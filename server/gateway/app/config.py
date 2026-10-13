"""Runtime settings and secrets. Secrets come from SSM Parameter Store on AWS, from env vars locally."""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from functools import lru_cache

import boto3

HAIKU = "claude-haiku-5-5"
SONNET = "claude-sonnet-5-5"
OPUS = "claude-opus-5-5"
ALLOWED_MODELS = (OPUS, SONNET, HAIKU)

# USD per million tokens: (input, output, cache read). Cache writes (5-minute TTL) cost 1.25x input.
# Source: Claude API pricing as of 2026-10. Haiku 5.5 switches to 0.50 / 2.50 above 100K prompt tokens.
PRICES: dict[str, tuple[float, float, float]] = {
    OPUS: (4.00, 20.00, 0.20),
    SONNET: (2.00, 10.00, 0.20),
    HAIKU: (0.10, 0.50, 0.01),
}
HAIKU_LONG = (0.50, 2.50, 0.05)  # cache-read figure for the long tier is an estimate (0.1x input)


@dataclass(frozen=True)
class Settings:
    store_backend: str
    table_name: str
    sqlite_path: str
    bucket: str
    s3_endpoint_url: str | None
    daily_cap_usd: float
    monthly_cap_usd: float
    soniox_keys_per_hour: int
    max_output_tokens: int


@lru_cache(maxsize=1)
def settings() -> Settings:
    env = os.environ
    return Settings(
        store_backend=env.get("STORE_BACKEND", "sqlite"),
        table_name=env.get("TABLE_NAME", "dawwen"),
        sqlite_path=env.get("SQLITE_PATH", "/tmp/dawwen.sqlite3"),
        bucket=env.get("BUCKET", ""),
        s3_endpoint_url=env.get("S3_ENDPOINT_URL") or None,
        daily_cap_usd=float(env.get("DAILY_CLAUDE_USD_CAP", "1.0")),
        monthly_cap_usd=float(env.get("MONTHLY_CLAUDE_USD_CAP", "15.0")),
        soniox_keys_per_hour=int(env.get("SONIOX_KEYS_PER_HOUR", "30")),
        max_output_tokens=int(env.get("MAX_OUTPUT_TOKENS", "64000")),
    )


@dataclass(frozen=True)
class Secrets:
    anthropic_api_key: str | None
    soniox_api_key: str | None
    # device id -> sha256(hex) of the device secret. The app sends "Bearer <device id>.<secret>".
    device_token_hashes: dict[str, str] = field(default_factory=dict)
    worker_token_hash: str | None = None


def _parse_devices(raw: str | None) -> dict[str, str]:
    if not raw:
        return {}
    value = json.loads(raw)
    return {str(k): str(v) for k, v in value.items()}


@lru_cache(maxsize=1)
def secrets() -> Secrets:
    """Read once per container. Rotate a secret in SSM, then redeploy (or wait for a cold start)."""
    if os.environ.get("SECRETS_SOURCE", "env") == "ssm":
        prefix = os.environ.get("SSM_PREFIX", "/dawwen").rstrip("/")
        names = ["anthropic_api_key", "soniox_api_key", "device_tokens", "worker_token_sha256"]
        response = boto3.client("ssm").get_parameters(
            Names=[f"{prefix}/{name}" for name in names], WithDecryption=True
        )
        values = {p["Name"].rsplit("/", 1)[-1]: p["Value"] for p in response["Parameters"]}
    else:
        values = {
            "anthropic_api_key": os.environ.get("ANTHROPIC_API_KEY"),
            "soniox_api_key": os.environ.get("SONIOX_API_KEY"),
            "device_tokens": os.environ.get("DEVICE_TOKENS"),
            "worker_token_sha256": os.environ.get("WORKER_TOKEN_SHA256"),
        }
    return Secrets(
        anthropic_api_key=values.get("anthropic_api_key") or None,
        soniox_api_key=values.get("soniox_api_key") or None,
        device_token_hashes=_parse_devices(values.get("device_tokens")),
        worker_token_hash=values.get("worker_token_sha256") or None,
    )


def price_usd(model: str, usage: dict, *, batch: bool = False) -> float:
    """Cost of one response from its usage block (input, cache write, cache read, output)."""
    inp, out, read = PRICES[model]
    uncached = usage.get("input_tokens", 0) or 0
    written = usage.get("cache_creation_input_tokens", 0) or 0
    cached = usage.get("cache_read_input_tokens", 0) or 0
    output = usage.get("output_tokens", 0) or 0
    if model == HAIKU and uncached + written + cached > 100_000:
        inp, out, read = HAIKU_LONG
    usd = (uncached * inp + written * inp * 1.25 + cached * read + output * out) / 1_000_000
    return usd * 0.5 if batch else usd


def estimate_usd(model: str, input_tokens: int, output_tokens: int, *, batch: bool = False) -> float:
    return price_usd(model, {"input_tokens": input_tokens, "output_tokens": output_tokens}, batch=batch)
