"""HTTP layer: envelope, problem+json, idempotency-key requirement, readiness degradation."""

from typing import Any

from fastapi.testclient import TestClient

from fraud import api
from fraud import service as svc
from fraud.config import Config


def cfg() -> Config:
    return Config(port=0, metrics_port=0, db_dsn="x", redis_url="x", kafka_brokers="x",
                  rabbit_url="x", velocity_window_ms=1000, velocity_threshold=10,
                  profile_ttl_s=60, model_version="rule-v1", build_info_path="/nonexistent")


class StubFraud:
    def run_idempotent(self, key: str | None, endpoint: str, body: dict[str, Any],
                       success_status: int, action: Any) -> tuple[int, dict[str, Any], bool]:
        if not key:
            raise svc.ApiError(400, "dokandar.fraud.request.missing_idempotency_key", "required")
        return success_status, {"echo": endpoint}, False

    def get_hold(self, subject_did: str) -> dict[str, Any] | None:
        return None


def client(healthy: bool = True) -> TestClient:
    app = api.build_app(cfg(), StubFraud(),  # type: ignore[arg-type]
                        lambda did: {"subjectDid": did, "riskScore": 0.1},
                        lambda: {"db": healthy, "redis": healthy})
    return TestClient(app)


def test_write_without_idempotency_key_is_problem_json() -> None:
    r = client().post("/v1/fraud/signals", json={"subjectDid": "did:dokandar:x"})
    assert r.status_code == 400
    assert r.headers["content-type"].startswith("application/problem+json")
    assert r.json()["code"] == "dokandar.fraud.request.missing_idempotency_key"


def test_signal_returns_envelope() -> None:
    r = client().post("/v1/fraud/signals", json={"subjectDid": "did:dokandar:x"},
                      headers={"Idempotency-Key": "k1"})
    assert r.status_code == 201
    body = r.json()
    assert body["success"] is True
    assert body["error"] is None
    assert body["meta"] == {"replayed": False}


def test_score_read_uses_profile_reader() -> None:
    r = client().get("/v1/fraud/scores/did:dokandar:x")
    assert r.status_code == 200
    assert r.json()["data"]["riskScore"] == 0.1


def test_missing_hold_is_404_problem() -> None:
    r = client().get("/v1/fraud/holds/did:dokandar:x")
    assert r.status_code == 404


def test_ready_degrades_to_503() -> None:
    assert client(healthy=True).get("/ready").status_code == 200
    assert client(healthy=False).get("/ready").status_code == 503


def test_oversized_body_is_413() -> None:
    r = client().post("/v1/fraud/signals", content=b"x" * (257 * 1024),
                      headers={"Idempotency-Key": "k", "Content-Type": "application/json"})
    assert r.status_code == 413
