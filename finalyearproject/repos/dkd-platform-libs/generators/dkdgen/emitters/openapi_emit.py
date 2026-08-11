"""
dkdgen.emitters.openapi_emit — emits the contract-derived OpenAPI 3.1 document.

Scope is bounded by the frozen contracts. api-registry.yaml REGISTERS the REST/gRPC surfaces but
declares every per-endpoint OpenAPI/proto signature NEEDS-INFO ("No endpoint invented", Phase-2). So
this generator emits exactly what the contracts DO specify and never invents an endpoint:

  * the universal operational endpoints every service exposes (/health /ready /live /version),
  * the cross-cutting components mandated by the architecture/conventions: the {success,data,error,meta}
    response envelope, RFC-7807 problem details (taxonomy-pinned `code`), cursor pagination, bearer-JWT
    security, mandatory Idempotency-Key + correlation headers, Money(int64 poisha), TimestampMs(int64),
  * `x-dkd-ohs-services`: the OHS services + operation names registered in canon (proto = NEEDS-INFO).

Per-context business `/v1` REST paths remain in `x-dkd-deferred`. Single IR, no duplicated logic,
deterministic (provenance carried in `info` extensions; no clock/random).
"""
from __future__ import annotations
import json
from ..ir import Contracts
from .base import Writer

LANG = "openapi"


def emit(c: Contracts, meta: dict, out_dir: str) -> list[str]:
    w = Writer(out_dir, "#", meta)
    ver = meta["contract_version"]
    env = {"$ref": "#/components/schemas/ResponseEnvelope"}

    def operational(opid: str, summary: str, ok_desc: str) -> dict:
        return {"get": {
            "operationId": opid, "tags": ["operational"], "summary": summary,
            "description": "Universal operational endpoint implemented by the golden service template.",
            "security": [],
            "responses": {
                "200": {"description": ok_desc,
                        "content": {"application/json": {"schema": env}}},
                "default": {"description": "RFC-7807 problem+json.",
                            "content": {"application/problem+json": {
                                "schema": {"$ref": "#/components/schemas/ProblemDetails"}}}},
            }}}

    ohs = [{
        "id": o.id,
        "ownerContext": o.owner_ctx,
        "ownerContextName": c.contexts.get(o.owner_ctx, str(o.owner_ctx)),
        "protocol": "gRPC",
        "operations": list(o.operations),
        "protoStatus": o.proto_status,
    } for o in c.ohs_services]

    doc = {
        "openapi": "3.1.0",
        "info": {
            "title": "DOKANDAR Platform — Operational & Cross-Cutting API",
            "version": ver,
            "description": (
                "Contract-derived OpenAPI for the DOKANDAR platform. Specifies the universal operational "
                "endpoints every service exposes and the cross-cutting components mandated by the "
                "architecture (response envelope, RFC-7807 problem details, cursor pagination, bearer-JWT "
                "security, idempotency + correlation headers, int64 money/time). Per-context business /v1 "
                "endpoints and OHS gRPC signatures are NEEDS-INFO in the frozen contracts "
                "(api-registry.yaml: 'No endpoint invented', Phase-2) and are intentionally NOT enumerated "
                "here — see x-dkd-deferred. Generated from dkd-contracts-spine@%s; never hand-edited." % ver),
            "x-dkd-generator": meta["generator"],
            "x-dkd-generator-version": meta["generator_version"],
            "x-dkd-contract-version": ver,
            "x-dkd-build-time": meta["build_time"],
            "x-dkd-build-commit": meta["build_commit"],
        },
        "servers": [{"url": "/v1",
                     "description": "External REST surface via api-gateway / BFFs (api-registry: versioned /v1)."}],
        "tags": [{"name": "operational",
                  "description": "Universal health/version endpoints implemented by the golden service template."}],
        "security": [{"bearerAuth": []}],
        "paths": {
            "/health": operational("getHealth", "Health probe", "Service healthy."),
            "/ready": operational("getReady", "Readiness probe", "Service ready (dependencies reachable)."),
            "/live": operational("getLive", "Liveness probe", "Service alive."),
            "/version": operational("getVersion", "Build/contract version",
                                    "contractVersion + sdkGenerator (consumed from dkd-platform)."),
        },
        "components": {
            "securitySchemes": {
                "bearerAuth": {"type": "http", "scheme": "bearer", "bearerFormat": "JWT",
                               "description": "Platform JWT (verified via Identity OHS JWKS). "
                                              "Required on all non-operational routes."},
            },
            "parameters": {
                "Cursor": {"name": "cursor", "in": "query", "required": False, "schema": {"type": "string"},
                           "description": "Opaque forward cursor. Cursor pagination only — offset is banned."},
                "Limit": {"name": "limit", "in": "query", "required": False,
                          "schema": {"type": "integer", "format": "int32", "minimum": 1},
                          "description": "Page size."},
                "IdempotencyKey": {"name": "Idempotency-Key", "in": "header", "required": True,
                                   "schema": {"type": "string"},
                                   "description": "Mandatory on unsafe/money/custody writes; deduped via the inbox."},
                "CorrelationId": {"name": "X-Correlation-Id", "in": "header", "required": False,
                                  "schema": {"type": "string"},
                                  "description": "W3C-traceparent-derived correlation id; echoed in logs."},
            },
            "schemas": {
                "ResponseEnvelope": {
                    "type": "object",
                    "description": "Mandatory response envelope {success,data,error,meta} (API convention).",
                    "required": ["success"],
                    "properties": {
                        "success": {"type": "boolean"},
                        "data": {"description": "Payload on success; null on error."},
                        "error": {"oneOf": [{"$ref": "#/components/schemas/ProblemDetails"}, {"type": "null"}]},
                        "meta": {"$ref": "#/components/schemas/Meta"},
                    }},
                "ProblemDetails": {
                    "type": "object",
                    "description": "RFC-7807 problem detail. 'code' follows the taxonomy %s." % c.error_taxonomy.fmt,
                    "required": ["type", "title", "status", "code"],
                    "properties": {
                        "type": {"type": "string", "format": "uri"},
                        "title": {"type": "string"},
                        "status": {"type": "integer", "format": "int32"},
                        "code": {"type": "string", "pattern": r"^dokandar\.[a-z]+\.[a-z0-9_]+\.[a-z0-9_]+$"},
                        "detail": {"type": "string"},
                        "instance": {"type": "string"},
                        "traceId": {"type": "string"},
                    }},
                "Meta": {"type": "object",
                         "properties": {"pagination": {"$ref": "#/components/schemas/PageInfo"}}},
                "PageInfo": {"type": "object", "description": "Cursor pagination metadata.",
                             "properties": {"nextCursor": {"type": ["string", "null"]},
                                            "hasMore": {"type": "boolean"}}},
                "ErrorContextSlug": {"type": "string", "enum": list(c.error_taxonomy.context_slugs),
                                     "description": "Bounded-context slug in the error-code taxonomy (error-codes.yaml)."},
                "Money": {"type": "integer", "format": "int64",
                          "description": "Integer poisha (int64). Float/decimal/string money is banned."},
                "TimestampMs": {"type": "integer", "format": "int64",
                                "description": "Unix epoch milliseconds, UTC (int64)."},
            },
        },
        "x-dkd-ohs-services": ohs,
        "x-dkd-deferred": {
            "rest_apis": "NEEDS-INFO",
            "ohs_proto": "NEEDS-INFO",
            "rationale": ("Frozen contracts (api-registry.yaml) deliberately omit per-endpoint REST/proto "
                          "signatures — 'No endpoint invented', Phase-2. Enumerating them would require "
                          "fabrication, which platform governance (P2) forbids. They are intentionally "
                          "deferred, not missing."),
            "source": "dkd-contracts-spine/api-registry.yaml",
        },
    }

    w.write("dkd-platform.openapi.json", json.dumps(doc, indent=2, ensure_ascii=False), with_banner=False)
    w.write("README.md", _readme(ver, len(ohs)), with_banner=False)
    return w.written


def _readme(ver: str, ohs_count: int) -> str:
    return (
        "# DOKANDAR Platform OpenAPI (generated)\n\n"
        "`dkd-platform.openapi.json` is generated by `dkdgen` from the frozen contracts "
        "(`dkd-contracts-spine@%s`) — **never hand-edit**; regenerate via `dkdgen generate`.\n\n"
        "## Scope — what IS specified (from contracts)\n"
        "- Universal operational endpoints `/health` `/ready` `/live` `/version` "
        "(implemented and verified in every runtime of the golden service template).\n"
        "- Cross-cutting components mandated by the architecture: `ResponseEnvelope` {success,data,error,meta}, "
        "RFC-7807 `ProblemDetails` (taxonomy-pinned `code`), cursor `PageInfo`, bearer-JWT security scheme, "
        "`Idempotency-Key` + correlation headers, `Money` (int64 poisha), `TimestampMs` (int64).\n"
        "- `x-dkd-ohs-services`: the %d OHS services + operation names registered in canon (api-registry.yaml).\n\n"
        "## Deferred by design — what is NOT specified, and why\n"
        "Per-context business `/v1` REST paths and OHS gRPC `.proto` request/response signatures are "
        "**NEEDS-INFO** in the frozen contracts (`api-registry.yaml`: *\"No endpoint invented\"*, Phase-2). "
        "Emitting them would require fabricating specifications, which platform governance (P2) forbids. "
        "They are therefore **intentionally deferred**, recorded under `x-dkd-deferred`, and will be filled "
        "by a future additive contract revision — **not missing work**. "
        "See `docs/openapi-generation-and-deferral.md`.\n" % (ver, ohs_count)
    )
