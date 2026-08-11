"""ClickHouse adapter. All fact/dim tables are ReplacingMergeTree with the lineage event_id
LAST in the sort key: a replayed event collapses into one row (INV-ANL-3 append/rebuild-only;
FR-ANL-002 idempotent on event_id). Reads use FINAL for exact-once semantics at query time."""

from __future__ import annotations

from typing import Any

import clickhouse_connect
from clickhouse_connect.driver.client import Client

DDL: list[str] = [
    """
    CREATE TABLE IF NOT EXISTS fact_custody_events (
      event_id String, event String, ppid String, gpid String, holder String,
      quantity Int64, unit String, occurred_at Int64, ingest_ts Int64
    ) ENGINE = ReplacingMergeTree ORDER BY (gpid, occurred_at, event_id)
    """,
    """
    CREATE TABLE IF NOT EXISTS fact_orders (
      event_id String, event String, ord String, buyer_did String, seller_did String,
      gpid String, quantity Int64, amount_poisha Int64, occurred_at Int64, ingest_ts Int64
    ) ENGINE = ReplacingMergeTree ORDER BY (ord, occurred_at, event_id)
    """,
    """
    CREATE TABLE IF NOT EXISTS fact_trade_orders (
      event_id String, event String, trd String, buyer_did String, seller_did String,
      gpid String, unit_price_poisha Int64, amount_poisha Int64,
      occurred_at Int64, ingest_ts Int64
    ) ENGINE = ReplacingMergeTree ORDER BY (trd, occurred_at, event_id)
    """,
    """
    CREATE TABLE IF NOT EXISTS fact_settlements (
      event_id String, event String, ref String, reference_id String, reference_type String,
      amount_poisha Int64, occurred_at Int64, ingest_ts Int64
    ) ENGINE = ReplacingMergeTree ORDER BY (ref, occurred_at, event_id)
    """,
    """
    CREATE TABLE IF NOT EXISTS fact_logistics (
      event_id String, event String, shp String, reference_id String,
      occurred_at Int64, ingest_ts Int64
    ) ENGINE = ReplacingMergeTree ORDER BY (shp, occurred_at, event_id)
    """,
    """
    CREATE TABLE IF NOT EXISTS fact_fraud_signals (
      event_id String, event String, subject_did String, reason String, risk_score Float64,
      occurred_at Int64, ingest_ts Int64
    ) ENGINE = ReplacingMergeTree ORDER BY (subject_did, occurred_at, event_id)
    """,
    """
    CREATE TABLE IF NOT EXISTS dim_product (
      event_id String, event String, gpid String, unit String, category String,
      occurred_at Int64, ingest_ts Int64
    ) ENGINE = ReplacingMergeTree ORDER BY (gpid, occurred_at, event_id)
    """,
]


def open_client(url: str, user: str, password: str) -> Client:
    return clickhouse_connect.get_client(dsn=url, username=user, password=password,
                                         database="default")


class ThreadLocalClients:
    """clickhouse-connect HttpClient is not documented thread-safe (reviewer H-1):
    the FastAPI threadpool vends one client per worker thread."""

    def __init__(self, url: str, user: str, password: str) -> None:
        import threading

        self._local = threading.local()
        self._args = (url, user, password)

    def get(self) -> Client:
        client = getattr(self._local, "client", None)
        if client is None:
            client = open_client(*self._args)
            self._local.client = client
        return client


def migrate(client: Client) -> None:
    for ddl in DDL:
        client.command(ddl)


def insert_rows(client: Client, table: str, rows: list[dict[str, Any]]) -> None:
    if not rows:
        return
    cols = list(rows[0].keys())
    client.insert(table, [[r[c] for c in cols] for r in rows], column_names=cols)


def query(client: Client, sql: str, params: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    result = client.query(sql, parameters=params or {})
    cols = result.column_names
    return [dict(zip(cols, r, strict=True)) for r in result.result_rows]
