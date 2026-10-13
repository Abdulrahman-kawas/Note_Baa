"""Backup: the iPad uploads closed audio parts and a lecture.json straight to S3 with presigned URLs."""
from __future__ import annotations

import uuid
from typing import Any

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from . import blobs
from .auth import require_device

router = APIRouter()

CONTENT_TYPES = {".m4a": "audio/mp4", ".caf": "audio/x-caf", ".json": "application/json"}
MAX_BYTES = 200 * 1024 * 1024  # one 5-minute PCM part is ~10 MB; m4a ~1.2 MB


class UploadIn(BaseModel):
    lecture_id: uuid.UUID
    name: str = Field(pattern=r"^(part-\d{3}\.(m4a|caf)|lecture\.json)$")
    sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    bytes: int = Field(gt=0, le=MAX_BYTES)


class DownloadIn(BaseModel):
    lecture_id: uuid.UUID
    name: str = Field(pattern=r"^(part-\d{3}\.(m4a|caf)|lecture\.json)$")


@router.post("/v1/backup/upload-url")
def upload_url(body: UploadIn, device: str = Depends(require_device)) -> dict[str, Any]:
    suffix = body.name[body.name.rfind("."):]
    key = blobs.lecture_prefix(device, str(body.lecture_id)) + body.name
    url, headers = blobs.presigned_put(key, CONTENT_TYPES[suffix], body.sha256)
    return {"url": url, "headers": headers, "expires_in": blobs.URL_TTL_SECONDS}


@router.get("/v1/backup/lectures")
def list_lectures(device: str = Depends(require_device)) -> dict[str, Any]:
    prefix = f"devices/{device}/lectures/"
    lectures: dict[str, list[dict[str, Any]]] = {}
    for obj in blobs.list_keys(prefix):
        lecture_id, _, name = obj["key"].removeprefix(prefix).partition("/")
        lectures.setdefault(lecture_id, []).append({"name": name, "size": obj["size"], "modified": obj["modified"]})
    return {"lectures": lectures}


@router.post("/v1/backup/download-url")
def download_url(body: DownloadIn, device: str = Depends(require_device)) -> dict[str, Any]:
    key = blobs.lecture_prefix(device, str(body.lecture_id)) + body.name
    if not blobs.list_keys(key):
        raise HTTPException(status_code=404, detail="Not in the backup")
    return {"url": blobs.presigned_get(key), "expires_in": blobs.URL_TTL_SECONDS}
