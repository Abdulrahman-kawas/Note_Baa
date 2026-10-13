"""Download the whole backup (or one lecture) from S3 and verify every file against its sha256.

  AWS_PROFILE=dawwen-readonly python restore_backup.py --bucket <bucket> --device ipad-3f2a --out ./restore
Each lecture folder comes back as lecture.json + part-NNN.m4a, ready for re-import or plain playback.
"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path

import boto3


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--device", required=True)
    parser.add_argument("--lecture")
    parser.add_argument("--out", default="restore")
    args = parser.parse_args()
    s3 = boto3.client("s3")
    prefix = f"devices/{args.device}/lectures/" + (f"{args.lecture}/" if args.lecture else "")
    bad = 0
    count = 0
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=args.bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            relative = obj["Key"].removeprefix(f"devices/{args.device}/lectures/")
            target = Path(args.out) / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            response = s3.get_object(Bucket=args.bucket, Key=obj["Key"])
            data = response["Body"].read()
            target.write_bytes(data)
            expected = response.get("Metadata", {}).get("sha256")
            if expected and hashlib.sha256(data).hexdigest() != expected:
                bad += 1
                print(f"CHECKSUM MISMATCH {relative}")
            count += 1
    print(f"{count} files restored to {args.out}; {bad} checksum mismatches")


if __name__ == "__main__":
    main()
