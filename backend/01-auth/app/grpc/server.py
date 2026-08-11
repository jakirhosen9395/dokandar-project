"""Auth gRPC server (async, port :GRPC_PORT).

Spec: dokandar_docs/services/auth.md §8. Service `Auth` with:
  - LookupShopkeeper(user_id) → exists, role, status, owner_id
  - GetUserKyc(user_id)        → tier, last_updated_at

Lifecycle: started inside FastAPI's lifespan() as a sibling asyncio task.
Every RPC requires `x-internal-token` metadata equal to
settings.internal_service_token; mismatch → UNAUTHENTICATED.
"""
from __future__ import annotations
import hmac
import logging
import uuid
from typing import Optional

import grpc
from sqlalchemy import select

from app.config import settings
from app.db.models import User
from app.db.session import SessionLocal
from app.grpc.codegen import load_stubs

log = logging.getLogger("auth.grpc")


async def _check_internal(ctx: grpc.aio.ServicerContext) -> None:
    md = dict(ctx.invocation_metadata() or [])
    tok = md.get("x-internal-token") or md.get("x-internal-token".upper())
    expected = settings.internal_service_token
    # constant-time compare to avoid leaking the shared token via response timing
    if not tok or not expected or not hmac.compare_digest(str(tok), str(expected)):
        await ctx.abort(grpc.StatusCode.UNAUTHENTICATED, "missing or invalid x-internal-token")


def build_servicer(pb2, pb2_grpc):
    class AuthServicer(pb2_grpc.AuthServicer):
        async def LookupShopkeeper(self, request, context):
            await _check_internal(context)
            if not request.user_id:
                await context.abort(grpc.StatusCode.INVALID_ARGUMENT, "user_id required")
            try:
                uid = uuid.UUID(request.user_id)
            except ValueError:
                await context.abort(grpc.StatusCode.INVALID_ARGUMENT, "user_id must be UUID")
            async with SessionLocal() as db:
                u: Optional[User] = (await db.execute(
                    select(User).where(User.id == uid)
                )).scalar_one_or_none()
                if u is None:
                    # Spec: exists=false rather than NOT_FOUND so callers can
                    # cheaply check "did this user exist at all?"
                    return pb2.LookupShopkeeperResponse(exists=False)
                return pb2.LookupShopkeeperResponse(
                    exists=True,
                    role=u.role,
                    status=u.status,
                    owner_id="",   # populated when shop_staff land in Shop
                )

        async def GetUserKyc(self, request, context):
            await _check_internal(context)
            if not request.user_id:
                await context.abort(grpc.StatusCode.INVALID_ARGUMENT, "user_id required")
            try:
                uid = uuid.UUID(request.user_id)
            except ValueError:
                await context.abort(grpc.StatusCode.INVALID_ARGUMENT, "user_id must be UUID")
            async with SessionLocal() as db:
                u: Optional[User] = (await db.execute(
                    select(User).where(User.id == uid)
                )).scalar_one_or_none()
                if u is None:
                    await context.abort(grpc.StatusCode.NOT_FOUND, "user not found")
                return pb2.GetUserKycResponse(
                    tier=u.kyc,
                    last_updated_at=u.updated_at.isoformat() if u.updated_at else "",
                )
    return AuthServicer


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
    pb2_grpc.add_AuthServicer_to_server(servicer_cls(), _server)
    addr = f"0.0.0.0:{settings.grpc_port}"
    _server.add_insecure_port(addr)
    await _server.start()
    log.info("grpc Auth listening on %s", addr)
    await _server.wait_for_termination()


async def stop() -> None:
    if _server is not None:
        log.info("grpc server stopping")
        await _server.stop(grace=5)
