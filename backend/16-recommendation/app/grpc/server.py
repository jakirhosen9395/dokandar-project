"""Recommendation gRPC server (async, port :GRPC_PORT) — architecture §7.

Exposes the same personalization the REST `/feed/me` serves, for low-latency in-fleet
reads (the BFF stitching home-screen tiles). Every RPC requires `x-internal-token`
metadata == settings.internal_service_token, compared constant-time (hmac.compare_digest);
mismatch → UNAUTHENTICATED. Started inside FastAPI's lifespan() as a sibling asyncio task.
"""
from __future__ import annotations
import hmac
import logging

import grpc

from app.config import settings
from app.grpc.codegen import load_stubs
from app.reco import service as svc

log = logging.getLogger("reco.grpc")


async def _check_internal(ctx: grpc.aio.ServicerContext) -> None:
    md = dict(ctx.invocation_metadata() or [])
    tok = md.get("x-internal-token")
    expected = settings.internal_service_token
    if not tok or not expected or not hmac.compare_digest(str(tok), str(expected)):
        await ctx.abort(grpc.StatusCode.UNAUTHENTICATED, "missing or invalid x-internal-token")


def build_servicer(pb2, pb2_grpc):
    class RecommendationServicer(pb2_grpc.RecommendationServicer):
        async def GetFeed(self, request, context):
            await _check_internal(context)
            if not request.user_id:
                await context.abort(grpc.StatusCode.INVALID_ARGUMENT, "user_id required")
            size = request.size if 1 <= request.size <= 100 else settings.feed_default_size
            feed = await svc.get_personal_feed(request.user_id, size)
            fallback = feed.source in ("cold_start", "popularity")
            return pb2.FeedResponse(
                items=[pb2.FeedItem(product_id=str(it.product_id), score=float(it.score), reason=it.reason or "")
                       for it in feed.items],
                strategy=feed.source,
                fallback=fallback,
            )
    return RecommendationServicer


_server: grpc.aio.Server | None = None


async def serve() -> None:
    """Bind + run until stop()."""
    global _server
    if not settings.grpc_enabled:
        log.info("grpc disabled (GRPC_ENABLED=false) — skipping server")
        return
    pb2, pb2_grpc = load_stubs()
    servicer_cls = build_servicer(pb2, pb2_grpc)
    _server = grpc.aio.server(options=[
        ("grpc.max_send_message_length", 4 * 1024 * 1024),
        ("grpc.max_receive_message_length", 4 * 1024 * 1024),
    ])
    pb2_grpc.add_RecommendationServicer_to_server(servicer_cls(), _server)
    addr = f"0.0.0.0:{settings.grpc_port}"
    _server.add_insecure_port(addr)
    await _server.start()
    log.warning("grpc Recommendation listening on %s", addr)
    await _server.wait_for_termination()


async def stop() -> None:
    if _server is not None:
        log.info("grpc server stopping")
        await _server.stop(grace=5)
