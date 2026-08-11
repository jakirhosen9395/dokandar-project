"""Four-eyes command logic (R4/ADR-006) against monkeypatched stores — no live Postgres."""

from typing import Any

import pytest

from fraud import service as svc
from fraud import stores


class FakeCx:
    def execute(self, *_a: Any, **_k: Any) -> None:
        pass


def _hold(status: str, approver1: str = "did:dokandar:a1") -> stores.PendingHold:
    return stores.PendingHold(subject_did="did:dokandar:s", reason="r", approver1=approver1,
                              status=status, approver2=None, requested_at=1)


@pytest.fixture()
def fraud() -> svc.FraudService:
    class NoRabbit:
        def publish_hold_request(self, message: dict[str, Any]) -> None:
            pass

    return svc.FraudService(pool=None, publisher=NoRabbit())  # type: ignore[arg-type]


def test_approve_rejects_same_approver(fraud: svc.FraudService,
                                       monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(stores, "lock_hold", lambda cx, did: _hold("PENDING"))
    with pytest.raises(svc.ApiError) as e:
        fraud.approve_hold(FakeCx(), "did:dokandar:s", "did:dokandar:a1")  # type: ignore[arg-type]
    assert e.value.status == 409
    assert "same_approver" in e.value.code


def test_approve_emits_account_held_with_both_approvers(
        fraud: svc.FraudService, monkeypatch: pytest.MonkeyPatch) -> None:
    emitted: list[tuple[str, str, str]] = []
    monkeypatch.setattr(stores, "lock_hold", lambda cx, did: _hold("PENDING"))
    monkeypatch.setattr(stores, "transition_hold",
                        lambda cx, did, frm, to, a2, now: True)
    monkeypatch.setattr("fraud.events.account_held",
                        lambda cx, did, a1, a2, now: emitted.append((did, a1, a2)) or "eid")
    out = fraud.approve_hold(FakeCx(), "did:dokandar:s", "did:dokandar:a2")  # type: ignore[arg-type]
    assert out["status"] == "APPROVED"
    assert emitted == [("did:dokandar:s", "did:dokandar:a1", "did:dokandar:a2")]


def test_approve_is_idempotent_on_replay(fraud: svc.FraudService,
                                         monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(stores, "lock_hold", lambda cx, did: _hold("APPROVED"))
    out = fraud.approve_hold(FakeCx(), "did:dokandar:s", "did:dokandar:a2")  # type: ignore[arg-type]
    assert out["status"] == "APPROVED"


def test_release_requires_approved_state(fraud: svc.FraudService,
                                         monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(stores, "lock_hold", lambda cx, did: _hold("PENDING"))
    with pytest.raises(svc.ApiError) as e:
        fraud.release_hold(FakeCx(), "did:dokandar:s",  # type: ignore[arg-type]
                           "did:dokandar:a1", "did:dokandar:a2")
    assert e.value.status == 409


def test_release_rejects_wrong_approvers(fraud: svc.FraudService,
                                         monkeypatch: pytest.MonkeyPatch) -> None:
    approved = stores.PendingHold(subject_did="did:dokandar:s", reason="r",
                                  approver1="did:dokandar:a1", status="APPROVED",
                                  approver2="did:dokandar:a2", requested_at=1, approved_at=2)
    monkeypatch.setattr(stores, "lock_hold", lambda cx, did: approved)
    with pytest.raises(svc.ApiError) as e:
        fraud.release_hold(FakeCx(), "did:dokandar:s",  # type: ignore[arg-type]
                           "did:dokandar:OTHER", "did:dokandar:a2")
    assert "approver_mismatch" in e.value.code


def test_release_requires_two_distinct_approvers(fraud: svc.FraudService) -> None:
    with pytest.raises(svc.ApiError) as e:
        fraud.release_hold(FakeCx(), "did:dokandar:s",  # type: ignore[arg-type]
                           "did:dokandar:a1", "did:dokandar:a1")
    assert "same_approver" in e.value.code


def test_raise_signal_validates_score_range(fraud: svc.FraudService) -> None:
    with pytest.raises(svc.ApiError) as e:
        fraud.raise_signal(FakeCx(), "did:dokandar:s", "CLONE_BATCH", 1.7,  # type: ignore[arg-type]
                           None, "analyst")
    assert "risk_score" in e.value.code


def test_hold_account_conflict_when_open_hold_exists(
        fraud: svc.FraudService, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(stores, "insert_pending_hold",
                        lambda cx, did, reason, a1, ev, now: False)
    with pytest.raises(svc.ApiError) as e:
        fraud.hold_account(FakeCx(), "did:dokandar:s", "reason",  # type: ignore[arg-type]
                           "did:dokandar:a1", None)
    assert e.value.status == 409
    assert "already_open" in e.value.code


def test_parse_evidence_accepts_dict_and_rejects_scalars() -> None:
    assert svc.parse_evidence(None) is None
    assert svc.parse_evidence({"k": 1}) == {"k": 1}
    assert svc.parse_evidence('{"k":2}') == {"k": 2}
    with pytest.raises(svc.ApiError):
        svc.parse_evidence(42)
