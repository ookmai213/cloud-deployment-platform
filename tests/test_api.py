from fastapi.testclient import TestClient

from app.main import APP_VERSION, SERVICE_NAME, app

client = TestClient(app)


def test_health_preserves_legacy_fields_and_reports_version() -> None:
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {
        "status": "ok",
        "service": SERVICE_NAME,
        "version": APP_VERSION,
    }


def test_info_reports_safe_runtime_information() -> None:
    response = client.get("/info")
    data = response.json()

    assert response.status_code == 200
    assert data["service"] == SERVICE_NAME
    assert data["version"] == APP_VERSION
    assert data["environment"] == "local"
    assert isinstance(data["uptime_seconds"], int)
    assert "timestamp" in data
    assert "instance_id" not in data


def test_liveness_and_readiness_are_available() -> None:
    assert client.get("/livez").json() == {"status": "ok"}
    assert client.get("/readyz").json() == {"status": "ok"}


def test_api_documentation_is_disabled_by_default() -> None:
    assert client.get("/docs").status_code == 404
    assert client.get("/redoc").status_code == 404
    assert client.get("/openapi.json").status_code == 404


def test_metrics_include_request_counts_without_raw_paths() -> None:
    client.get("/health")
    client.get("/not-a-real-route-with-id-12345")

    response = client.get("/metrics")

    assert response.status_code == 200
    assert "http_requests_total" in response.text
    assert 'route="unmatched"' in response.text
    assert "/not-a-real-route-with-id-12345" not in response.text
