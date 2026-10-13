"""Optional home worker. Pulls jobs from the AWS gateway over outbound HTTPS (no open ports at home).

Job types:
  refine_translation  context-aware EN->AR translation with a local LLM through Ollama (free alternative
                      to the Claude Haiku batch; only worth it if it wins the blind test).
  hq_asr              second-pass English transcription with faster-whisper (only if the WER test shows
                      Apple's live transcript is not good enough).

Results use the same shape as the gateway's Claude batch results, so the app reads both the same way.
"""
from __future__ import annotations

import json
import logging
import os
import tempfile
import time
from pathlib import Path
from typing import Any

import httpx

GATEWAY_URL = os.environ["GATEWAY_URL"].rstrip("/")
WORKER_TOKEN = os.environ["WORKER_TOKEN"]
JOB_TYPES = os.environ.get("JOB_TYPES", "refine_translation")
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://ollama:11434").rstrip("/")
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "qwen3:14b")
WHISPER_MODEL = os.environ.get("WHISPER_MODEL", "large-v3-turbo")
WHISPER_DEVICE = os.environ.get("WHISPER_DEVICE", "auto")  # cuda | cpu | auto
POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "60"))

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("dawwen.worker")
gateway = httpx.Client(base_url=GATEWAY_URL, headers={"Authorization": f"Bearer {WORKER_TOKEN}"}, timeout=60)
_whisper = None


def refine_translation(job: dict[str, Any]) -> dict[str, Any]:
    payload = httpx.get(job["input_url"], timeout=60).json()["refine"]
    schema = json.loads(payload["output_schema"])
    system = payload["preamble"] + ("\n\n" + payload["context"] if payload.get("context") else "")
    results: dict[str, Any] = {}
    for request in payload["requests"]:
        response = httpx.post(
            f"{OLLAMA_URL}/api/chat",
            json={
                "model": OLLAMA_MODEL,
                "messages": [
                    {"role": "system", "content": system},
                    {"role": "user", "content": request["user_message"]},
                ],
                "stream": False,
                "format": schema,          # Ollama structured output: JSON schema
                "think": False,
                "options": {"temperature": 0.2, "num_ctx": 16384},
            },
            timeout=900,
        )
        response.raise_for_status()
        results[request["custom_id"]] = {"text": response.json()["message"]["content"], "stop_reason": "end_turn"}
        log.info("refined %s", request["custom_id"])
    return {"type": "refine_translation", "engine": f"ollama:{OLLAMA_MODEL}", "results": results}


def hq_asr(job: dict[str, Any]) -> dict[str, Any]:
    global _whisper
    from faster_whisper import WhisperModel  # imported lazily: refine-only workers don't need it

    if _whisper is None:
        _whisper = WhisperModel(WHISPER_MODEL, device=WHISPER_DEVICE, compute_type="default")
    language = httpx.get(job["input_url"], timeout=60).json().get("language", "en")
    segments: list[dict[str, Any]] = []
    offset = 0.0
    with tempfile.TemporaryDirectory() as folder:
        for part in job["parts"]:
            path = Path(folder) / part["name"]
            path.write_bytes(httpx.get(part["url"], timeout=300).content)
            pieces, info = _whisper.transcribe(str(path), language=language[:2], vad_filter=True, beam_size=5)
            for piece in pieces:
                segments.append({"start": round(offset + piece.start, 2), "end": round(offset + piece.end, 2), "text": piece.text.strip()})
            offset += info.duration
            log.info("transcribed %s (%.0f s)", part["name"], info.duration)
    return {"type": "hq_asr", "engine": f"faster-whisper:{WHISPER_MODEL}", "segments": segments}


HANDLERS = {"refine_translation": refine_translation, "hq_asr": hq_asr}


def main() -> None:
    log.info("worker polling %s for %s", GATEWAY_URL, JOB_TYPES)
    while True:
        try:
            job = gateway.get("/v1/worker/claim", params={"types": JOB_TYPES}).json().get("job")
        except httpx.HTTPError as error:
            log.warning("gateway unreachable: %s", error)
            time.sleep(POLL_SECONDS)
            continue
        if not job:
            time.sleep(POLL_SECONDS)
            continue
        log.info("job %s (%s)", job["id"], job["type"])
        try:
            result = HANDLERS[job["type"]](job)
            gateway.post(f"/v1/worker/jobs/{job['id']}/result", json=result, timeout=120).raise_for_status()
        except Exception as error:  # report every failure to the gateway, then keep polling
            log.exception("job %s failed", job["id"])
            try:
                gateway.post(f"/v1/worker/jobs/{job['id']}/fail", json={"error": str(error)[:500]})
            except httpx.HTTPError:
                pass


if __name__ == "__main__":
    main()
