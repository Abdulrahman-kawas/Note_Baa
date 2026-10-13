"""Claude proxy: the API key stays here, every request is capped, the stream is relayed unchanged."""
from __future__ import annotations

import json
import logging
from functools import lru_cache
from typing import Any, Literal

import anthropic
from fastapi import APIRouter, Depends, HTTPException
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from .auth import require_device
from .config import ALLOWED_MODELS, HAIKU, estimate_usd, price_usd, secrets, settings
from .store import store

log = logging.getLogger("dawwen.claude")
router = APIRouter()

FALLBACK_BETA = "server-side-fallback-2026-07-01"
Effort = Literal["low", "medium", "high", "xhigh", "max"]


class ClaudeCall(BaseModel):
    """What the app sends. The gateway, not the app, builds the Messages API request."""

    model: Literal["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
    preamble: str = Field(max_length=20_000)
    context: str = Field(default="", max_length=3_000_000)
    user_message: str = Field(max_length=400_000)
    effort: Effort = "high"
    max_tokens: int = Field(default=16_000, ge=1, le=128_000)
    output_schema: str | None = Field(default=None, max_length=20_000)


def anthropic_key() -> str:
    key = secrets().anthropic_api_key
    if not key:
        raise HTTPException(status_code=503, detail="Claude is not configured on the gateway")
    return key


@lru_cache(maxsize=1)
def async_client() -> anthropic.AsyncAnthropic:
    return anthropic.AsyncAnthropic(api_key=anthropic_key(), max_retries=2)


@lru_cache(maxsize=1)
def sync_client() -> anthropic.Anthropic:
    return anthropic.Anthropic(api_key=anthropic_key(), max_retries=2)


def build_params(call: ClaudeCall) -> dict[str, Any]:
    """Same request the iPad builds in ClaudeClient.messagesBody (minus `stream`)."""
    if call.model not in ALLOWED_MODELS:
        raise HTTPException(status_code=400, detail="Model not allowed")
    output_config: dict[str, Any] = {"effort": call.effort}
    if call.output_schema:
        output_config["format"] = {"type": "json_schema", "schema": json.loads(call.output_schema)}
    system: list[dict[str, Any]] = [{"type": "text", "text": call.preamble}]
    if call.context:
        system.append({"type": "text", "text": call.context, "cache_control": {"type": "ephemeral"}})
    return {
        "model": call.model,
        "max_tokens": min(call.max_tokens, settings().max_output_tokens),
        "thinking": {"type": "adaptive"},
        "output_config": output_config,
        "system": system,
        "messages": [{"role": "user", "content": call.user_message}],
    }


def fallback_options(model: str) -> dict[str, Any]:
    """Server-side refusal fallback; Haiku has none."""
    if model == HAIKU:
        return {}
    return {"extra_headers": {"anthropic-beta": FALLBACK_BETA}, "extra_body": {"fallbacks": "default"}}


def rough_tokens(text: str) -> int:
    return max(1, len(text) // 3)


def _sse(event_type: str, payload: dict[str, Any]) -> str:
    return f"event: {event_type}\ndata: {json.dumps(payload, ensure_ascii=False)}\n\n"


@router.post("/v1/claude/messages")
async def claude_messages(call: ClaudeCall, device: str = Depends(require_device)) -> StreamingResponse:
    params = build_params(call)
    client = async_client()
    counted = await client.messages.count_tokens(
        model=params["model"], system=params["system"], messages=params["messages"]
    )
    reserved = estimate_usd(call.model, counted.input_tokens, min(params["max_tokens"], 12_000))
    config = settings()
    allowed = await run_in_threadpool(
        store().try_add_spend, device, reserved, config.daily_cap_usd, config.monthly_cap_usd
    )
    if not allowed:
        raise HTTPException(status_code=402, detail="Spending cap reached for today or this month")

    try:
        # Opening the stream here, before the 200 goes out, lets HTTP errors (429/529) reach the
        # app as real status codes it can retry.
        stream = await client.messages.create(**params, stream=True, **fallback_options(call.model))
    except anthropic.APIStatusError as error:
        await run_in_threadpool(store().adjust_spend, device, -reserved)
        raise HTTPException(status_code=error.status_code, detail=str(error.message)) from error
    except anthropic.APIConnectionError as error:
        await run_in_threadpool(store().adjust_spend, device, -reserved)
        raise HTTPException(status_code=502, detail="Could not reach Claude") from error

    async def relay():
        usage: dict[str, int] = {}
        try:
            async for event in stream:
                if event.type == "message_start":
                    u = event.message.usage
                    usage["input_tokens"] = u.input_tokens or 0
                    usage["cache_creation_input_tokens"] = u.cache_creation_input_tokens or 0
                    usage["cache_read_input_tokens"] = u.cache_read_input_tokens or 0
                elif event.type == "message_delta" and event.usage is not None:
                    usage["output_tokens"] = event.usage.output_tokens or 0
                yield f"event: {event.type}\ndata: {event.model_dump_json(exclude_none=True)}\n\n"
        except anthropic.APIError as error:
            yield _sse("error", {"type": "error", "error": {"type": "api_error", "message": str(error)}})
        finally:
            actual = price_usd(call.model, usage)
            await run_in_threadpool(store().adjust_spend, device, actual - reserved)
            # Metadata only: transcripts never reach the logs.
            log.info(json.dumps({"device": device, "model": call.model, "usage": usage, "usd": round(actual, 5)}))

    return StreamingResponse(relay(), media_type="text/event-stream", headers={"Cache-Control": "no-cache"})


@router.get("/v1/claude/spend")
def claude_spend(device: str = Depends(require_device)) -> dict[str, float]:
    day, month = store().spend(device)
    config = settings()
    return {"day_usd": day, "month_usd": month, "day_cap_usd": config.daily_cap_usd, "month_cap_usd": config.monthly_cap_usd}
