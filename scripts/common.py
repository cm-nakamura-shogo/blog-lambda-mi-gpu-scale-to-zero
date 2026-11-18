"""Shared helpers for the measurement scripts."""

import datetime as dt
import json

import boto3


def session(profile, region):
    """Create a boto3 session for the given profile and region."""
    return boto3.Session(profile_name=profile, region_name=region)


def now_iso():
    """Return the current UTC time in ISO 8601 with milliseconds."""
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds")


def managed_instances(ec2, vpc_id):
    """Return Lambda managed instances in the VPC, including terminated ones still listed."""
    res = ec2.describe_instances(
        IncludeManagedResources=True,
        Filters=[{"Name": "vpc-id", "Values": [vpc_id]}],
    )
    out = []
    for r in res["Reservations"]:
        for i in r["Instances"]:
            out.append(
                {
                    "id": i["InstanceId"],
                    "type": i["InstanceType"],
                    "az": i["Placement"]["AvailabilityZone"],
                    "state": i["State"]["Name"],
                    "launch_time": i["LaunchTime"].isoformat(),
                }
            )
    return sorted(out, key=lambda x: x["launch_time"])


def append_jsonl(path, record):
    """Append one JSON record to a JSONL file."""
    with open(path, "a") as f:
        f.write(json.dumps(record, ensure_ascii=False, default=str) + "\n")
