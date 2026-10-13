"""Create a device (or worker) token and register its hash in SSM. The secret is printed once, never stored.

  python issue_device_token.py --name ipad --apply            # prints the token to paste into the app
  python issue_device_token.py --worker --apply               # prints WORKER_TOKEN for the home worker
  python issue_device_token.py --revoke ipad-3f2a --apply      # removes a lost device
"""
from __future__ import annotations

import argparse
import hashlib
import json
import secrets

import boto3


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", default="ipad")
    parser.add_argument("--worker", action="store_true")
    parser.add_argument("--revoke")
    parser.add_argument("--prefix", default="/dawwen")
    parser.add_argument("--apply", action="store_true", help="write to SSM (otherwise only print)")
    args = parser.parse_args()
    ssm = boto3.client("ssm")
    prefix = args.prefix.rstrip("/")

    if args.worker:
        token = secrets.token_urlsafe(32)
        digest = hashlib.sha256(token.encode()).hexdigest()
        if args.apply:
            ssm.put_parameter(Name=f"{prefix}/worker_token_sha256", Value=digest, Type="SecureString", Overwrite=True)
        print(f"WORKER_TOKEN={token}")
        return

    name = f"{prefix}/device_tokens"
    try:
        devices = json.loads(ssm.get_parameter(Name=name, WithDecryption=True)["Parameter"]["Value"])
    except ssm.exceptions.ParameterNotFound:
        devices = {}

    if args.revoke:
        devices.pop(args.revoke, None)
        print(f"revoked {args.revoke}")
    else:
        device_id = f"{args.name}-{secrets.token_hex(2)}"
        secret = secrets.token_urlsafe(32)
        devices[device_id] = hashlib.sha256(secret.encode()).hexdigest()
        print("Paste this into Dawwen > Settings > Server > Token (shown once):")
        print(f"{device_id}.{secret}")

    if args.apply:
        ssm.put_parameter(Name=name, Value=json.dumps(devices), Type="SecureString", Overwrite=True)
        print("SSM updated. Redeploy or wait for a Lambda cold start for the change to apply.")


if __name__ == "__main__":
    main()
