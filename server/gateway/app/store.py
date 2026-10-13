"""State: spend counters, rate limits and jobs. DynamoDB on AWS, SQLite for local runs."""
from __future__ import annotations

import json
import sqlite3
import threading
import time
from datetime import datetime, timezone
from decimal import Decimal
from functools import lru_cache
from typing import Any, Protocol

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

from .config import settings


def _periods() -> tuple[str, str]:
    now = datetime.now(timezone.utc)
    return now.strftime("DAY#%Y-%m-%d"), now.strftime("MONTH#%Y-%m")


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


class Store(Protocol):
    def try_add_spend(self, device: str, usd: float, day_cap: float, month_cap: float) -> bool: ...
    def adjust_spend(self, device: str, delta: float) -> None: ...
    def spend(self, device: str) -> tuple[float, float]: ...
    def hit(self, key: str, window_seconds: int) -> int: ...
    def put_job(self, job: dict[str, Any]) -> None: ...
    def get_job(self, job_id: str) -> dict[str, Any] | None: ...
    def update_job(self, job_id: str, **fields: Any) -> None: ...
    def claim_job(self, types: list[str], worker: str) -> dict[str, Any] | None: ...


def _dec(value: float) -> Decimal:
    return Decimal(str(round(value, 6)))


class DynamoStore:
    """Single table: pk/sk strings, GSI 'gsi1' (gsi1pk, gsi1sk) holds queued home-worker jobs, TTL on 'ttl'."""

    def __init__(self, table_name: str) -> None:
        self.table = boto3.resource("dynamodb").Table(table_name)

    # Spend ---------------------------------------------------------------------------------------
    def _add(self, pk: str, sk: str, usd: float, cap: float | None, ttl_days: int) -> bool:
        kwargs: dict[str, Any] = {
            "Key": {"pk": pk, "sk": sk},
            "UpdateExpression": "ADD usd :x SET #ttl = :ttl",
            "ExpressionAttributeNames": {"#ttl": "ttl"},
            "ExpressionAttributeValues": {":x": _dec(usd), ":ttl": int(time.time()) + ttl_days * 86400},
        }
        if cap is not None:
            kwargs["ConditionExpression"] = "attribute_not_exists(usd) OR usd <= :room"
            kwargs["ExpressionAttributeValues"][":room"] = _dec(cap - usd)
        try:
            self.table.update_item(**kwargs)
            return True
        except ClientError as error:
            if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
                return False
            raise

    def try_add_spend(self, device: str, usd: float, day_cap: float, month_cap: float) -> bool:
        if usd > min(day_cap, month_cap):
            return False
        day, month = _periods()
        pk = f"SPEND#{device}"
        if not self._add(pk, day, usd, day_cap, 40):
            return False
        if not self._add(pk, month, usd, month_cap, 400):
            self._add(pk, day, -usd, None, 40)  # roll the day counter back
            return False
        return True

    def adjust_spend(self, device: str, delta: float) -> None:
        if abs(delta) < 1e-7:
            return
        day, month = _periods()
        self._add(f"SPEND#{device}", day, delta, None, 40)
        self._add(f"SPEND#{device}", month, delta, None, 400)

    def spend(self, device: str) -> tuple[float, float]:
        day, month = _periods()
        values = []
        for sk in (day, month):
            item = self.table.get_item(Key={"pk": f"SPEND#{device}", "sk": sk}).get("Item") or {}
            values.append(float(item.get("usd", 0)))
        return values[0], values[1]

    # Rate limit ----------------------------------------------------------------------------------
    def hit(self, key: str, window_seconds: int) -> int:
        window = int(time.time()) // window_seconds
        response = self.table.update_item(
            Key={"pk": f"RATE#{key}#{window}", "sk": "-"},
            UpdateExpression="ADD hits :one SET #ttl = :ttl",
            ExpressionAttributeNames={"#ttl": "ttl"},
            ExpressionAttributeValues={":one": 1, ":ttl": int(time.time()) + 2 * window_seconds},
            ReturnValues="UPDATED_NEW",
        )
        return int(response["Attributes"]["hits"])

    # Jobs ----------------------------------------------------------------------------------------
    def put_job(self, job: dict[str, Any]) -> None:
        item = {"pk": f"JOB#{job['id']}", "sk": "-", "ttl": int(time.time()) + 45 * 86400, **_to_dynamo(job)}
        if job.get("status") == "queued" and job.get("engine") == "home":
            item["gsi1pk"] = f"QUEUE#{job['type']}"
            item["gsi1sk"] = job["created_at"]
        self.table.put_item(Item=item)

    def get_job(self, job_id: str) -> dict[str, Any] | None:
        item = self.table.get_item(Key={"pk": f"JOB#{job_id}", "sk": "-"}).get("Item")
        return _from_dynamo(item) if item else None

    def update_job(self, job_id: str, **fields: Any) -> None:
        fields = {k: v for k, v in fields.items() if v is not None}
        fields["updated_at"] = utc_now()
        names = {f"#{k}": k for k in fields}
        values = {f":{k}": v for k, v in _to_dynamo(fields).items()}
        expression = "SET " + ", ".join(f"#{k} = :{k}" for k in fields)
        if fields.get("status") in ("running", "done", "failed"):
            expression += " REMOVE gsi1pk, gsi1sk"
        self.table.update_item(
            Key={"pk": f"JOB#{job_id}", "sk": "-"},
            UpdateExpression=expression,
            ExpressionAttributeNames=names,
            ExpressionAttributeValues=values,
        )

    def claim_job(self, types: list[str], worker: str) -> dict[str, Any] | None:
        for job_type in types:
            response = self.table.query(
                IndexName="gsi1",
                KeyConditionExpression=Key("gsi1pk").eq(f"QUEUE#{job_type}"),
                Limit=5,
            )
            for item in response.get("Items", []):
                job_id = item["pk"].removeprefix("JOB#")
                try:
                    self.table.update_item(
                        Key={"pk": item["pk"], "sk": "-"},
                        UpdateExpression="SET #s = :running, worker = :w, updated_at = :now REMOVE gsi1pk, gsi1sk",
                        ConditionExpression="#s = :queued",
                        ExpressionAttributeNames={"#s": "status"},
                        ExpressionAttributeValues={
                            ":running": "running", ":queued": "queued", ":w": worker, ":now": utc_now(),
                        },
                    )
                except ClientError as error:
                    if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
                        continue  # another worker took it
                    raise
                return self.get_job(job_id)
        return None


def _to_dynamo(values: dict[str, Any]) -> dict[str, Any]:
    return {k: (_dec(v) if isinstance(v, float) else v) for k, v in values.items() if v is not None}


def _from_dynamo(item: dict[str, Any]) -> dict[str, Any]:
    out = {k: (float(v) if isinstance(v, Decimal) else v) for k, v in item.items()}
    for key in ("pk", "sk", "gsi1pk", "gsi1sk", "ttl"):
        out.pop(key, None)
    return out


class SqliteStore:
    """Same behaviour for local development (`docker run` without AWS)."""

    def __init__(self, path: str) -> None:
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.lock = threading.Lock()
        with self.lock, self.db:
            self.db.execute("CREATE TABLE IF NOT EXISTS spend (device TEXT, period TEXT, usd REAL, PRIMARY KEY (device, period))")
            self.db.execute("CREATE TABLE IF NOT EXISTS rate (key TEXT PRIMARY KEY, hits INTEGER)")
            self.db.execute("CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, body TEXT)")

    def _get(self, device: str, period: str) -> float:
        row = self.db.execute("SELECT usd FROM spend WHERE device=? AND period=?", (device, period)).fetchone()
        return row[0] if row else 0.0

    def _add(self, device: str, period: str, usd: float) -> None:
        self.db.execute(
            "INSERT INTO spend VALUES (?, ?, ?) ON CONFLICT(device, period) DO UPDATE SET usd = usd + excluded.usd",
            (device, period, usd),
        )

    def try_add_spend(self, device: str, usd: float, day_cap: float, month_cap: float) -> bool:
        day, month = _periods()
        with self.lock, self.db:
            if self._get(device, day) + usd > day_cap or self._get(device, month) + usd > month_cap:
                return False
            self._add(device, day, usd)
            self._add(device, month, usd)
            return True

    def adjust_spend(self, device: str, delta: float) -> None:
        day, month = _periods()
        with self.lock, self.db:
            self._add(device, day, delta)
            self._add(device, month, delta)

    def spend(self, device: str) -> tuple[float, float]:
        day, month = _periods()
        with self.lock:
            return self._get(device, day), self._get(device, month)

    def hit(self, key: str, window_seconds: int) -> int:
        bucket = f"{key}#{int(time.time()) // window_seconds}"
        with self.lock, self.db:
            self.db.execute(
                "INSERT INTO rate VALUES (?, 1) ON CONFLICT(key) DO UPDATE SET hits = hits + 1", (bucket,)
            )
            return self.db.execute("SELECT hits FROM rate WHERE key=?", (bucket,)).fetchone()[0]

    def put_job(self, job: dict[str, Any]) -> None:
        with self.lock, self.db:
            self.db.execute("INSERT OR REPLACE INTO jobs VALUES (?, ?)", (job["id"], json.dumps(job)))

    def get_job(self, job_id: str) -> dict[str, Any] | None:
        with self.lock:
            row = self.db.execute("SELECT body FROM jobs WHERE id=?", (job_id,)).fetchone()
        return json.loads(row[0]) if row else None

    def update_job(self, job_id: str, **fields: Any) -> None:
        job = self.get_job(job_id)
        if job is None:
            return
        job.update({k: v for k, v in fields.items() if v is not None}, updated_at=utc_now())
        self.put_job(job)

    def claim_job(self, types: list[str], worker: str) -> dict[str, Any] | None:
        with self.lock:
            rows = self.db.execute("SELECT body FROM jobs").fetchall()
        queued = sorted(
            (json.loads(r[0]) for r in rows),
            key=lambda j: j.get("created_at", ""),
        )
        for job in queued:
            if job.get("status") == "queued" and job.get("engine") == "home" and job.get("type") in types:
                self.update_job(job["id"], status="running", worker=worker)
                return self.get_job(job["id"])
        return None


@lru_cache(maxsize=1)
def store() -> Store:
    config = settings()
    if config.store_backend == "dynamodb":
        return DynamoStore(config.table_name)
    return SqliteStore(config.sqlite_path)
