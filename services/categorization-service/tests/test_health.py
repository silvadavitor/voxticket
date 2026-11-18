"""O serviço sobe e responde /health mesmo sem banco e sem broker (R6)."""

import os

os.environ.setdefault("BROKER_URL", "amqp://guest:guest@127.0.0.1:1/")
os.environ.setdefault("DB_HOST", "127.0.0.1")
os.environ.setdefault("DB_PORT", "1")

from fastapi.testclient import TestClient  # noqa: E402

from app.main import app  # noqa: E402


def test_health_sem_infra():
    with TestClient(app) as client:
        r = client.get("/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert body["broker"] == "down" and body["db"] == "down"
