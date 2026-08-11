from __future__ import annotations
from typing import Annotated
from fastapi import APIRouter, Depends

from app.auth.internal import require_internal_token
from app.auth.jwt import require_admin
from app.risk import service as svc
from app.risk.schemas import (
    ErrorEnvelope, OverrideBody, RuleBody, ScoreCheckoutBody, ScoreCODBody, ScoreResponse,
    ScoreReviewBody,
)


router = APIRouter(prefix="/api/v1/risk")

# Reusable documented error responses (each $refs the shared ErrorEnvelope component).
_ERR = {"model": ErrorEnvelope}
_INTERNAL_ERRORS = {
    401: {"model": ErrorEnvelope, "description": "x-internal-token missing or invalid"},
    422: {"model": ErrorEnvelope, "description": "Request body failed validation"},
    500: {"model": ErrorEnvelope, "description": "Internal error (scrubbed)"},
    503: {"model": ErrorEnvelope, "description": "A traffic-gating dependency is unavailable"},
}
_ADMIN_ERRORS = {
    401: {"model": ErrorEnvelope, "description": "Bearer token missing or invalid"},
    403: {"model": ErrorEnvelope, "description": "admin / platform_staff role required"},
    422: {"model": ErrorEnvelope, "description": "Request body failed validation"},
    500: {"model": ErrorEnvelope, "description": "Internal error (scrubbed)"},
}


@router.post(
    "/score/checkout", response_model=ScoreResponse, operation_id="scoreCheckout",
    summary="Score a checkout for fraud risk",
    description="Internal east-west call (cart/order during checkout). Returns a decision "
                "(`allow`/`review`/`deny`) plus opaque reason codes. The numeric score is "
                "never returned. Authenticated with `x-internal-token`.",
    tags=["scoring"],
    dependencies=[Depends(require_internal_token)],
    responses={200: {"description": "Risk decision"}, **_INTERNAL_ERRORS},
)
async def score_checkout(body: ScoreCheckoutBody) -> ScoreResponse:
    return await svc.score_checkout(body)


@router.post(
    "/score/cod", response_model=ScoreResponse, operation_id="scoreCod",
    summary="Score a cash-on-delivery order",
    description="Scores COD-refusal risk from the user's prior refusal history and order amount. "
                "Authenticated with `x-internal-token`.",
    tags=["scoring"],
    dependencies=[Depends(require_internal_token)],
    responses={200: {"description": "Risk decision"}, **_INTERNAL_ERRORS},
)
async def score_cod(body: ScoreCODBody) -> ScoreResponse:
    return await svc.score_cod(body)


@router.post(
    "/score/review", response_model=ScoreResponse, operation_id="scoreReview",
    summary="Score a review for spam / abuse",
    description="Scans review text with spam/abuse heuristics. Authenticated with "
                "`x-internal-token`.",
    tags=["scoring"],
    dependencies=[Depends(require_internal_token)],
    responses={200: {"description": "Risk decision"}, **_INTERNAL_ERRORS},
)
async def score_review(body: ScoreReviewBody) -> ScoreResponse:
    return await svc.score_review(body)


@router.get(
    "/admin/rules", operation_id="listRiskRules",
    summary="List risk rules",
    description="Returns all configured risk rules (newest first). Requires an admin Bearer JWT.",
    tags=["admin"],
    responses={200: {"description": "Array of risk rules"}, **_ADMIN_ERRORS},
)
async def list_rules(user: Annotated[dict, Depends(require_admin)]) -> list[dict]:
    return await svc.list_rules()


@router.post(
    "/admin/rules", operation_id="createRiskRule",
    summary="Create a risk rule",
    description="Creates a new risk rule for one of the closed-set signals. Requires an admin "
                "Bearer JWT.",
    tags=["admin"],
    responses={200: {"description": "Created risk rule"}, **_ADMIN_ERRORS},
)
async def create_rule(body: RuleBody, user: Annotated[dict, Depends(require_admin)]) -> dict:
    return await svc.create_rule(user, body)


@router.post(
    "/admin/overrides", operation_id="createRiskOverride",
    summary="Create a risk override",
    description="Creates an allow/deny override that fences a specific entity (user/order/shop/"
                "review), optionally with an expiry. Requires an admin Bearer JWT.",
    tags=["admin"],
    responses={200: {"description": "Created override"}, **_ADMIN_ERRORS},
)
async def create_override(body: OverrideBody, user: Annotated[dict, Depends(require_admin)]) -> dict:
    return await svc.create_override(user, body)
