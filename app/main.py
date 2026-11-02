from datetime import datetime, timezone

from fastapi import FastAPI

app = FastAPI(
    title="Linux Web Infrastructure API",
    docs_url=None,
    redoc_url=None,
)


@app.get("/health")
def health():
    return {
        "status": "ok",
        "service": "linux-web-api",
    }


@app.get("/info")
def info():
    return {
        "service": "linux-web-api",
        "environment": "wsl2-local",
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }
