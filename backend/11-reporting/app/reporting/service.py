"""11-reporting OLAP queries — runs against PG facts (ClickHouse-optional)."""
from __future__ import annotations
import logging
import time
from datetime import date, timedelta

from fastapi import HTTPException, status

from app.config import settings
from app.db.postgres import pool
from app.observability.metrics import (
    SERVICE_VAL, reporting_kpi_queries_total, reporting_kpi_query_duration_ms,
)
from app.reporting.schemas import (
    OrdersByPeriod, PaymentMix, PayoutsHistory, PlatformKpis, ShopKpis,
)


log = logging.getLogger("reporting.service")


def _validate_range(d_from: date, d_to: date) -> None:
    if d_to < d_from:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, detail={
            "error": {"code": "invalid_request", "message": "to < from"}})
    if (d_to - d_from).days > settings.kpi_max_range_days:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, detail={
            "error": {"code": "range_too_large",
                      "message": f"range exceeds KPI_MAX_RANGE_DAYS={settings.kpi_max_range_days}"}})


def _now_default(d_from: date | None, d_to: date | None) -> tuple[date, date]:
    if d_to is None: d_to = date.today()
    if d_from is None: d_from = d_to - timedelta(days=30)
    return d_from, d_to


async def platform_kpis(d_from: date | None, d_to: date | None) -> PlatformKpis:
    d_from, d_to = _now_default(d_from, d_to)
    _validate_range(d_from, d_to)
    t0 = time.perf_counter()
    async with pool().acquire() as conn:
        row = await conn.fetchrow("""
            WITH o AS (
              SELECT count(*)::int AS orders,
                     coalesce(sum(total_minor), 0)::bigint AS gmv,
                     coalesce(sum(CASE WHEN refunded_at IS NOT NULL THEN 1 ELSE 0 END), 0)::int AS refunded
              FROM fact_order WHERE date_key BETWEEN $1 AND $2
            ),
            p AS (
              SELECT coalesce(sum(commission_minor), 0)::bigint AS commission,
                     coalesce(sum(amount_minor), 0)::bigint AS settled
              FROM fact_payment WHERE date_key BETWEEN $1 AND $2
            )
            SELECT o.orders, o.gmv, o.refunded, p.commission, p.settled FROM o, p
        """, d_from, d_to)
    orders = row["orders"] or 0
    gmv = int(row["gmv"] or 0)
    commission = int(row["commission"] or 0)
    settled = int(row["settled"] or 1)
    refunded = row["refunded"] or 0
    reporting_kpi_queries_total.labels(SERVICE_VAL, "platform").inc()
    reporting_kpi_query_duration_ms.labels(SERVICE_VAL, "platform").observe((time.perf_counter() - t0) * 1000)
    log.info("platform_kpis served from=%s to=%s orders=%s", d_from, d_to, row["orders"])
    return PlatformKpis(
        period_from=d_from, period_to=d_to,
        gmv_minor=gmv, orders=orders,
        aov_minor=(gmv / orders) if orders else 0.0,
        take_rate_pct=(commission / settled * 100.0) if settled else 0.0,
        refund_rate_pct=(refunded / orders * 100.0) if orders else 0.0,
    )


async def shop_kpis(shop_id: str, d_from: date | None, d_to: date | None) -> ShopKpis:
    d_from, d_to = _now_default(d_from, d_to)
    _validate_range(d_from, d_to)
    async with pool().acquire() as conn:
        row = await conn.fetchrow("""
            SELECT count(*)::int AS orders, coalesce(sum(total_minor), 0)::bigint AS gmv
            FROM fact_order WHERE shop_id = $1::uuid AND date_key BETWEEN $2 AND $3
        """, shop_id, d_from, d_to)
    orders = row["orders"] or 0
    gmv = int(row["gmv"] or 0)
    reporting_kpi_queries_total.labels(SERVICE_VAL, "shop").inc()
    return ShopKpis(shop_id=shop_id, period_from=d_from, period_to=d_to,
                    gmv_minor=gmv, orders=orders,
                    aov_minor=(gmv / orders) if orders else 0.0)


async def payment_mix(d_from: date | None, d_to: date | None) -> PaymentMix:
    d_from, d_to = _now_default(d_from, d_to)
    _validate_range(d_from, d_to)
    async with pool().acquire() as conn:
        rows = await conn.fetch("""
            SELECT provider, sum(amount_minor)::bigint AS amount, count(*)::int AS n
            FROM fact_payment WHERE date_key BETWEEN $1 AND $2 GROUP BY provider
        """, d_from, d_to)
    reporting_kpi_queries_total.labels(SERVICE_VAL, "payment_mix").inc()
    return PaymentMix(
        period_from=d_from, period_to=d_to,
        by_provider={r["provider"]: int(r["amount"]) for r in rows},
        by_provider_count={r["provider"]: r["n"] for r in rows},
    )


async def orders_by_period(d_from: date | None, d_to: date | None) -> OrdersByPeriod:
    d_from, d_to = _now_default(d_from, d_to)
    _validate_range(d_from, d_to)
    async with pool().acquire() as conn:
        rows = await conn.fetch("""
            SELECT date_key, count(*)::int AS orders, coalesce(sum(total_minor), 0)::bigint AS gmv
            FROM fact_order WHERE date_key BETWEEN $1 AND $2 GROUP BY date_key ORDER BY date_key
        """, d_from, d_to)
    reporting_kpi_queries_total.labels(SERVICE_VAL, "orders_by_period").inc()
    log.info("orders_by_period served from=%s to=%s buckets=%s", d_from, d_to, len(rows))
    return OrdersByPeriod(
        period_from=d_from, period_to=d_to,
        daily=[{"date": r["date_key"].isoformat(), "orders": r["orders"], "gmv_minor": int(r["gmv"])} for r in rows],
    )


async def payouts_history(shopkeeper_id: str | None, d_from: date | None, d_to: date | None) -> PayoutsHistory:
    d_from, d_to = _now_default(d_from, d_to)
    _validate_range(d_from, d_to)
    async with pool().acquire() as conn:
        if shopkeeper_id:
            rows = await conn.fetch("""
                SELECT * FROM fact_payout
                WHERE shopkeeper_id = $1::uuid AND date_key BETWEEN $2 AND $3
                ORDER BY date_key DESC LIMIT 500
            """, shopkeeper_id, d_from, d_to)
        else:
            rows = await conn.fetch("""
                SELECT * FROM fact_payout WHERE date_key BETWEEN $1 AND $2
                ORDER BY date_key DESC LIMIT 500
            """, d_from, d_to)
    reporting_kpi_queries_total.labels(SERVICE_VAL, "payouts_history").inc()
    return PayoutsHistory(shopkeeper_id=shopkeeper_id, period_from=d_from, period_to=d_to,
                          payouts=[dict(r) for r in rows])


async def export_nbr_vat(period_from: date, period_to: date) -> list[dict]:
    """NBR VAT export — 15% VAT on commission earnings (simplified)."""
    _validate_range(period_from, period_to)
    async with pool().acquire() as conn:
        rows = await conn.fetch("""
            SELECT date_key, provider,
                   sum(commission_minor)::bigint AS commission_minor,
                   sum(commission_minor)::bigint * 15 / 115 AS vat_minor,
                   count(*)::int AS transactions
            FROM fact_payment
            WHERE date_key BETWEEN $1 AND $2
            GROUP BY date_key, provider ORDER BY date_key, provider
        """, period_from, period_to)
    from app.observability.metrics import reporting_export_rows_total
    reporting_export_rows_total.labels(SERVICE_VAL, "nbr_vat").inc(len(rows))
    return [dict(r) for r in rows]


async def export_btrc_dbid(quarter: str) -> list[dict]:
    """BTRC DBID quarterly export — by-shopkeeper revenue."""
    # quarter like "2026-Q2"
    if len(quarter) != 7 or quarter[4] != "-" or quarter[5] != "Q":
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, detail={
            "error": {"code": "invalid_request", "message": "quarter format: YYYY-Qn"}})
    year = int(quarter[:4])
    q = int(quarter[6])
    if q not in {1, 2, 3, 4}:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, detail={
            "error": {"code": "invalid_request", "message": "Q in 1..4"}})
    starts = [(1, 1), (4, 1), (7, 1), (10, 1)][q - 1]
    d_from = date(year, *starts)
    ends_map = [(3, 31), (6, 30), (9, 30), (12, 31)][q - 1]
    d_to = date(year, *ends_map)
    async with pool().acquire() as conn:
        rows = await conn.fetch("""
            SELECT shopkeeper_id, sum(total_minor)::bigint AS revenue_minor,
                   count(*)::int AS orders
            FROM fact_order
            WHERE date_key BETWEEN $1 AND $2 AND shopkeeper_id IS NOT NULL
            GROUP BY shopkeeper_id ORDER BY revenue_minor DESC
        """, d_from, d_to)
    from app.observability.metrics import reporting_export_rows_total
    reporting_export_rows_total.labels(SERVICE_VAL, "btrc_dbid").inc(len(rows))
    return [{"shopkeeper_id": str(r["shopkeeper_id"]),
             "revenue_minor": int(r["revenue_minor"]),
             "orders": r["orders"]} for r in rows]
