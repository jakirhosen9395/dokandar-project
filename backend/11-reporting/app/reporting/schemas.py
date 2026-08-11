from __future__ import annotations
from datetime import date
from typing import Optional
from pydantic import BaseModel, Field


class ErrorDetail(BaseModel):
    """Inner object of the platform error envelope."""
    code: str = Field(..., description="Stable machine-readable error code (lowercase snake_case).",
                      examples=["forbidden"])
    message: str = Field(..., description="Human-readable error message.",
                         examples=["admin or platform_staff required"])
    request_id: Optional[str] = Field(None, description="Echo of the honour-or-mint x-request-id header.",
                                      examples=["3f1c2b8e9a7d4f0c"])
    details: Optional[dict] = Field(None, description="Optional structured context for the error.")


class ErrorEnvelope(BaseModel):
    """Platform-wide error envelope. Every 4xx/5xx response uses this shape."""
    error: ErrorDetail

    model_config = {
        "json_schema_extra": {
            "example": {
                "error": {
                    "code": "forbidden",
                    "message": "admin or platform_staff required",
                    "request_id": "3f1c2b8e9a7d4f0c",
                    "details": {},
                }
            }
        }
    }


class PlatformKpis(BaseModel):
    period_from: date = Field(..., description="Inclusive start of the reporting window (ISO-8601 date).")
    period_to: date = Field(..., description="Inclusive end of the reporting window (ISO-8601 date).")
    gmv_minor: int = Field(..., description="Gross merchandise value in integer paisa (BDT minor units).",
                           examples=[125000000])
    orders: int = Field(..., description="Total placed orders in the window.", examples=[842])
    aov_minor: float = Field(..., description="Average order value in paisa (gmv_minor / orders).",
                             examples=[148456.0])
    take_rate_pct: float = Field(..., description="Platform take rate as a percentage.", examples=[7.5])
    refund_rate_pct: float = Field(..., description="Refunded-order rate as a percentage.", examples=[2.1])


class ShopKpis(BaseModel):
    shop_id: str = Field(..., description="Opaque shop identifier the KPIs were computed for.")
    period_from: date = Field(..., description="Inclusive start of the reporting window (ISO-8601 date).")
    period_to: date = Field(..., description="Inclusive end of the reporting window (ISO-8601 date).")
    gmv_minor: int = Field(..., description="Shop GMV in integer paisa (BDT minor units).", examples=[4200000])
    orders: int = Field(..., description="Total placed orders for the shop in the window.", examples=[31])
    aov_minor: float = Field(..., description="Average order value in paisa.", examples=[135483.0])


class PaymentMix(BaseModel):
    period_from: date = Field(..., description="Inclusive start of the reporting window (ISO-8601 date).")
    period_to: date = Field(..., description="Inclusive end of the reporting window (ISO-8601 date).")
    by_provider: dict[str, int] = Field(
        ..., description="Settled amount in paisa keyed by payment provider.",
        examples=[{"bkash": 88000000, "nagad": 21000000, "cod": 16000000}])
    by_provider_count: dict[str, int] = Field(
        ..., description="Settled payment count keyed by payment provider.",
        examples=[{"bkash": 520, "nagad": 180, "cod": 142}])


class OrdersByPeriod(BaseModel):
    period_from: date = Field(..., description="Inclusive start of the reporting window (ISO-8601 date).")
    period_to: date = Field(..., description="Inclusive end of the reporting window (ISO-8601 date).")
    daily: list[dict] = Field(
        ..., description="Per-day buckets of order counts and GMV (paisa).",
        examples=[[{"day": "2026-01-01", "orders": 12, "gmv_minor": 1800000}]])


class PayoutsHistory(BaseModel):
    shopkeeper_id: Optional[str] = Field(
        None, description="Opaque shopkeeper identifier the payouts were filtered by, if supplied.")
    period_from: date = Field(..., description="Inclusive start of the reporting window (ISO-8601 date).")
    period_to: date = Field(..., description="Inclusive end of the reporting window (ISO-8601 date).")
    payouts: list[dict] = Field(
        ..., description="Payout records (amount in paisa, status, settled_at).",
        examples=[[{"payout_id": "po_001", "amount_minor": 5000000, "status": "completed",
                    "settled_at": "2026-01-15T08:30:00Z"}]])
