"""S3 access: presigned URLs so audio goes iPad -> S3 directly and never through Lambda."""
from __future__ import annotations

import json
from functools import lru_cache
from typing import Any

import boto3
from botocore.config import Config

from .config import settings

URL_TTL_SECONDS = 3600


@lru_cache(maxsize=1)
def s3():
    config = settings()
    return boto3.client(
        "s3",
        endpoint_url=config.s3_endpoint_url,
        # Plain SigV4 presigned PUTs: no automatic CRC32 header the iPad would then have to send.
        config=Config(signature_version="s3v4", request_checksum_calculation="when_required"),
    )


def lecture_prefix(device: str, lecture_id: str) -> str:
    return f"devices/{device}/lectures/{lecture_id}/"


def presigned_put(key: str, content_type: str, sha256_hex: str) -> tuple[str, dict[str, str]]:
    """The iPad must send exactly these headers with its PUT, or S3 rejects the signature."""
    headers = {"Content-Type": content_type, "x-amz-meta-sha256": sha256_hex}
    url = s3().generate_presigned_url(
        "put_object",
        Params={
            "Bucket": settings().bucket,
            "Key": key,
            "ContentType": content_type,
            "Metadata": {"sha256": sha256_hex},
        },
        ExpiresIn=URL_TTL_SECONDS,
        HttpMethod="PUT",
    )
    return url, headers


def presigned_get(key: str) -> str:
    return s3().generate_presigned_url(
        "get_object", Params={"Bucket": settings().bucket, "Key": key}, ExpiresIn=URL_TTL_SECONDS
    )


def put_json(key: str, value: Any) -> None:
    s3().put_object(
        Bucket=settings().bucket,
        Key=key,
        Body=json.dumps(value, ensure_ascii=False).encode("utf-8"),
        ContentType="application/json",
    )


def get_json(key: str) -> Any:
    body = s3().get_object(Bucket=settings().bucket, Key=key)["Body"].read()
    return json.loads(body)


def list_keys(prefix: str) -> list[dict[str, Any]]:
    paginator = s3().get_paginator("list_objects_v2")
    items: list[dict[str, Any]] = []
    for page in paginator.paginate(Bucket=settings().bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            items.append({"key": obj["Key"], "size": obj["Size"], "modified": obj["LastModified"].isoformat()})
    return items
