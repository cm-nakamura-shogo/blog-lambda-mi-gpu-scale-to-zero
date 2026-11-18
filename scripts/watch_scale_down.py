# /// script
# requires-python = ">=3.12"
# dependencies = ["boto3"]
# ///
"""After the last invocation, watch until the managed instances of the VPC are gone."""

import argparse
import time

from common import append_jsonl, managed_instances, now_iso, session


def main():
    """Poll instance states and write each change with the elapsed time since start."""
    p = argparse.ArgumentParser()
    p.add_argument("--profile", default=None)
    p.add_argument("--region", default="ap-northeast-1")
    p.add_argument("--vpc-id", required=True)
    p.add_argument("--interval", type=float, default=30.0)
    p.add_argument("--timeout", type=float, default=7200.0)
    p.add_argument("--out", required=True)
    args = p.parse_args()

    ec2 = session(args.profile, args.region).client("ec2")
    t0 = time.time()
    seen = {}
    while time.time() - t0 < args.timeout:
        insts = managed_instances(ec2, args.vpc_id)
        for inst in insts:
            if seen.get(inst["id"]) != inst["state"]:
                seen[inst["id"]] = inst["state"]
                append_jsonl(args.out, {"t": round(time.time() - t0, 1), "at": now_iso(), **inst})
                print(f"[{time.time() - t0:7.1f}s] {inst['id']} {inst['state']}", flush=True)
        if insts and all(i["state"] == "terminated" for i in insts):
            break
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
