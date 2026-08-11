"""Fraud commands (DM ctx #10 command table, verbatim semantics):
- RaiseFraudSignal -> FraudSignalRaised.v1 (advisory, append-only signal)
- HoldAccount(approver1) -> RabbitMQ fraud.hold-approval-request (NO Kafka event — R4 four-eyes)
- ApproveHold(approver2) -> asserts approver2 != approver1 -> AccountHeld.v1
- ReleaseHold(approver1, approver2) -> AccountHoldReleased.v1
Command tx = state change + outbox row on ONE connection; RabbitMQ publish is post-commit.
"""

from __future__ import annotations

import json
import re
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any, Protocol

from psycopg import Connection
from psycopg_pool import ConnectionPool

from fraud import events, ids, stores

# FRAUD-11 / R6: FraudSignalRaised.reason must be a controlled CODE (uppercase enum), never free text —
# free text on the Published-Language wire is an uncontrolled PII vector (payloads carry codes only).
_REASON_CODE = re.compile(r"^[A-Z][A-Z0-9_]{1,63}$")


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


class HoldRequestPublisher(Protocol):
    def publish_hold_request(self, message: dict[str, Any]) -> None: ...


@dataclass(frozen=True)
class HoldView:
    subject_did: str
    reason: str
    approver1: str
    status: str
    approver2: str | None
    requested_at: int

    def as_dict(self) -> dict[str, Any]:
        return {
            "subjectDid": self.subject_did, "reason": self.reason, "approver1": self.approver1,
            "status": self.status, "approver2": self.approver2, "requestedAt": self.requested_at,
        }


def _view(h: stores.PendingHold) -> HoldView:
    return HoldView(subject_did=h.subject_did, reason=h.reason, approver1=h.approver1,
                    status=h.status, approver2=h.approver2, requested_at=h.requested_at)


class FraudService:
    def __init__(self, pool: ConnectionPool, publisher: HoldRequestPublisher) -> None:
        self._pool = pool
        self._publisher = publisher

    def raise_signal(self, cx: Connection[Any], subject_did: str, reason: str,
                     risk_score: float, evidence: dict[str, Any] | None,
                     raised_by: str) -> dict[str, Any]:
        _require_did(subject_did, "subjectDid")
        if not reason:
            raise ApiError(400, "dokandar.fraud.validation.reason", "reason is required")
        if not _REASON_CODE.match(reason):
            raise ApiError(422, "dokandar.fraud.validation.reason_not_code",
                           "reason must be an uppercase detector CODE (e.g. VELOCITY_ANOMALY), not free text (FRAUD-11/R6)")
        if not 0.0 <= risk_score <= 1.0:
            raise ApiError(400, "dokandar.fraud.validation.risk_score",
                           "riskScore must be within [0,1] (FR-SCM-019)")
        now = ids.now_ms()
        signal_id = ids.new_signal_id()
        stores.insert_signal(cx, signal_id, subject_did, reason, risk_score, evidence,
                             raised_by or "system", now)
        events.fraud_signal_raised(cx, subject_did, reason, risk_score, now)
        return {"signalId": signal_id, "subjectDid": subject_did, "riskScore": risk_score,
                "raisedAt": now}

    def hold_account(self, cx: Connection[Any], subject_did: str, reason: str, approver1: str,
                     evidence: dict[str, Any] | None) -> dict[str, Any]:
        """First approver requests the hold. NO enforcement happens yet — the request goes to
        the intra-context RabbitMQ queue for the second approver (R4)."""
        _require_did(subject_did, "subjectDid")
        _require_did(approver1, "approver1")
        if not reason:
            raise ApiError(400, "dokandar.fraud.validation.reason", "reason is required")
        now = ids.now_ms()
        if not stores.insert_pending_hold(cx, subject_did, reason, approver1, evidence, now):
            raise ApiError(409, "dokandar.fraud.hold.already_open",
                           "one open hold per subject (R4) — approve or release the existing one")
        return {"subjectDid": subject_did, "status": "PENDING", "approver1": approver1,
                "requestedAt": now,
                "__rabbit": {"type": "AccountHoldRequested", "subjectDid": subject_did,
                             "reason": reason, "approver1": approver1, "requestedAt": now}}

    def publish_hold_request(self, message: dict[str, Any]) -> None:
        self._publisher.publish_hold_request(message)

    def approve_hold(self, cx: Connection[Any], subject_did: str,
                     approver2: str) -> dict[str, Any]:
        _require_did(approver2, "approver2")
        hold = stores.lock_hold(cx, subject_did)
        if hold is None:
            raise ApiError(404, "dokandar.fraud.hold.not_found", "no hold request for subject")
        if hold.status == "APPROVED":
            # idempotent replay with the SAME shape as a fresh approval
            return {"subjectDid": subject_did, "status": "APPROVED",
                    "approver1": hold.approver1, "approver2": hold.approver2,
                    "heldAt": hold.approved_at}
        if hold.status != "PENDING":
            raise ApiError(409, "dokandar.fraud.hold.bad_state", f"hold is {hold.status}")
        if approver2 == hold.approver1:
            raise ApiError(409, "dokandar.fraud.hold.same_approver",
                           "four-eyes requires two DISTINCT approvers (R4/ADR-006)")
        now = ids.now_ms()
        if not stores.transition_hold(cx, subject_did, "PENDING", "APPROVED", approver2, now):
            raise ApiError(409, "dokandar.fraud.hold.conflict", "concurrent hold update")
        events.account_held(cx, subject_did, hold.approver1, approver2, now)
        return {"subjectDid": subject_did, "status": "APPROVED", "approver1": hold.approver1,
                "approver2": approver2, "heldAt": now}

    def release_hold(self, cx: Connection[Any], subject_did: str, approver1: str,
                     approver2: str) -> dict[str, Any]:
        """Both approvers are required to release — DM: ReleaseHold(subjectDid, a1, a2)."""
        _require_did(approver1, "approver1")
        _require_did(approver2, "approver2")
        if approver1 == approver2:
            raise ApiError(409, "dokandar.fraud.hold.same_approver",
                           "four-eyes requires two DISTINCT approvers (R4/ADR-006)")
        hold = stores.lock_hold(cx, subject_did)
        if hold is None:
            raise ApiError(404, "dokandar.fraud.hold.not_found", "no hold for subject")
        if hold.status != "APPROVED":
            raise ApiError(409, "dokandar.fraud.hold.bad_state",
                           f"only an APPROVED hold can be released (hold is {hold.status})")
        if approver1 != hold.approver1 or approver2 != hold.approver2:
            raise ApiError(409, "dokandar.fraud.hold.approver_mismatch",
                           "release requires the SAME two approvers who created and approved "
                           "the hold (R4)")
        now = ids.now_ms()
        if not stores.transition_hold(cx, subject_did, "APPROVED", "RELEASED", None, now):
            raise ApiError(409, "dokandar.fraud.hold.conflict", "concurrent hold update")
        stores.delete_hold(cx, subject_did)
        events.account_hold_released(cx, subject_did, now)
        return {"subjectDid": subject_did, "status": "RELEASED", "releasedAt": now}

    def get_hold(self, subject_did: str) -> dict[str, Any] | None:
        with self._pool.connection() as cx:
            hold = stores.get_hold_ro(cx, subject_did)
            cx.rollback()
        return _view(hold).as_dict() if hold else None

    def run_idempotent(
            self, key: str | None, endpoint: str, body: dict[str, Any], success_status: int,
            action: Callable[[Connection[Any]], dict[str, Any]],
    ) -> tuple[int, dict[str, Any], bool]:
        """Exactly-once command: response (or business failure) stored with the state change
        in ONE transaction keyed (Idempotency-Key, endpoint) — fleet contract."""
        if not key:
            raise ApiError(400, "dokandar.fraud.request.missing_idempotency_key",
                           "Idempotency-Key header is mandatory on fraud writes")
        req_hash = stores.request_hash(body)
        with self._pool.connection() as cx:
            stored = stores.idem_find(cx, key, endpoint)
            if stored is not None:
                cx.rollback()
                return _replay(stored, req_hash)
            try:
                data = action(cx)
                rabbit = data.pop("__rabbit", None)
                stores.idem_insert(cx, key, endpoint, req_hash, success_status,
                                   data, ids.now_ms())
                cx.commit()
            except ApiError as e:
                cx.rollback()
                _store_failure(self._pool, key, endpoint, req_hash, e)
                raise
        if rabbit is not None:
            self.publish_hold_request(rabbit)  # post-commit, never inside the tx
        return success_status, data, False


def _replay(stored: stores.StoredResponse, req_hash: str) -> tuple[int, dict[str, Any], bool]:
    if stored.request_hash != req_hash:
        raise ApiError(409, "dokandar.fraud.request.idempotency_key_reuse",
                       "Idempotency-Key was already used with a different request body")
    err = stored.body.get("__error")
    if isinstance(err, dict):
        raise ApiError(stored.status, str(err.get("code")), str(err.get("message")))
    return stored.status, stored.body, True


def _store_failure(pool: ConnectionPool, key: str, endpoint: str, req_hash: str,
                   e: ApiError) -> None:
    body = {"__error": {"code": e.code, "message": e.message}}
    try:
        with pool.connection() as cx:
            stores.idem_insert(cx, key, endpoint, req_hash, e.status, body, ids.now_ms())
            cx.commit()
    except Exception:  # noqa: BLE001 — another attempt already stored an outcome; keep theirs
        pass


def _require_did(value: str, field: str) -> None:
    if not ids.is_did(value):
        raise ApiError(400, f"dokandar.fraud.validation.{field.lower()}",
                       f"{field} must be a did:dokandar DID")


def parse_evidence(raw: object) -> dict[str, Any] | None:
    if raw is None:
        return None
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str):
        try:
            loaded = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise ApiError(400, "dokandar.fraud.validation.evidence",
                           "evidence must be a JSON object") from exc
        if isinstance(loaded, dict):
            return loaded
    raise ApiError(400, "dokandar.fraud.validation.evidence", "evidence must be a JSON object")
