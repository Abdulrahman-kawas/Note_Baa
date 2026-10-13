"""Dawwen gateway: one FastAPI app, run by Lambda (via Lambda Web Adapter) or by plain uvicorn."""
from __future__ import annotations

import logging

from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from . import backup, claude, jobs, soniox

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s %(message)s")

app = FastAPI(title="Dawwen gateway", docs_url=None, redoc_url=None, openapi_url=None)
app.include_router(claude.router)
app.include_router(soniox.router)
app.include_router(backup.router)
app.include_router(jobs.router)


def _error(status: int, message: str) -> JSONResponse:
    # Same shape as the Anthropic API, so the iPad's ClaudeClient.errorMessage reads it.
    return JSONResponse(status_code=status, content={"type": "error", "error": {"type": "gateway_error", "message": message}})


@app.exception_handler(HTTPException)
async def http_error(_: Request, exc: HTTPException) -> JSONResponse:
    return _error(exc.status_code, str(exc.detail))


@app.exception_handler(RequestValidationError)
async def validation_error(_: Request, exc: RequestValidationError) -> JSONResponse:
    return _error(422, "Invalid request: " + "; ".join(e.get("msg", "") for e in exc.errors()[:3]))


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}
