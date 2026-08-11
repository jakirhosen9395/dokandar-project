from __future__ import annotations
import uuid
from datetime import datetime
from typing import Optional
from pydantic import BaseModel, Field


class FeedItem(BaseModel):
    product_id: uuid.UUID = Field(
        ..., description="Catalog product id (opaque UUID).",
        examples=["11111111-1111-4111-8111-111111111111"])
    score: float = Field(
        ..., description="Relevance / ranking score (higher = more relevant).",
        examples=[42.5])
    reason: Optional[str] = Field(
        None,
        description="Why the item surfaced: one of `personal` | `collab` | `content` | "
                    "`popularity` | `cross_sell` | `similar` | `cold_start`.",
        examples=["popularity"])


class Feed(BaseModel):
    source: str = Field(
        ..., description="Feed strategy actually used: `personal` | `popularity` | "
                         "`cold_start` | `similar`.",
        examples=["personal"])
    items: list[FeedItem] = Field(..., description="Ranked recommendation items.")
    generated_at: datetime = Field(
        ..., description="RFC 3339 / ISO-8601 UTC timestamp of feed generation.",
        examples=["2026-06-20T12:00:00Z"])


class CrossSellItem(BaseModel):
    paired_product_id: uuid.UUID = Field(
        ..., description="Product frequently co-purchased with the queried product.",
        examples=["22222222-2222-4222-8222-222222222222"])
    weight: float = Field(
        ..., description="Co-occurrence weight (higher = stronger pairing).",
        examples=[3.0])


class ErrorBody(BaseModel):
    code: str = Field(
        ..., description="Stable lowercase_snake machine code.",
        examples=["invalid_token"])
    message: str = Field(
        ..., description="Human-readable (scrubbed) message.",
        examples=["invalid or expired token"])
    request_id: Optional[str] = Field(
        None, description="Honour-or-mint x-request-id.",
        examples=["11111111-1111-4111-8111-111111111111"])
    details: Optional[dict] = Field(
        None, description="Optional structured context.", examples=[{}])


class ErrorEnvelope(BaseModel):
    """Platform-standard error envelope: `{error:{code,message,request_id,details}}`."""
    error: ErrorBody
