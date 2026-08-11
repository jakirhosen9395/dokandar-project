from __future__ import annotations
from typing import Annotated
from fastapi import APIRouter, Depends, Path, Query

from app.auth.jwt import require_admin, require_user
from app.reco import service as svc
from app.reco.schemas import CrossSellItem, ErrorEnvelope, Feed


router = APIRouter(prefix="/api/v1/recommendation", tags=["recommendation"])

_ERR = {"model": ErrorEnvelope}
_AUTH_RESPONSES = {
    401: {"model": ErrorEnvelope, "description": "missing_token / invalid_token"},
    422: {"model": ErrorEnvelope, "description": "invalid_request (query validation failed)"},
    503: {"model": ErrorEnvelope, "description": "server_misconfigured / dep_unavailable"},
}
_PUBLIC_RESPONSES = {
    422: {"model": ErrorEnvelope, "description": "invalid_request (query/path validation failed)"},
    503: {"model": ErrorEnvelope, "description": "dep_unavailable (datastore unreachable)"},
}


@router.get(
    "/feed/me", response_model=Feed, operation_id="getPersonalFeed",
    summary="Personalised recommendation feed for the caller",
    description="Returns a ranked feed for the authenticated user. Falls back from the "
                "ANN/personal model to a popularity / cold-start feed when embeddings are "
                "unavailable (degraded, not an error). Requires a Bearer JWT.",
    responses=_AUTH_RESPONSES,
)
async def feed_me(user: Annotated[dict, Depends(require_user)],
                   size: Annotated[int, Query(
                       ge=1, le=100,
                       description="Maximum number of items to return.",
                       examples=[30])] = 30) -> Feed:
    return await svc.get_personal_feed(user["sub"], size)


@router.get(
    "/similar/{product_id}", response_model=Feed, operation_id="getSimilarProducts",
    summary="Products similar to a given product",
    description="Returns products similar to `product_id` (co-purchase proxy, popularity "
                "fallback). Public read — no authentication required.",
    responses=_PUBLIC_RESPONSES,
)
async def similar(product_id: Annotated[str, Path(
                      description="Catalog product id (opaque UUID).",
                      examples=["11111111-1111-4111-8111-111111111111"])],
                   size: Annotated[int, Query(
                       ge=1, le=100,
                       description="Maximum number of items to return.",
                       examples=[20])] = 20) -> Feed:
    return await svc.get_similar(product_id, size)


@router.get(
    "/cross-sell", response_model=list[CrossSellItem], operation_id="getCrossSell",
    summary="Cross-sell pairings for a product",
    description="Returns products frequently co-purchased with `product_id`, ranked by "
                "co-occurrence weight. Public read — no authentication required.",
    responses=_PUBLIC_RESPONSES,
)
async def cross_sell(product_id: Annotated[str, Query(
                          description="Catalog product id (opaque UUID).",
                          examples=["11111111-1111-4111-8111-111111111111"])],
                      size: Annotated[int, Query(
                          ge=1, le=100,
                          description="Maximum number of items to return.",
                          examples=[20])] = 20) -> list[CrossSellItem]:
    return await svc.get_cross_sell(product_id, size)


@router.post(
    "/admin/retrain", operation_id="triggerRetrain",
    summary="Trigger a model retrain (admin only)",
    description="Schedules a popularity/cross-sell aggregation retrain. Admin/platform_staff "
                "only. Single-flight: a concurrent retrain returns `409 retrain_in_progress`.",
    responses={
        401: {"model": ErrorEnvelope, "description": "missing_token / invalid_token"},
        403: {"model": ErrorEnvelope, "description": "insufficient_role (admin required)"},
        409: {"model": ErrorEnvelope, "description": "retrain_in_progress"},
        503: {"model": ErrorEnvelope, "description": "server_misconfigured / dep_unavailable"},
    },
)
async def retrain(user: Annotated[dict, Depends(require_admin)]) -> dict:
    return await svc.trigger_retrain()
