"""Exactly-once command envelope: fresh run, replay, body-conflict, failure replay."""

from typing import Any

import pytest

from fraud import service as svc
from fraud import stores


class FakeCx:
    def __init__(self) -> None:
        self.committed = False
        self.rolled_back = False

    def commit(self) -> None:
        self.committed = True

    def rollback(self) -> None:
        self.rolled_back = True

    def execute(self, *_a: Any, **_k: Any) -> None:
        pass


class FakePool:
    def __init__(self) -> None:
        self.cx = FakeCx()

    def connection(self) -> Any:
        pool = self

        class _Ctx:
            def __enter__(self) -> FakeCx:
                return pool.cx

            def __exit__(self, *a: Any) -> None:
                return None

        return _Ctx()


class NoRabbit:
    def __init__(self) -> None:
        self.published: list[dict[str, Any]] = []

    def publish_hold_request(self, message: dict[str, Any]) -> None:
        self.published.append(message)


@pytest.fixture()
def env(monkeypatch: pytest.MonkeyPatch) -> tuple[svc.FraudService, NoRabbit, list[Any]]:
    inserted: list[Any] = []
    monkeypatch.setattr(stores, "idem_find", lambda cx, k, e: None)
    monkeypatch.setattr(stores, "idem_insert",
                        lambda cx, k, e, h, s, b, n: inserted.append((k, s, b)))
    rabbit = NoRabbit()
    return svc.FraudService(FakePool(), rabbit), rabbit, inserted  # type: ignore[arg-type]


def test_fresh_command_stores_response_and_commits(
        env: tuple[svc.FraudService, NoRabbit, list[Any]]) -> None:
    fraud, _rabbit, inserted = env
    status, data, replayed = fraud.run_idempotent("k1", "POST /x", {"a": 1}, 201,
                                                  lambda cx: {"ok": True})
    assert (status, replayed) == (201, False)
    assert data == {"ok": True}
    assert inserted[0][1] == 201


def test_rabbit_message_publishes_post_commit_only(
        env: tuple[svc.FraudService, NoRabbit, list[Any]]) -> None:
    fraud, rabbit, _ = env
    _, data, _ = fraud.run_idempotent("k2", "POST /x", {}, 202,
                                      lambda cx: {"ok": 1, "__rabbit": {"m": "hold"}})
    assert rabbit.published == [{"m": "hold"}]
    assert "__rabbit" not in data  # the queue side-channel never leaks into the response


def test_replay_returns_stored_body(monkeypatch: pytest.MonkeyPatch) -> None:
    body = {"a": 1}
    stored = stores.StoredResponse(request_hash=stores.request_hash(body), status=201,
                                   body={"ord": "X"})
    monkeypatch.setattr(stores, "idem_find", lambda cx, k, e: stored)
    fraud = svc.FraudService(FakePool(), NoRabbit())  # type: ignore[arg-type]
    status, data, replayed = fraud.run_idempotent("k", "POST /x", body, 201,
                                                  lambda cx: pytest.fail("must not run"))
    assert (status, data, replayed) == (201, {"ord": "X"}, True)


def test_replay_with_different_body_is_conflict(monkeypatch: pytest.MonkeyPatch) -> None:
    stored = stores.StoredResponse(request_hash="other", status=201, body={})
    monkeypatch.setattr(stores, "idem_find", lambda cx, k, e: stored)
    fraud = svc.FraudService(FakePool(), NoRabbit())  # type: ignore[arg-type]
    with pytest.raises(svc.ApiError) as e:
        fraud.run_idempotent("k", "POST /x", {"a": 2}, 201, lambda cx: {})
    assert "idempotency_key_reuse" in e.value.code


def test_stored_business_failure_replays_as_same_error(
        monkeypatch: pytest.MonkeyPatch) -> None:
    body = {"a": 1}
    stored = stores.StoredResponse(
        request_hash=stores.request_hash(body), status=409,
        body={"__error": {"code": "dokandar.fraud.hold.already_open", "message": "open"}})
    monkeypatch.setattr(stores, "idem_find", lambda cx, k, e: stored)
    fraud = svc.FraudService(FakePool(), NoRabbit())  # type: ignore[arg-type]
    with pytest.raises(svc.ApiError) as e:
        fraud.run_idempotent("k", "POST /x", body, 201, lambda cx: {})
    assert e.value.status == 409
    assert e.value.code == "dokandar.fraud.hold.already_open"


def test_business_failure_is_persisted_for_replay(
        env: tuple[svc.FraudService, NoRabbit, list[Any]]) -> None:
    fraud, _rabbit, inserted = env

    def boom(cx: Any) -> dict[str, Any]:
        raise svc.ApiError(409, "dokandar.fraud.hold.already_open", "open")

    with pytest.raises(svc.ApiError):
        fraud.run_idempotent("k9", "POST /x", {}, 202, boom)
    assert inserted and inserted[0][1] == 409
    assert "__error" in inserted[0][2]


def test_missing_key_rejected(env: tuple[svc.FraudService, NoRabbit, list[Any]]) -> None:
    fraud, _r, _i = env
    with pytest.raises(svc.ApiError) as e:
        fraud.run_idempotent(None, "POST /x", {}, 200, lambda cx: {})
    assert "missing_idempotency_key" in e.value.code


def test_hold_account_happy_path_returns_rabbit_side_channel(
        monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(stores, "insert_pending_hold",
                        lambda cx, did, reason, a1, ev, now: True)
    fraud = svc.FraudService(FakePool(), NoRabbit())  # type: ignore[arg-type]
    out = fraud.hold_account(FakeCx(), "did:dokandar:s", "HOARDING",  # type: ignore[arg-type]
                             "did:dokandar:a1", {"caseRef": "x"})
    assert out["status"] == "PENDING"
    assert out["__rabbit"]["type"] == "AccountHoldRequested"


def test_release_happy_path_emits_event(monkeypatch: pytest.MonkeyPatch) -> None:
    from fraud.stores import PendingHold
    emitted: list[str] = []
    monkeypatch.setattr(stores, "lock_hold", lambda cx, did: PendingHold(
        subject_did=did, reason="r", approver1="did:dokandar:a1", status="APPROVED",
        approver2="did:dokandar:a2", requested_at=1))
    monkeypatch.setattr(stores, "transition_hold", lambda cx, did, f, t, a2, now: True)
    monkeypatch.setattr(stores, "delete_hold", lambda cx, did: None)
    monkeypatch.setattr("fraud.events.account_hold_released",
                        lambda cx, did, now: emitted.append(did) or "eid")
    fraud = svc.FraudService(FakePool(), NoRabbit())  # type: ignore[arg-type]
    out = fraud.release_hold(FakeCx(), "did:dokandar:s",  # type: ignore[arg-type]
                             "did:dokandar:a1", "did:dokandar:a2")
    assert out["status"] == "RELEASED"
    assert emitted == ["did:dokandar:s"]


def test_raise_signal_happy_path(monkeypatch: pytest.MonkeyPatch) -> None:
    rows: list[Any] = []
    monkeypatch.setattr(stores, "insert_signal",
                        lambda cx, sid, did, r, s, ev, by, now: rows.append(sid))
    monkeypatch.setattr("fraud.events.fraud_signal_raised",
                        lambda cx, did, r, s, now: "eid")
    fraud = svc.FraudService(FakePool(), NoRabbit())  # type: ignore[arg-type]
    out = fraud.raise_signal(FakeCx(), "did:dokandar:s", "CLONE_BATCH",  # type: ignore[arg-type]
                             0.66, None, "analyst")
    assert out["signalId"].startswith("FSG-")
    assert rows
