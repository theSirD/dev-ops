"""Shop API: orders backed by the CloudNativePG PostgreSQL cluster."""

from __future__ import annotations

import os
import random
import time
from contextlib import asynccontextmanager

import psycopg
from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import PlainTextResponse
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from pydantic import BaseModel, Field

DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "postgresql://app:app@postgres-rw:5432/shop",
)

VERSION = os.getenv("VERSION", "v1")
# v2 test switch: every POST /order fails with 500
FAIL = os.getenv("FAIL", "false").lower() == "true"
# v1 test switch: a random share of POST /order fails with 500
FLAKY = os.getenv("FLAKY", "false").lower() == "true"
FLAKY_RATE = float(os.getenv("FLAKY_RATE", "0.3"))

REQUESTS = Counter(
    "shop_http_requests_total",
    "Shop API HTTP requests",
    ["method", "path", "code"],
)
LATENCY = Histogram(
    "shop_http_request_duration_seconds",
    "Shop API request latency",
    ["method", "path"],
)


def connection() -> psycopg.Connection:
    return psycopg.connect(DATABASE_URL, connect_timeout=3)


def initialize_schema() -> None:
    with connection() as conn, conn.cursor() as cur:
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS orders (
                id BIGSERIAL PRIMARY KEY,
                customer TEXT NOT NULL,
                item TEXT NOT NULL,
                processed BOOLEAN NOT NULL DEFAULT FALSE,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )
            """
        )


@asynccontextmanager
async def lifespan(_: FastAPI):
    # CNPG can start after API; endpoints return 503 until the database is ready.
    try:
        initialize_schema()
    except psycopg.Error:
        pass
    yield


app = FastAPI(title="shop-api", lifespan=lifespan)


@app.middleware("http")
async def metrics(request: Request, call_next):
    if request.url.path == "/metrics":
        return await call_next(request)
    started = time.perf_counter()
    response: Response | None = None
    try:
        response = await call_next(request)
        return response
    finally:
        code = str(response.status_code if response else 500)
        path = request.url.path
        REQUESTS.labels(request.method, path, code).inc()
        LATENCY.labels(request.method, path).observe(time.perf_counter() - started)


class OrderIn(BaseModel):
    customer: str = Field(min_length=1, max_length=128)
    item: str = Field(min_length=1, max_length=128)


@app.get("/version")
def version() -> PlainTextResponse:
    return PlainTextResponse(VERSION)


@app.get("/health")
def health() -> PlainTextResponse:
    if os.getenv("HEALTH_FAIL", "false").lower() == "true":
        return PlainTextResponse("health intentionally failed", status_code=500)
    return PlainTextResponse("ok")


@app.get("/fail")
def fail() -> PlainTextResponse:
    """Controlled 5xx endpoint used only to demonstrate the API error-rate alert."""
    return PlainTextResponse("intentional failure", status_code=500)


@app.post("/order", status_code=201)
def create_order(order: OrderIn) -> dict[str, object]:
    # fail before touching the database, so a retried order is never stored twice
    if FAIL or (FLAKY and random.random() < FLAKY_RATE):
        raise HTTPException(status_code=500, detail="injected failure")
    try:
        initialize_schema()
        with connection() as conn, conn.cursor() as cur:
            cur.execute(
                "INSERT INTO orders (customer, item) VALUES (%s, %s) RETURNING id, processed",
                (order.customer, order.item),
            )
            order_id, processed = cur.fetchone()
    except psycopg.Error as error:
        raise HTTPException(status_code=503, detail="database unavailable") from error
    return {"id": order_id, "customer": order.customer, "item": order.item, "processed": processed}


@app.get("/orders")
def list_orders() -> list[dict[str, object]]:
    try:
        initialize_schema()
        with connection() as conn, conn.cursor() as cur:
            cur.execute(
                "SELECT id, customer, item, processed, created_at FROM orders ORDER BY id"
            )
            rows = cur.fetchall()
    except psycopg.Error as error:
        raise HTTPException(status_code=503, detail="database unavailable") from error
    return [
        {
            "id": row[0],
            "customer": row[1],
            "item": row[2],
            "processed": row[3],
            "created_at": row[4].isoformat(),
        }
        for row in rows
    ]


@app.get("/metrics")
def prometheus_metrics() -> Response:
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
