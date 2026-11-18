# /// script
# requires-python = ">=3.12"
# dependencies = ["boto3"]
# ///
"""Run the warm benchmark matrix (input length x concurrency) through the function's bench mode."""

import argparse
import json
import statistics

from botocore.config import Config

from common import session


def call(client, function, qualifier, payload):
    """Invoke the function synchronously and return the decoded result."""
    res = client.invoke(FunctionName=function, Qualifier=qualifier, Payload=json.dumps(payload).encode())
    body = json.loads(res["Payload"].read())
    if "FunctionError" in res:
        raise RuntimeError(body)
    return body


def main():
    """Measure each condition with warm-up rounds, then summarize medians."""
    p = argparse.ArgumentParser()
    p.add_argument("--profile", default=None)
    p.add_argument("--region", default="ap-northeast-1")
    p.add_argument("--function", required=True)
    p.add_argument("--qualifier", default="$LATEST.PUBLISHED")
    p.add_argument("--inputs", default="254,2048,7936")
    p.add_argument("--concurrency", default="1,2,4")
    p.add_argument("--out", required=True)
    args = p.parse_args()

    client = session(args.profile, args.region).client("lambda", config=Config(read_timeout=900, retries={"total_max_attempts": 1}))
    rows = []
    for n_in in [int(x) for x in args.inputs.split(",")]:
        for conc in [int(x) for x in args.concurrency.split(",")]:
            base = {"mode": "bench", "input_tokens": n_in, "max_tokens": 256, "concurrency": conc}
            call(client, args.function, args.qualifier, {**base, "rounds": 2, "seed": 1})
            body = call(client, args.function, args.qualifier, {**base, "rounds": 5, "seed": 2})
            rounds = body["result"]["rounds"]
            row = {"input_tokens": body["result"]["input_tokens"], "concurrency": conc}
            for k in ("ttft_ms", "e2e_tok_per_sec", "decode_tok_per_sec", "aggregate_tok_per_sec"):
                row[k] = round(statistics.median(r[k] for r in rounds), 2)
            row["rounds"] = rounds
            rows.append(row)
            print(json.dumps({k: v for k, v in row.items() if k != "rounds"}))
    with open(args.out, "w") as f:
        json.dump({"cuda_graph": body["init"]["cuda_graph"], "rows": rows}, f, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
