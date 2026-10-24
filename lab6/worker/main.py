"""Background order processor with a small health/metrics HTTP server."""

from __future__ import annotations

import asyncio
import os
from contextlib import asynccontextmanager, suppress

import psycopg
from fastapi import FastAPI, Response
from fastapi.responses import PlainTextResponse
from prometheus_client import CONTENT_TYPE_LATEST, Counter, generate_latest

DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "postgresql://app:app@postgres-rw:5432/shop",
)
PROCESSED = Counter("shop_worker_orders_processed_total", "Orders processed by worker")


def process_one() -> bool:
    with psycopg.connect(DATABASE_URL, connect_timeout=3) as conn, conn.cursor() as cur:
        cur.execute(
            """
            WITH next_order AS (
                SELECT id FROM orders
                WHERE NOT processed
                ORDER BY id
                FOR UPDATE SKIP LOCKED
                LIMIT 1
            )
            UPDATE orders SET processed = TRUE
            WHERE id IN (SELECT id FROM next_order)
            RETURNING id
            """
        )
        processed = cur.fetchone() is not None
    return processed


async def consume_orders() -> None:
    while True:
        try:
            # psycopg is blocking; run it off the event loop so /health keeps answering
            if await asyncio.to_thread(process_one):
                PROCESSED.inc()
                continue
        except psycopg.Error:
            pass
        await asyncio.sleep(1)


@asynccontextmanager
async def lifespan(_: FastAPI):
    task = asyncio.create_task(consume_orders())
    yield
    task.cancel()
    with suppress(asyncio.CancelledError):
        await task


app = FastAPI(title="shop-worker", lifespan=lifespan)


@app.get("/health")
def health() -> PlainTextResponse:
    return PlainTextResponse("ok")


@app.get("/metrics")
def metrics() -> Response:
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
