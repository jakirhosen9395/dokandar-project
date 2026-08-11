from __future__ import annotations
from datetime import date
from typing import Annotated, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.auth.jwt import require_admin, require_user
from app.reporting import service as svc
from app.reporting.schemas import (
    ErrorEnvelope, OrdersByPeriod, PaymentMix, PayoutsHistory, PlatformKpis, ShopKpis,
)


router = APIRouter(prefix="/api/v1/reporting", tags=["reporting"])


# Shared OpenAPI response blocks (doc-only). Every authenticated read can return
# 401 (missing/invalid token), 422 (bad query params) and 500; admin-gated and
# resource reads add 403/404 where applicable. All reference the one ErrorEnvelope.
_ERR = {"model": ErrorEnvelope}
_AUTH_ERRORS = {
    401: {"model": ErrorEnvelope, "description": "Missing or invalid bearer token."},
    422: {"model": ErrorEnvelope, "description": "Invalid or out-of-range query parameters."},
    500: {"model": ErrorEnvelope, "description": "Unexpected server error (scrubbed)."},
}
_ADMIN_ERRORS = {
    401: {"model": ErrorEnvelope, "description": "Missing or invalid bearer token."},
    403: {"model": ErrorEnvelope, "description": "Caller lacks admin/platform_staff role."},
    422: {"model": ErrorEnvelope, "description": "Invalid or out-of-range query parameters."},
    500: {"model": ErrorEnvelope, "description": "Unexpected server error (scrubbed)."},
}


@router.get(
    "/platform-kpis",
    response_model=PlatformKpis,
    operation_id="getPlatformKpis",
    summary="Platform KPIs (admin)",
    description="Aggregate marketplace KPIs (GMV, orders, AOV, take-rate, refund-rate) over a "
                "date window. Amounts are integer paisa. Requires `admin`/`platform_staff`. "
                "Window defaults to the service's standard range when `from`/`to` are omitted "
                "and is capped at `KPI_MAX_RANGE_DAYS`.",
    responses=_ADMIN_ERRORS,
)
async def platform_kpis(user: Annotated[dict, Depends(require_admin)],
                         d_from: Optional[date] = Query(
                             None, alias="from",
                             description="Inclusive window start (ISO-8601 date, e.g. 2026-01-01)."),
                         d_to: Optional[date] = Query(
                             None, alias="to",
                             description="Inclusive window end (ISO-8601 date, e.g. 2026-12-31).")) -> PlatformKpis:
    return await svc.platform_kpis(d_from, d_to)


@router.get(
    "/shop-kpis",
    response_model=ShopKpis,
    operation_id="getShopKpis",
    summary="Shop KPIs",
    description="Per-shop KPIs (GMV, orders, AOV in paisa) over a date window. Any authenticated "
                "user may call; supply the opaque `shop_id`.",
    responses=_AUTH_ERRORS,
)
async def shop_kpis(user: Annotated[dict, Depends(require_user)],
                     shop_id: str = Query(
                         ..., description="Opaque shop identifier to report on.",
                         examples=["11111111-1111-4111-8111-111111111111"]),
                     d_from: Optional[date] = Query(
                         None, alias="from",
                         description="Inclusive window start (ISO-8601 date)."),
                     d_to: Optional[date] = Query(
                         None, alias="to",
                         description="Inclusive window end (ISO-8601 date).")) -> ShopKpis:
    return await svc.shop_kpis(shop_id, d_from, d_to)


@router.get(
    "/orders-by-period",
    response_model=OrdersByPeriod,
    operation_id="getOrdersByPeriod",
    summary="Orders time series",
    description="Daily buckets of order counts and GMV (paisa) over a date window. Any "
                "authenticated user may call.",
    responses=_AUTH_ERRORS,
)
async def orders(user: Annotated[dict, Depends(require_user)],
                  d_from: Optional[date] = Query(
                      None, alias="from",
                      description="Inclusive window start (ISO-8601 date)."),
                  d_to: Optional[date] = Query(
                      None, alias="to",
                      description="Inclusive window end (ISO-8601 date).")) -> OrdersByPeriod:
    return await svc.orders_by_period(d_from, d_to)


@router.get(
    "/payment-mix",
    response_model=PaymentMix,
    operation_id="getPaymentMix",
    summary="Payment provider mix (admin)",
    description="Settled amount (paisa) and count broken down by payment provider over a date "
                "window. Requires `admin`/`platform_staff`.",
    responses=_ADMIN_ERRORS,
)
async def payment_mix(user: Annotated[dict, Depends(require_admin)],
                       d_from: Optional[date] = Query(
                           None, alias="from",
                           description="Inclusive window start (ISO-8601 date)."),
                       d_to: Optional[date] = Query(
                           None, alias="to",
                           description="Inclusive window end (ISO-8601 date).")) -> PaymentMix:
    return await svc.payment_mix(d_from, d_to)


@router.get(
    "/payouts-history",
    response_model=PayoutsHistory,
    operation_id="getPayoutsHistory",
    summary="Payouts history",
    description="Payout records over a date window, optionally filtered by `shopkeeper_id`. "
                "Amounts are integer paisa. Any authenticated user may call.",
    responses=_AUTH_ERRORS,
)
async def payouts(user: Annotated[dict, Depends(require_user)],
                   shopkeeper_id: Optional[str] = Query(
                       None, description="Optional opaque shopkeeper id to filter payouts by."),
                   d_from: Optional[date] = Query(
                       None, alias="from",
                       description="Inclusive window start (ISO-8601 date)."),
                   d_to: Optional[date] = Query(
                       None, alias="to",
                       description="Inclusive window end (ISO-8601 date).")) -> PayoutsHistory:
    return await svc.payouts_history(shopkeeper_id, d_from, d_to)


@router.get(
    "/exports/nbr-vat",
    operation_id="exportNbrVat",
    summary="NBR VAT export (admin)",
    description="NBR (National Board of Revenue) VAT line items for the given period. Returns a "
                "JSON array of export rows. Requires `admin`/`platform_staff`.",
    responses={
        200: {"description": "Array of NBR VAT export rows."},
        **_ADMIN_ERRORS,
    },
)
async def nbr_vat(user: Annotated[dict, Depends(require_admin)],
                   period_from: date = Query(
                       ..., description="Inclusive period start (ISO-8601 date).",
                       examples=["2026-01-01"]),
                   period_to: date = Query(
                       ..., description="Inclusive period end (ISO-8601 date).",
                       examples=["2026-12-31"])) -> list[dict]:
    return await svc.export_nbr_vat(period_from, period_to)


@router.get(
    "/exports/btrc-dbid",
    operation_id="exportBtrcDbid",
    summary="BTRC DBID export (admin)",
    description="BTRC DBID regulatory export for a calendar quarter (e.g. `2025-Q4`). Returns a "
                "JSON array of export rows. Requires `admin`/`platform_staff`.",
    responses={
        200: {"description": "Array of BTRC DBID export rows."},
        **_ADMIN_ERRORS,
    },
)
async def btrc_dbid(user: Annotated[dict, Depends(require_admin)],
                     quarter: str = Query(
                         ..., description="Calendar quarter in `YYYY-Qn` form (e.g. 2025-Q4).",
                         examples=["2025-Q4"])) -> list[dict]:
    return await svc.export_btrc_dbid(quarter)
