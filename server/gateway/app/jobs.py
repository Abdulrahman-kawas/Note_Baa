"""Work that finishes while the iPad sleeps: Claude Message Batches (half price) or the home worker."""
from __future__ import annotations

import uuid
from typing import Any, Literal

from fastapi import APIRouter, Body, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from . import blobs
from .auth import require_device, require_worker
from .claude import ClaudeCall, build_params, rough_tokens, sync_client
from .config import estimate_usd, price_usd, settings
from .store import store, utc_now

router = APIRouter()

JobType = Literal["summary", "refine_translation", "hq_asr"]
Engine = Literal["claude-batch", "home"]


class RefineRequest(BaseModel):
    custom_id: str = Field(pattern=r"^[A-Za-z0-9_-]{1,64}$")
    user_message: str = Field(max_length=200_000)


class RefinePayload(BaseModel):
    model: Literal["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"] = "claude-haiku-5-5"
    preamble: str = Field(max_length=20_000)
    context: str = Field(default="", max_length=200_000)
    effort: Literal["low", "medium", "high"] = "low"
    max_tokens: int = Field(default=16_000, ge=1, le=64_000)
    output_schema: str = Field(max_length=20_000)
    requests: list[RefineRequest] = Field(min_length=1, max_length=500)


class JobIn(BaseModel):
    type: JobType
    lecture_id: uuid.UUID
    engine: Engine = "claude-batch"
    claude: ClaudeCall | None = None      # summary
    refine: RefinePayload | None = None   # refine_translation
    language: str = "en"                  # hq_asr


def _job_out(job: dict[str, Any]) -> dict[str, Any]:
    out = {"id": job["id"], "type": job["type"], "status": job["status"], "error": job.get("error")}
    if job["status"] == "done" and job.get("result_key"):
        out["result_url"] = blobs.presigned_get(job["result_key"])
    return out


def _reserve(device: str, usd: float) -> None:
    config = settings()
    if not store().try_add_spend(device, usd, config.daily_cap_usd, config.monthly_cap_usd):
        raise HTTPException(status_code=402, detail="Spending cap reached for today or this month")


@router.post("/v1/jobs")
def create_job(job_in: JobIn, device: str = Depends(require_device)) -> dict[str, Any]:
    job_id = uuid.uuid4().hex
    lecture_id = str(job_in.lecture_id)
    job: dict[str, Any] = {
        "id": job_id, "device": device, "type": job_in.type, "engine": job_in.engine,
        "lecture_id": lecture_id, "status": "queued", "created_at": utc_now(), "updated_at": utc_now(),
        "result_key": f"jobs/{job_id}/result.json",
    }
    requests: list[dict[str, Any]] = []
    model = None
    if job_in.type == "summary":
        if job_in.claude is None or job_in.engine != "claude-batch":
            raise HTTPException(status_code=400, detail="summary needs `claude` and engine claude-batch")
        params = build_params(job_in.claude)
        model = params["model"]
        requests = [{"custom_id": "summary", "params": params}]
        reserved = estimate_usd(model, rough_tokens(job_in.claude.context + job_in.claude.user_message), 12_000, batch=True)
    elif job_in.type == "refine_translation":
        refine = job_in.refine
        if refine is None:
            raise HTTPException(status_code=400, detail="refine_translation needs `refine`")
        model = refine.model
        for request in refine.requests:
            call = ClaudeCall(
                model=refine.model, preamble=refine.preamble, context=refine.context,
                user_message=request.user_message, effort=refine.effort,
                max_tokens=refine.max_tokens, output_schema=refine.output_schema,
            )
            requests.append({"custom_id": request.custom_id, "params": build_params(call)})
        text = sum(rough_tokens(r.user_message) for r in refine.requests)
        # Arabic output runs about 2-3x the English input in tokens.
        reserved = estimate_usd(model, text + rough_tokens(refine.context) * len(refine.requests), text * 3, batch=True)
    else:  # hq_asr
        if job_in.engine != "home":
            raise HTTPException(status_code=400, detail="hq_asr runs on the home worker only")
        reserved = 0.0

    if job_in.engine == "home":
        # The worker reads its input from S3; DynamoDB items stay small.
        payload = job_in.model_dump(mode="json")
        payload["parts_prefix"] = blobs.lecture_prefix(device, lecture_id)
        blobs.put_json(f"jobs/{job_id}/input.json", payload)
        job["input_key"] = f"jobs/{job_id}/input.json"
        store().put_job(job)
        return _job_out(job)

    _reserve(device, reserved)
    try:
        batch = sync_client().messages.batches.create(requests=requests)
    except Exception:
        store().adjust_spend(device, -reserved)
        raise
    job.update(status="running", batch_id=batch.id, model=model, reserved_usd=reserved)
    store().put_job(job)
    return _job_out(job)


def _collect_batch(job: dict[str, Any]) -> None:
    client = sync_client()
    batch = client.messages.batches.retrieve(job["batch_id"])
    if batch.processing_status != "ended":
        return
    results: dict[str, Any] = {}
    actual = 0.0
    for item in client.messages.batches.results(job["batch_id"]):
        if item.result.type == "succeeded":
            message = item.result.message
            text = "".join(block.text for block in message.content if block.type == "text")
            results[item.custom_id] = {"text": text, "stop_reason": message.stop_reason}
            usage = message.usage
            actual += price_usd(job["model"], {
                "input_tokens": usage.input_tokens or 0,
                "cache_creation_input_tokens": usage.cache_creation_input_tokens or 0,
                "cache_read_input_tokens": usage.cache_read_input_tokens or 0,
                "output_tokens": usage.output_tokens or 0,
            }, batch=True)
        else:
            results[item.custom_id] = {"error": item.result.type}
    blobs.put_json(job["result_key"], {"type": job["type"], "results": results})
    store().adjust_spend(job["device"], actual - float(job.get("reserved_usd", 0)))
    failed = sum(1 for r in results.values() if "error" in r)
    store().update_job(job["id"], status="done", error=(f"{failed} part(s) failed" if failed else None))
    job.update(status="done", error=(f"{failed} part(s) failed" if failed else None))


@router.get("/v1/jobs/{job_id}")
def get_job(job_id: str, device: str = Depends(require_device)) -> dict[str, Any]:
    job = store().get_job(job_id)
    if job is None or job.get("device") != device:
        raise HTTPException(status_code=404, detail="No such job")
    if job["engine"] == "claude-batch" and job["status"] == "running":
        _collect_batch(job)
    return _job_out(job)


# Home worker ---------------------------------------------------------------------------------

@router.get("/v1/worker/claim")
def claim(types: str = Query("refine_translation,hq_asr"), worker: str = Depends(require_worker)) -> dict[str, Any]:
    job = store().claim_job([t for t in types.split(",") if t], worker)
    if job is None:
        return {"job": None}
    parts = []
    if job["type"] == "hq_asr":
        prefix = blobs.lecture_prefix(job["device"], job["lecture_id"])
        for obj in blobs.list_keys(prefix):
            name = obj["key"].removeprefix(prefix)
            if name.startswith("part-") and name.endswith(".m4a"):
                parts.append({"name": name, "url": blobs.presigned_get(obj["key"])})
        parts.sort(key=lambda p: p["name"])
    return {"job": {
        "id": job["id"], "type": job["type"], "lecture_id": job["lecture_id"],
        "input_url": blobs.presigned_get(job["input_key"]), "parts": parts,
    }}


@router.post("/v1/worker/jobs/{job_id}/result")
def worker_result(job_id: str, result: dict[str, Any] = Body(...), worker: str = Depends(require_worker)) -> dict[str, str]:
    job = store().get_job(job_id)
    if job is None or job["status"] != "running":
        raise HTTPException(status_code=409, detail="Job is not running")
    blobs.put_json(job["result_key"], result)
    store().update_job(job_id, status="done")
    return {"status": "done"}


@router.post("/v1/worker/jobs/{job_id}/fail")
def worker_fail(job_id: str, body: dict[str, Any] = Body(default={}), worker: str = Depends(require_worker)) -> dict[str, str]:
    store().update_job(job_id, status="failed", error=str(body.get("error", "worker error"))[:500])
    return {"status": "failed"}
