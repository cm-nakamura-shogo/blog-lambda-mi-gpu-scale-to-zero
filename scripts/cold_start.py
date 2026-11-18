# /// script
# requires-python = ">=3.12"
# dependencies = ["boto3"]
# ///
"""Invoke a scaled-to-zero LMI function until it answers, recording every throttle and instance state change."""

import argparse
import json
import time

from botocore.config import Config
from botocore.exceptions import ClientError

from common import append_jsonl, managed_instances, now_iso, session


def invoke_once(client, function, qualifier, payload):
    """Invoke synchronously and return (status, body_or_error)."""
    try:
        res = client.invoke(FunctionName=function, Qualifier=qualifier, Payload=json.dumps(payload).encode())
        body = json.loads(res["Payload"].read())
        return ("FunctionError" if "FunctionError" in res else "OK"), body
    except ClientError as e:
        err = e.response["Error"]
        return err["Code"], err.get("Message", "")[:300]


def sdk_default_attempt(sess, function, qualifier, payload):
    """Call once with the SDK's default retry settings and report how long it took to give up."""
    client = sess.client("lambda", config=Config(read_timeout=900))
    attempts = []
    client.meta.events.register("needs-retry.lambda.Invoke", lambda **kw: attempts.append(time.time()))
    t0 = time.time()
    status, body = invoke_once(client, function, qualifier, payload)
    return {
        "retry_mode": client.meta.config.retries.get("mode", "legacy") if client.meta.config.retries else "legacy",
        "attempts": len(attempts),
        "elapsed_seconds": round(time.time() - t0, 2),
        "status": status,
        "detail": body if status != "OK" else None,
    }


def main():
    """Run the cold start measurement and write a timeline and a summary."""
    p = argparse.ArgumentParser()
    p.add_argument("--profile", default=None)
    p.add_argument("--region", default="ap-northeast-1")
    p.add_argument("--function", required=True)
    p.add_argument("--qualifier", default="$LATEST.PUBLISHED")
    p.add_argument("--vpc-id", required=True)
    p.add_argument("--interval", type=float, default=5.0)
    p.add_argument("--timeout", type=float, default=1800.0)
    p.add_argument("--payload", default='{"prompt": "Lambdaとは何か、一文で答えて。", "max_tokens": 64}')
    p.add_argument("--out", required=True)
    args = p.parse_args()

    sess = session(args.profile, args.region)
    ec2 = sess.client("ec2")
    payload = json.loads(args.payload)
    timeline = f"{args.out}.timeline.jsonl"

    before = managed_instances(ec2, args.vpc_id)
    t_start = time.time()
    sdk = sdk_default_attempt(sess, args.function, args.qualifier, payload)
    append_jsonl(timeline, {"t": round(time.time() - t_start, 2), "at": now_iso(), "event": "sdk_default", **sdk})
    print("SDK default:", sdk)

    # 以降は SDK のリトライを止め、1 回ずつの結果を記録する。
    client = sess.client("lambda", config=Config(retries={"total_max_attempts": 1}, read_timeout=900))
    statuses = {}
    seen = {}
    body = None
    while time.time() - t_start < args.timeout:
        t_call = time.time()
        status, body = invoke_once(client, args.function, args.qualifier, payload)
        statuses[status] = statuses.get(status, 0) + 1
        rec = {"t": round(t_call - t_start, 2), "at": now_iso(), "event": "invoke", "status": status, "seconds": round(time.time() - t_call, 2)}
        if status not in ("OK",):
            rec["detail"] = body
        append_jsonl(timeline, rec)

        for inst in managed_instances(ec2, args.vpc_id):
            if seen.get(inst["id"]) != inst["state"]:
                seen[inst["id"]] = inst["state"]
                append_jsonl(timeline, {"t": round(time.time() - t_start, 2), "at": now_iso(), "event": "instance", **inst})
                print(f"[{time.time() - t_start:7.1f}s] instance {inst['id']} {inst['state']}")
        print(f"[{t_call - t_start:7.1f}s] {status}")
        if status == "OK":
            break
        time.sleep(max(0.0, args.interval - (time.time() - t_call)))

    t_ok = time.time()
    summary = {
        "started_at_epoch": t_start,
        "instances_before": before,
        "sdk_default": sdk,
        "status_counts": statuses,
        "seconds_to_first_success": round(t_ok - t_start, 2),
        "response": body,
    }
    if isinstance(body, dict) and "init" in body:
        init = body["init"]
        summary["breakdown_seconds"] = {
            "until_init_start": round(init["start_epoch"] - t_start, 2),
            "init": init["total_seconds"],
            "init_end_to_response": round(t_ok - init["end_epoch"], 2),
            "host_uptime_at_init": init["host_uptime_at_init_seconds"],
        }
    with open(f"{args.out}.summary.json", "w") as f:
        json.dump(summary, f, ensure_ascii=False, indent=2, default=str)
    print(json.dumps(summary.get("breakdown_seconds"), indent=2), statuses)


if __name__ == "__main__":
    main()
