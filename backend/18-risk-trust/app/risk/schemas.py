from __future__ import annotations
import uuid
from typing import Annotated, Optional
from pydantic import BaseModel, Field


class ScoreCheckoutBody(BaseModel):
    user_id: uuid.UUID = Field(
        description="Opaque auth user id placing the order.",
        examples=["11111111-1111-4111-8111-111111111111"],
    )
    order_id: uuid.UUID = Field(
        description="Opaque order id (idempotency key for the persisted decision).",
        examples=["22222222-2222-4222-8222-222222222222"],
    )
    amount_minor: int = Field(
        ge=0,
        description="Order total in integer paisa (BDT minor units). 50,000 BDT = 5,000,000.",
        examples=[150000],
    )
    device_id: Optional[str] = Field(
        default=None, description="Optional device fingerprint.", examples=["dev-abc-123"]
    )
    ip: Optional[str] = Field(
        default=None, description="Optional client IP.", examples=["203.0.113.10"]
    )
    payment_method: str = Field(
        default="card",
        description="Payment method; `cod` activates the COD-refusal signal.",
        examples=["cod"],
    )


class ScoreCODBody(BaseModel):
    user_id: uuid.UUID = Field(
        description="Opaque auth user id.",
        examples=["11111111-1111-4111-8111-111111111111"],
    )
    order_id: uuid.UUID = Field(
        description="Opaque order id.",
        examples=["22222222-2222-4222-8222-222222222222"],
    )
    amount_minor: int = Field(
        ge=0,
        description="COD order total in integer paisa. 20,000 BDT = 2,000,000.",
        examples=[2500000],
    )
    delivery_district: Optional[str] = Field(
        default=None, description="Optional delivery district (rural-routing signal).",
        examples=["Dhaka"],
    )


class ScoreReviewBody(BaseModel):
    user_id: uuid.UUID = Field(
        description="Opaque auth user id who authored the review.",
        examples=["11111111-1111-4111-8111-111111111111"],
    )
    review_id: uuid.UUID = Field(
        description="Opaque review id (idempotency key for the persisted decision).",
        examples=["33333333-3333-4333-8333-333333333333"],
    )
    body: str = Field(
        description="Raw review text scanned for spam/abuse heuristics.",
        examples=["Great product, fast delivery!"],
    )


class ScoreResponse(BaseModel):
    # SECURITY (§12, §16-e): decision + OPAQUE reason_codes ONLY. The numeric score and
    # thresholds are NEVER returned — exposing them lets adversaries probe and evade the
    # model. The score stays internal (persisted + metered), it never leaves the service.
    decision: str = Field(
        description="Risk decision. Closed set: `allow` | `review` | `deny`.",
        examples=["allow"],
    )
    reason_codes: list[str] = Field(
        description="Opaque, stable reason codes (no numeric score or threshold is ever returned).",
        examples=[["cod_prior_refusal"]],
    )


class RuleBody(BaseModel):
    name: str = Field(
        min_length=3, max_length=80, description="Human-readable rule name (3–80 chars).",
        examples=["High velocity checkout"],
    )
    signal: Annotated[str, Field(
        pattern="^(velocity|device|geo|bin_mismatch|cod_refusal|review_abuse)$",
        description="Closed set of supported risk signals.",
        examples=["velocity"],
    )]
    threshold: dict = Field(
        description="Free-form JSON threshold config for the signal.",
        examples=[{"orders_per_hour": 10}],
    )
    action: Annotated[str, Field(
        pattern="^(allow|review|deny)$",
        description="Decision the rule emits when matched.",
        examples=["review"],
    )]
    active: bool = Field(default=True, description="Whether the rule is enabled.", examples=[True])


class OverrideBody(BaseModel):
    entity_type: Annotated[str, Field(
        pattern="^(user|order|shop|review)$",
        description="Entity class the override fences.",
        examples=["user"],
    )]
    entity_id: uuid.UUID = Field(
        description="Opaque id of the fenced entity.",
        examples=["11111111-1111-4111-8111-111111111111"],
    )
    action: Annotated[str, Field(
        pattern="^(allow|deny)$",
        description="Forced decision for the entity (allow-list or deny-list).",
        examples=["deny"],
    )]
    reason: str = Field(
        min_length=3, max_length=500, description="Audit reason (3–500 chars).",
        examples=["Confirmed fraud ring"],
    )
    expires_at: Optional[str] = Field(
        default=None, description="Optional RFC 3339 / ISO-8601 UTC expiry; null = never expires.",
        examples=["2026-12-31T23:59:59Z"],
    )


class ErrorEnvelope(BaseModel):
    """Platform error envelope (contract §10). Shape: {error:{code,message,request_id,details}}."""

    class _Error(BaseModel):
        code: str = Field(
            description="Stable lowercase_snake machine code.", examples=["invalid_request"]
        )
        message: str = Field(
            description="Human-readable (scrubbed) message.", examples=["validation failed"]
        )
        request_id: Optional[str] = Field(
            default=None, description="Honour-or-mint x-request-id.",
            examples=["3f2a1c9d8e7b4a5f9c0d1e2f3a4b5c6d"],
        )
        details: Optional[dict] = Field(
            default=None, description="Optional structured context.", examples=[{}]
        )

    error: _Error
