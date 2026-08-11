"""Risk gRPC server (async, :GRPC_PORT) — ScoreCheckout | ScoreCOD (§7). Decision-only
responses; internal-token gated (hmac.compare_digest) → UNAUTHENTICATED. Started inside the
FastAPI lifespan as a sibling task."""
from __future__ import annotations
import hmac
import logging

import grpc

from app.config import settings
from app.grpc.codegen import load_stubs
from app.risk import service as svc
from app.risk.schemas import ScoreCheckoutBody, ScoreCODBody

log = logging.getLogger("risk.grpc")


async def _check_internal(ctx: grpc.aio.ServicerContext) -> None:
    md = dict(ctx.invocation_metadata() or [])
    tok = md.get("x-internal-token")
    expected = settings.internal_service_token
    if not tok or not expected or not hmac.compare_digest(str(tok), str(expected)):
        await ctx.abort(grpc.StatusCode.UNAUTHENTICATED, "missing or invalid x-internal-token")


def build_servicer(pb2, pb2_grpc):
    class RiskServicer(pb2_grpc.RiskServicer):
        async def ScoreCheckout(self, request, context):
            await _check_internal(context)
            if not request.user_id or not request.order_id:
                await context.abort(grpc.StatusCode.INVALID_ARGUMENT, "user_id and order_id required")
            body = ScoreCheckoutBody(user_id=request.user_id, order_id=request.order_id,
                                     amount_minor=request.amount_minor,
                                     device_id=request.device_id or None, ip=request.ip or None,
                                     payment_method=request.payment_method or "card")
            res = await svc.score_checkout(body)
            return pb2.ScoreResponse(decision=res.decision, reason_codes=res.reason_codes)

        async def ScoreCOD(self, request, context):
            await _check_internal(context)
            if not request.user_id or not request.order_id:
                await context.abort(grpc.StatusCode.INVALID_ARGUMENT, "user_id and order_id required")
            body = ScoreCODBody(user_id=request.user_id, order_id=request.order_id,
                                amount_minor=request.amount_minor)
            res = await svc.score_cod(body)
            return pb2.ScoreResponse(decision=res.decision, reason_codes=res.reason_codes)
    return RiskServicer


_server: grpc.aio.Server | None = None


async def serve() -> None:
    global _server
    if not settings.grpc_enabled:
        log.info("grpc disabled — skipping")
        return
    pb2, pb2_grpc = load_stubs()
    _server = grpc.aio.server(options=[
        ("grpc.max_send_message_length", 4 * 1024 * 1024),
        ("grpc.max_receive_message_length", 4 * 1024 * 1024),
    ])
    pb2_grpc.add_RiskServicer_to_server(build_servicer(pb2, pb2_grpc)(), _server)
    addr = f"0.0.0.0:{settings.grpc_port}"
    _server.add_insecure_port(addr)
    await _server.start()
    log.warning("grpc Risk listening on %s", addr)
    await _server.wait_for_termination()


async def stop() -> None:
    if _server is not None:
        await _server.stop(grace=5)
