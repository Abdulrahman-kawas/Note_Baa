"""Offline tests: moto stands in for DynamoDB/S3, fakes stand in for Claude and Soniox.

Run: pip install -r requirements.txt "moto[dynamodb,s3]==5.2.3" pytest==9.1.1 && pytest -q
"""
from __future__ import annotations

import hashlib
import json
import os
from types import SimpleNamespace

import boto3
import pytest
from moto import mock_aws

DEVICE_SECRET = "s3cret-device"
WORKER_SECRET = "s3cret-worker"


def sha(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


@pytest.fixture()
def client(monkeypatch):
    env = {
        "AWS_DEFAULT_REGION": "us-east-1", "AWS_ACCESS_KEY_ID": "x", "AWS_SECRET_ACCESS_KEY": "x",
        "STORE_BACKEND": "dynamodb", "TABLE_NAME": "dawwen-test", "BUCKET": "dawwen-test-bucket",
        "SECRETS_SOURCE": "env", "ANTHROPIC_API_KEY": "sk-test", "SONIOX_API_KEY": "soniox-test",
        "DEVICE_TOKENS": json.dumps({"ipad": sha(DEVICE_SECRET)}), "WORKER_TOKEN_SHA256": sha(WORKER_SECRET),
        "DAILY_CLAUDE_USD_CAP": "0.50", "MONTHLY_CLAUDE_USD_CAP": "5",
    }
    for key, value in env.items():
        monkeypatch.setenv(key, value)
    with mock_aws():
        boto3.client("s3").create_bucket(Bucket="dawwen-test-bucket")
        boto3.client("dynamodb").create_table(
            TableName="dawwen-test", BillingMode="PAY_PER_REQUEST",
            AttributeDefinitions=[{"AttributeName": n, "AttributeType": "S"} for n in ("pk", "sk", "gsi1pk", "gsi1sk")],
            KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}, {"AttributeName": "sk", "KeyType": "RANGE"}],
            GlobalSecondaryIndexes=[{
                "IndexName": "gsi1",
                "KeySchema": [{"AttributeName": "gsi1pk", "KeyType": "HASH"}, {"AttributeName": "gsi1sk", "KeyType": "RANGE"}],
                "Projection": {"ProjectionType": "ALL"},
            }],
        )
        from app import blobs, claude, config, store
        for cached in (config.settings, config.secrets, store.store, blobs.s3, claude.async_client, claude.sync_client):
            cached.cache_clear()
        from fastapi.testclient import TestClient
        from app.main import app
        yield TestClient(app)


AUTH = {"Authorization": f"Bearer ipad.{DEVICE_SECRET}"}
WORKER = {"Authorization": f"Bearer {WORKER_SECRET}"}


def test_health_and_auth(client):
    assert client.get("/healthz").json() == {"status": "ok"}
    response = client.get("/v1/claude/spend", headers={"Authorization": "Bearer ipad.wrong"})
    assert response.status_code == 401
    assert response.json()["error"]["message"]
    assert client.get("/v1/claude/spend", headers=AUTH).json()["day_usd"] == 0


def test_backup_upload_url_is_presigned_put(client):
    body = {"lecture_id": "6f1c1f0e-4f39-4d1e-9a4e-5a1f3c2b1a00", "name": "part-000.m4a", "sha256": "a" * 64, "bytes": 1200}
    data = client.post("/v1/backup/upload-url", json=body, headers=AUTH).json()
    assert "devices/ipad/lectures/6f1c1f0e-4f39-4d1e-9a4e-5a1f3c2b1a00/part-000.m4a" in data["url"]
    assert data["headers"]["Content-Type"] == "audio/mp4"
    bad = client.post("/v1/backup/upload-url", json={**body, "name": "../etc/passwd"}, headers=AUTH)
    assert bad.status_code == 422


def test_spend_cap(client):
    from app.store import store
    s = store()
    assert s.try_add_spend("ipad", 0.30, 0.50, 5)
    assert not s.try_add_spend("ipad", 0.30, 0.50, 5)   # would pass the daily cap
    s.adjust_spend("ipad", -0.25)
    assert s.try_add_spend("ipad", 0.30, 0.50, 5)
    assert not s.try_add_spend("ipad", 0.60, 0.50, 5)   # larger than the cap itself
    day, month = s.spend("ipad")
    assert round(day, 2) == 0.35 and round(month, 2) == 0.35


def test_home_job_claim_and_result(client):
    payload = {"type": "hq_asr", "lecture_id": "6f1c1f0e-4f39-4d1e-9a4e-5a1f3c2b1a00", "engine": "home", "language": "en"}
    job = client.post("/v1/jobs", json=payload, headers=AUTH).json()
    assert job["status"] == "queued"
    claimed = client.get("/v1/worker/claim?types=hq_asr", headers=WORKER).json()["job"]
    assert claimed["id"] == job["id"]
    assert client.get("/v1/worker/claim?types=hq_asr", headers=WORKER).json()["job"] is None
    client.post(f"/v1/worker/jobs/{job['id']}/result", json={"type": "hq_asr", "segments": []}, headers=WORKER)
    done = client.get(f"/v1/jobs/{job['id']}", headers=AUTH).json()
    assert done["status"] == "done" and done["result_url"].startswith("https://")


class FakeStream:
    def __init__(self, events):
        self.events = events

    def __aiter__(self):
        self._it = iter(self.events)
        return self

    async def __anext__(self):
        try:
            return next(self._it)
        except StopIteration:
            raise StopAsyncIteration


def event(kind, **fields):
    payload = {"type": kind, **{k: v for k, v in fields.items() if k != "obj"}}
    return SimpleNamespace(type=kind, model_dump_json=lambda exclude_none=True: json.dumps(payload, default=vars), **fields)


def test_claude_stream_relays_and_settles_spend(client, monkeypatch):
    from app import claude
    usage = SimpleNamespace(input_tokens=1000, cache_creation_input_tokens=0, cache_read_input_tokens=0)
    events = [
        event("message_start", message=SimpleNamespace(usage=usage)),
        event("content_block_delta", delta={"type": "text_delta", "text": "مرحبا"}),
        event("message_delta", usage=SimpleNamespace(output_tokens=200), delta={"stop_reason": "end_turn"}),
        event("message_stop"),
    ]

    class FakeMessages:
        async def count_tokens(self, **kwargs):
            return SimpleNamespace(input_tokens=1000)

        async def create(self, **kwargs):
            assert kwargs["stream"] is True and kwargs["thinking"] == {"type": "adaptive"}
            assert kwargs["extra_body"] == {"fallbacks": "default"}
            return FakeStream(events)

    monkeypatch.setattr(claude, "async_client", lambda: SimpleNamespace(messages=FakeMessages()))
    body = {"model": "claude-sonnet-5-5", "preamble": "p", "context": "transcript", "user_message": "q", "max_tokens": 4000}
    with client.stream("POST", "/v1/claude/messages", json=body, headers=AUTH) as response:
        text = "".join(response.iter_text())
    assert response.status_code == 200 and "text_delta" in text and "message_stop" in text
    from app.store import store
    day, _ = store().spend("ipad")
    assert abs(day - (1000 * 2 + 200 * 10) / 1e6) < 1e-6   # settled to the real usage


def test_soniox_temp_key(client, monkeypatch):
    from app import soniox

    def fake_post(url, headers, json, timeout):
        assert url == soniox.TEMPORARY_KEY_URL and json["usage_type"] == "transcribe_websocket"
        return SimpleNamespace(status_code=200, json=lambda: {"api_key": "temp:abc", "expires_at": "2026-10-13T10:00:00Z"})

    monkeypatch.setattr(soniox.httpx, "post", fake_post)
    assert client.post("/v1/soniox/temp-key", headers=AUTH).json()["api_key"] == "temp:abc"


def test_claude_refuses_over_cap(client, monkeypatch):
    from app import claude

    class Huge:
        async def count_tokens(self, **kwargs):
            return SimpleNamespace(input_tokens=200_000)   # Opus: 0.80 $ > 0.50 $ daily cap

        async def create(self, **kwargs):
            raise AssertionError("must not call Claude over the cap")

    monkeypatch.setattr(claude, "async_client", lambda: SimpleNamespace(messages=Huge()))
    body = {"model": "claude-opus-5-5", "preamble": "p", "context": "t", "user_message": "q"}
    response = client.post("/v1/claude/messages", json=body, headers=AUTH)
    assert response.status_code == 402
    assert "cap" in response.json()["error"]["message"]


def test_refine_batch_roundtrip(client, monkeypatch):
    """Body shaped like the Swift JSONEncoder output of ServerClient.JobRequest."""
    from app import claude, jobs

    created = {}

    class FakeBatches:
        def create(self, requests):
            created["requests"] = requests
            return SimpleNamespace(id="msgbatch_1")

        def retrieve(self, batch_id):
            return SimpleNamespace(processing_status="ended")

        def results(self, batch_id):
            usage = SimpleNamespace(input_tokens=3000, cache_creation_input_tokens=0, cache_read_input_tokens=0, output_tokens=6000)
            message = SimpleNamespace(content=[SimpleNamespace(type="text", text='{"items":[{"id":"A","translation":"ب"}]}')],
                                      stop_reason="end_turn", usage=usage)
            yield SimpleNamespace(custom_id="chunk-0", result=SimpleNamespace(type="succeeded", message=message))

    fake = SimpleNamespace(messages=SimpleNamespace(batches=FakeBatches()))
    monkeypatch.setattr(jobs, "sync_client", lambda: fake)
    body = {
        "type": "refine_translation", "lecture_id": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F", "engine": "claude-batch",
        "refine": {"model": "claude-haiku-5-5", "preamble": "translate", "context": "GLOSSARY:\nloss = خسارة",
                   "effort": "low", "max_tokens": 16000, "output_schema": '{"type":"object","properties":{},"additionalProperties":false}',
                   "requests": [{"custom_id": "chunk-0", "user_message": "TRANSLATE:\n[A] hello"}]},
    }
    job = client.post("/v1/jobs", json=body, headers=AUTH).json()
    assert job["status"] == "running"
    params = created["requests"][0]["params"]
    assert params["output_config"]["format"]["type"] == "json_schema" and params["system"][1]["cache_control"]
    done = client.get(f"/v1/jobs/{job['id']}", headers=AUTH).json()
    assert done["status"] == "done" and done["result_url"]
    from app import blobs
    result = blobs.get_json(f"jobs/{job['id']}/result.json")
    assert "ب" in result["results"]["chunk-0"]["text"]
