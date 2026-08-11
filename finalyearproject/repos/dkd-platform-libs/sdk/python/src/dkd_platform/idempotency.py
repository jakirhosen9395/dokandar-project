# HAND-AUTHORED platform primitive (NOT dkdgen-generated).
# PL-03 — Idempotency-Key enforcement helper (EF-API-6).
"""Idempotency-Key enforcement for unsafe / money / custody writes.

Canon (EF-API-6): every unsafe/money/custody write carries an `Idempotency-Key` header. This helper
enforces the three branches so a service never re-applies a money/custody effect:

  1. MISSING key on a guarded write         -> reject with HTTP 400.
  2. SAME key + SAME payload (a retry)       -> REPLAY the original stored response verbatim.
  3. SAME key + DIFFERENT payload (misuse)   -> reject with HTTP 409.
  otherwise (first time this key is seen)    -> PROCEED; the caller runs the handler, then records
                                                the response via `commit` so a later retry replays it.

The store is a pluggable `IdempotencyStore` Protocol — back it with the PL-02 inbox table or a
dedicated idempotency table; the helper NEVER hard-wires a database. `payload` is fingerprinted with
SHA-256, so a mismatch is detected without persisting the raw request body.
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from enum import Enum
from typing import Optional, Protocol

HEADER = "Idempotency-Key"

# HTTP statuses this helper emits (see errors.py / http_status.py for the full vocabulary).
_MISSING_KEY = 400
_MISMATCH = 409


def fingerprint(payload: bytes) -> str:
    """SHA-256 hex of the raw request body — the stored request identity for replay/mismatch."""
    if isinstance(payload, str):
        payload = payload.encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


@dataclass(frozen=True)
class StoredResponse:
    """The original response captured for a completed idempotent request."""

    request_hash: str
    status: int
    body: bytes = b""
    headers: tuple[tuple[str, str], ...] = ()


class IdempotencyStore(Protocol):
    """Persistence surface for the guard. A PL-02 inbox row or an idempotency table satisfies it.

    `save` MUST be insert-if-absent (e.g. `ON CONFLICT DO NOTHING`) and return False when a
    concurrent request already committed the key — the guard then replays the winner.
    """

    def load(self, key: str) -> Optional[StoredResponse]: ...

    def save(self, key: str, response: StoredResponse) -> bool: ...


class Action(str, Enum):
    PROCEED = "proceed"
    REPLAY = "replay"
    REJECT = "reject"


@dataclass(frozen=True)
class Decision:
    """The guard's verdict. On REPLAY/REJECT the caller returns `status` immediately (with
    `response` on REPLAY); on PROCEED the caller runs the handler and then calls `commit`."""

    action: Action
    status: int = 0
    response: Optional[StoredResponse] = None
    reason: Optional[str] = None


class IdempotencyGuard:
    """Framework-agnostic enforcer. Wire it into a middleware / dependency for guarded routes."""

    def __init__(self, store: IdempotencyStore):
        self._store = store

    def begin(self, key: Optional[str], payload: bytes) -> Decision:
        """Classify an incoming guarded write BEFORE the handler runs."""
        if not key:
            return Decision(Action.REJECT, _MISSING_KEY, reason="missing Idempotency-Key")
        prior = self._store.load(key)
        if prior is None:
            return Decision(Action.PROCEED)
        if prior.request_hash == fingerprint(payload):
            return Decision(Action.REPLAY, prior.status, response=prior)
        return Decision(Action.REJECT, _MISMATCH, reason="Idempotency-Key reused with a different payload")

    def commit(self, key: str, payload: bytes, status: int, body: bytes = b"",
               headers: tuple[tuple[str, str], ...] = ()) -> StoredResponse:
        """Persist the handler's response so a later retry with the same key replays it."""
        stored = StoredResponse(fingerprint(payload), status, body, headers)
        self._store.save(key, stored)
        return stored
