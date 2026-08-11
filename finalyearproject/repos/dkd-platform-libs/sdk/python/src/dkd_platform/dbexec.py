# HAND-AUTHORED platform primitive (NOT dkdgen-generated).
# PL-02 — shared outbox/inbox/DLQ contract. One of five byte-semantic runtime implementations.
"""Minimal, driver-agnostic DB-execution interface for the effectively-once quartet.

The outbox/inbox/DLQ helpers (SA-CONV-QUARTET, EF §21.1 / EF-EVT-6, SA-MSG-09/10) are written
against these Protocols ONLY — never against pgx/JDBC/Npgsql/psycopg/pg directly. The service
supplies a concrete transaction/connection handle at call time; a psycopg `Connection`/`Cursor`
already satisfies this surface, and a hand-rolled fake can too (so the quartet is unit-testable
without a live database).
"""
from __future__ import annotations

from typing import Any, Protocol, Sequence


class Cursor(Protocol):
    """The subset of a DB cursor the quartet reads back: affected-row count + row fetch."""

    @property
    def rowcount(self) -> int: ...

    def fetchone(self) -> tuple[Any, ...] | None: ...

    def fetchall(self) -> list[tuple[Any, ...]]: ...


class DbExecutor(Protocol):
    """A transaction- or connection-scoped executor. `%s` positional placeholders (DB-API/psycopg).

    Callers own the transaction: for the outbox `enqueue` and the inbox dedup, the SAME handle
    that writes the aggregate state MUST be passed, so the row and the side effect commit atomically.
    """

    def execute(self, sql: str, params: Sequence[Any] = ...) -> Cursor: ...
