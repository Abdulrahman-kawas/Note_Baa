"""Short-lived Soniox keys: the iPad streams audio to Soniox directly, never with the master key."""
from __future__ import annotations

from typing import Any

import httpx
from fastapi import APIRouter, Depends, HTTPException

from .auth import require_device
from .config import secrets, settings
from .store import store

router = APIRouter()

TEMPORARY_KEY_URL = "https://api.soniox.com/v1/auth/temporary-api-key"


@router.post("/v1/soniox/temp-key")
def temporary_key(device: str = Depends(require_device)) -> dict[str, Any]:
    master = secrets().soniox_api_key
    if not master:
        raise HTTPException(status_code=503, detail="Soniox is not configured on the gateway")
    # A reconnecting stream asks for a new key each time; 30 an hour is far above normal use.
    if store().hit(f"soniox#{device}", 3600) > settings().soniox_keys_per_hour:
        raise HTTPException(status_code=429, detail="Too many Soniox keys this hour")
    try:
        response = httpx.post(
            TEMPORARY_KEY_URL,
            headers={"Authorization": f"Bearer {master}"},
            json={
                "usage_type": "transcribe_websocket",
                "expires_in_seconds": 60,  # only needed to open the WebSocket
                "client_reference_id": device,
            },
            timeout=10,
        )
    except httpx.HTTPError as error:
        raise HTTPException(status_code=502, detail="Could not reach Soniox") from error
    if response.status_code != 200:
        raise HTTPException(status_code=502, detail=f"Soniox refused: {response.status_code}")
    data = response.json()
    return {"api_key": data["api_key"], "expires_at": data.get("expires_at")}
