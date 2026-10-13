"""Bearer-token auth. One random secret per device (and one for the home worker), stored only as a hash."""
from __future__ import annotations

import hashlib
import hmac

from fastapi import Header, HTTPException

from .config import secrets


def sha256_hex(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _bearer(authorization: str) -> str:
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not token:
        raise HTTPException(status_code=401, detail="Missing bearer token")
    return token.strip()


def require_device(authorization: str = Header(default="")) -> str:
    """Token format: '<device id>.<secret>'. Returns the device id."""
    token = _bearer(authorization)
    device_id, dot, secret = token.partition(".")
    expected = secrets().device_token_hashes.get(device_id)
    if not dot or not expected or not hmac.compare_digest(expected, sha256_hex(secret)):
        raise HTTPException(status_code=401, detail="Unknown device or wrong token")
    return device_id


def require_worker(authorization: str = Header(default="")) -> str:
    token = _bearer(authorization)
    expected = secrets().worker_token_hash
    if not expected or not hmac.compare_digest(expected, sha256_hex(token)):
        raise HTTPException(status_code=401, detail="Wrong worker token")
    return "worker"
