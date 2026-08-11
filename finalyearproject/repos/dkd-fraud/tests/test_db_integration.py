"""FRAUD-07: real DB integration coverage of the four-eyes hold flow and the WORM signal append —
exercising the previously coverage-omitted db.py/stores layer against a real Postgres (not FakeCx).
Skips unless DKD_TEST_DB_DSN is set (the integration CI stage)."""
from __future__ import annotations

import os

import psycopg
import pytest

from fraud import db, service as svc


class NoRabbit:
    def publish_hold_request(self, message: dict) -> None:  # noqa: D401
        pass


DSN = os.getenv("DKD_TEST_DB_DSN")
pytestmark = pytest.mark.skipif(not DSN, reason="DKD_TEST_DB_DSN not set — integration DB required")


@pytest.fixture()
def cx():
    db.migrate(_pool(), 0)  # ensure schema
    conn = psycopg.connect(DSN)  # type: ignore[arg-type]
    yield conn
    conn.rollback()
    conn.close()


def _pool():
    from psycopg_pool import ConnectionPool
    p = ConnectionPool(DSN, min_size=1, max_size=2, open=True)  # type: ignore[arg-type]
    p.wait(timeout=15)
    return p


def _fraud() -> svc.FraudService:
    return svc.FraudService(pool=None, publisher=NoRabbit())  # type: ignore[arg-type]


def _did(tag: str) -> str:
    import uuid
    return f"did:dokandar:{uuid.uuid4()}-{tag}"


def test_four_eyes_hold_flow_real_db(cx):
    f = _fraud()
    subject, a1, a2 = _did("subj"), _did("a1"), _did("a2")

    # first approver requests the hold -> PENDING
    out = f.hold_account(cx, subject, "VELOCITY_ANOMALY", a1, None)
    cx.commit()
    assert out["status"] == "PENDING"

    # SAME approver cannot approve their own hold (four-eyes at the DB level, R4/ADR-006)
    with pytest.raises(svc.ApiError) as e:
        f.approve_hold(cx, subject, a1)
    assert e.value.status == 409 and "same_approver" in e.value.code
    cx.rollback()

    # a DISTINCT second approver approves -> APPROVED, persisted
    out2 = f.approve_hold(cx, subject, a2)
    cx.commit()
    assert out2["status"] == "APPROVED" and out2["approver2"] == a2

    row = cx.execute("SELECT status, approver1, approver2 FROM pending_holds WHERE subject_did=%s",
                     (subject,)).fetchone()
    assert row is not None and row[0] == "APPROVED" and row[1] == a1 and row[2] == a2


def test_one_open_hold_per_subject(cx):
    f = _fraud()
    subject, a1 = _did("subj2"), _did("a1")
    f.hold_account(cx, subject, "R", a1, None)
    cx.commit()
    # a second open hold for the same subject is rejected (R4 one-open-hold invariant)
    with pytest.raises(svc.ApiError) as e:
        f.hold_account(cx, subject, "R", a1, None)
    assert e.value.status == 409 and "already_open" in e.value.code
    cx.rollback()


def test_signal_is_worm_append(cx):
    f = _fraud()
    subject = _did("sig")
    f.raise_signal(cx, subject, "CLONE_BATCH", 0.9, None, "tester")
    cx.commit()
    n = cx.execute("SELECT count(*) FROM fraud_signals WHERE subject_did=%s", (subject,)).fetchone()[0]
    assert n == 1
