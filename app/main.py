from __future__ import annotations

import os
import re
import time
from datetime import datetime, timezone
from typing import Final

from fastapi import FastAPI, Request
from prometheus_client import CONTENT_TYPE_LATEST, CollectorRegistry, Counter, Histogram, generate_latest
from starlette.middleware.base import RequestResponseEndpoint
from starlette.responses import Response

SERVICE_NAME: Final = "linux-web-api"
STARTED_AT: Final = time.monotonic()
REGISTRY: Final = CollectorRegistry(auto_describe=True)
HTTP_REQUESTS: Final = Counter(
    "http_requests_total",
    "Total HTTP requests handled by the application.",
    ("method", "route", "status"),
    registry=REGISTRY,
)
HTTP_REQUEST_DURATION: Final = Histogram(
    "http_request_duration_seconds",
    "HTTP request duration in seconds.",
    ("method", "route"),
    registry=REGISTRY,
)


def _read_setting(name: str, default: str, pattern: str) -> str:
    value = os.environ.get(name, default)
    if not re.fullmatch(pattern, value):
        raise ValueError(f"{name} has an invalid value")
    return value


APP_ENV: Final = _read_setting("APP_ENV", "local", r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}")
APP_VERSION: Final = _read_setting("APP_VERSION", "dev", r"[a-zA-Z0-9][a-zA-Z0-9._+-]{0,63}")

ENABLE_API_DOCS: Final = os.environ.get("ENABLE_API_DOCS", "false").lower()
if ENABLE_API_DOCS not in {"true", "false"}:
    raise ValueError("ENABLE_API_DOCS must be true or false")
API_DOCS_ENABLED: Final = ENABLE_API_DOCS == "true"

app = FastAPI(
    title="Linux Web Infrastructure API",
    docs_url="/docs" if API_DOCS_ENABLED else None,
    redoc_url="/redoc" if API_DOCS_ENABLED else None,
    openapi_url="/openapi.json" if API_DOCS_ENABLED else None,
)


@app.middleware("http")
async def record_http_metrics(
    request: Request,
    call_next: RequestResponseEndpoint,
) -> Response:
    if request.url.path == "/metrics":
        return await call_next(request)

    started = time.perf_counter()
    status_code = 500
    try:
        response = await call_next(request)
        status_code = response.status_code
        return response
    finally:
        route = request.scope.get("route")
        route_name = getattr(route, "path", "unmatched")
        method = request.method if request.method in {"GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"} else "OTHER"
        HTTP_REQUESTS.labels(method, route_name, str(status_code)).inc()
        HTTP_REQUEST_DURATION.labels(method, route_name).observe(time.perf_counter() - started)


@app.get("/health", tags=["health"])
def health() -> dict[str, str]:
    return {
        "status": "ok",
        "service": SERVICE_NAME,
        "version": APP_VERSION,
    }


@app.get("/livez", include_in_schema=False)
def liveness() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/readyz", include_in_schema=False)
def readiness() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/info", tags=["information"])
def info() -> dict[str, str | int]:
    return {
        "service": SERVICE_NAME,
        "environment": APP_ENV,
        "version": APP_VERSION,
        "uptime_seconds": int(time.monotonic() - STARTED_AT),
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/metrics", include_in_schema=False)
def metrics() -> Response:
    return Response(generate_latest(REGISTRY), media_type=CONTENT_TYPE_LATEST)
