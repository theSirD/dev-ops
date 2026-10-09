"""Lab 2 demo API: RED metrics, JSON logs with trace_id, OpenTelemetry traces."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import random
import time
from typing import Any

import httpx
from fastapi import FastAPI, Request, Response
from fastapi.responses import PlainTextResponse
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace import Status, StatusCode
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

SERVICE_NAME = os.getenv("OTEL_SERVICE_NAME", "api")
PORT = int(os.getenv("PORT", "8000"))
metrics_unavailable_until = 0.0


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        span = trace.get_current_span()
        ctx = span.get_span_context() if span is not None else None
        if ctx is not None and ctx.is_valid:
            trace_id = format(ctx.trace_id, "032x")
            span_id = format(ctx.span_id, "016x")
        else:
            trace_id = "0" * 32
            span_id = "0" * 16

        payload: dict[str, Any] = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "level": record.levelname.lower(),
            "service": SERVICE_NAME,
            "msg": record.getMessage(),
            "trace_id": trace_id,
            "span_id": span_id,
        }
        for key in ("path", "method", "status_code", "duration_ms", "error"):
            if hasattr(record, key):
                payload[key] = getattr(record, key)
        return json.dumps(payload, ensure_ascii=False)


def setup_logging() -> logging.Logger:
    handler = logging.StreamHandler()
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(logging.INFO)
    return logging.getLogger(SERVICE_NAME)


def setup_tracing() -> trace.Tracer:
    endpoint = os.getenv(
        "OTEL_EXPORTER_OTLP_ENDPOINT",
        "http://jaeger-collector.monitoring.svc.cluster.local:4318",
    ).rstrip("/")
    # SDK expects the traces path for the HTTP exporter.
    if not endpoint.endswith("/v1/traces"):
        traces_endpoint = f"{endpoint}/v1/traces"
    else:
        traces_endpoint = endpoint

    resource = Resource.create({"service.name": SERVICE_NAME})
    provider = TracerProvider(resource=resource)
    provider.add_span_processor(
        BatchSpanProcessor(OTLPSpanExporter(endpoint=traces_endpoint))
    )
    trace.set_tracer_provider(provider)
    return trace.get_tracer(SERVICE_NAME)


logger = setup_logging()
tracer = setup_tracing()

REQUESTS = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "path", "code"],
)
ERRORS = Counter(
    "http_errors_total",
    "Total HTTP 5xx responses",
    ["method", "path"],
)
LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds",
    ["method", "path"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0),
)

app = FastAPI(title="lab2-api")
FastAPIInstrumentor.instrument_app(app, excluded_urls="metrics,health")
HTTPXClientInstrumentor().instrument()


def _normalize_path(path: str) -> str:
    if path.startswith("/fail"):
        return "/fail"
    if path.startswith("/slow"):
        return "/slow"
    if path.startswith("/load"):
        return "/load"
    if path.startswith("/down"):
        return "/down"
    if path.startswith("/health"):
        return "/health"
    if path.startswith("/metrics"):
        return "/metrics"
    return path


@app.middleware("http")
async def metrics_middleware(request: Request, call_next):
    if request.url.path == "/metrics":
        return await call_next(request)

    path = _normalize_path(request.url.path)
    method = request.method
    start = time.perf_counter()
    response: Response | None = None
    with tracer.start_as_current_span(f"{method} {path}") as span:
        try:
            response = await call_next(request)
            return response
        except Exception as exc:
            span.set_status(Status(StatusCode.ERROR, str(exc)))
            span.record_exception(exc)
            raise
        finally:
            duration = time.perf_counter() - start
            code = str(response.status_code if response is not None else 500)
            REQUESTS.labels(method=method, path=path, code=code).inc()
            LATENCY.labels(method=method, path=path).observe(duration)
            if code.startswith("5"):
                ERRORS.labels(method=method, path=path).inc()
                span.set_status(Status(StatusCode.ERROR, f"HTTP {code}"))
            logger.info(
                "request completed",
                extra={
                    "path": path,
                    "method": method,
                    "status_code": int(code),
                    "duration_ms": round(duration * 1000, 2),
                },
            )


@app.get("/health")
async def health() -> PlainTextResponse:
    return PlainTextResponse("ok")


@app.get("/fail")
async def fail() -> PlainTextResponse:
    span = trace.get_current_span()
    span.set_status(Status(StatusCode.ERROR, "intentional failure"))
    span.record_exception(RuntimeError("intentional failure from /fail"))
    logger.error(
        "intentional failure",
        extra={"path": "/fail", "method": "GET", "status_code": 500, "error": True},
    )
    return PlainTextResponse("internal error", status_code=500)


@app.get("/slow")
async def slow() -> dict[str, Any]:
    delay = random.uniform(1.0, 3.0)
    with tracer.start_as_current_span("slow-op") as span:
        span.set_attribute("delay.seconds", delay)
        await asyncio.sleep(delay)
    return {"status": "slow", "delay_seconds": round(delay, 3)}


@app.get("/load")
async def load() -> dict[str, Any]:
    """Fire a burst of requests at this service to spike RPS."""
    base = os.getenv("SELF_BASE_URL", f"http://127.0.0.1:{PORT}")
    paths = ["/health", "/health", "/slow", "/fail"]
    results: dict[str, int] = {}

    async with httpx.AsyncClient(timeout=10.0) as client:
        tasks = [client.get(f"{base}{random.choice(paths)}") for _ in range(40)]
        responses = await asyncio.gather(*tasks, return_exceptions=True)

    for item in responses:
        if isinstance(item, Exception):
            key = "exception"
        else:
            key = str(item.status_code)
        results[key] = results.get(key, 0) + 1

    logger.info("load burst finished", extra={"path": "/load", "method": "GET"})
    return {"fired": 40, "results": results}


@app.get("/down")
async def down(seconds: int = 90) -> dict[str, Any]:
    """Temporarily make the Prometheus scrape fail to demonstrate ApiDown."""
    global metrics_unavailable_until

    duration = min(max(seconds, 75), 300)
    metrics_unavailable_until = time.monotonic() + duration
    logger.warning(
        "synthetic scrape outage enabled",
        extra={"path": "/down", "method": "GET", "duration_ms": duration * 1000},
    )
    return {"status": "scrape outage enabled", "seconds": duration}


@app.get("/metrics")
async def metrics() -> Response:
    remaining = metrics_unavailable_until - time.monotonic()
    if remaining > 0:
        return PlainTextResponse(
            f"synthetic scrape outage; retry in {remaining:.0f}s",
            status_code=503,
        )
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=PORT)
