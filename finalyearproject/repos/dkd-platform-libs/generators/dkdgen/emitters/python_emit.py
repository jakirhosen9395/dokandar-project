"""
dkdgen.emitters.python_emit — emits the Python SDK (`dkd_platform`) from the IR.

REFERENCE emitter: every other language emitter mirrors these exact artifacts/semantics.
Generated = derivable from frozen contracts. Framework-only = blocked-by-NEEDS-INFO (events
payloads, schemas, error-code catalog, OpenAPI/proto) — emitted as typed extension points, never
fabricated.
"""
from __future__ import annotations
import json
from ..ir import Contracts, CONTEXTS
from .base import Writer, pascal, snake, screaming, const_name

PKG = "dkd_platform"
LANG = "python"


def _q(s: str) -> str:
    return json.dumps(s)


def emit(c: Contracts, meta: dict, out_dir: str) -> list[str]:
    w = Writer(out_dir, "#", meta)
    base = "src/%s" % PKG

    # ---- provenance ----
    w.write("%s/_provenance.py" % base,
            "GENERATOR = %s\nGENERATOR_VERSION = %s\nCONTRACT_VERSION = %s\nBUILD_TIME = %s\nBUILD_COMMIT = %s\n" % (
                _q(meta["generator"]), _q(meta["generator_version"]), _q(meta["contract_version"]),
                _q(meta["build_time"]), _q(meta["build_commit"])))

    # ---- money / time ----
    w.write("%s/money.py" % base, '''"""Money is int64 poisha; Timestamp is int64 unix-ms UTC (ids.yaml types)."""
from __future__ import annotations

POISHA_PER_BDT = 100


class Money:
    """Integer poisha. Float/decimal/string money is banned (DM type conventions)."""
    __slots__ = ("poisha",)

    def __init__(self, poisha: int):
        if not isinstance(poisha, int) or isinstance(poisha, bool):
            raise TypeError("Money must be int64 poisha, got %r" % type(poisha).__name__)
        self.poisha = poisha

    @classmethod
    def of_bdt(cls, bdt: int) -> "Money":
        return cls(bdt * POISHA_PER_BDT)

    def __eq__(self, o): return isinstance(o, Money) and o.poisha == self.poisha
    def __hash__(self): return hash(self.poisha)
    def __repr__(self): return "Money(%d poisha)" % self.poisha


class Timestamp:
    """Unix milliseconds, UTC (int64)."""
    __slots__ = ("epoch_ms",)

    def __init__(self, epoch_ms: int):
        if not isinstance(epoch_ms, int) or isinstance(epoch_ms, bool):
            raise TypeError("Timestamp must be int64 epoch_ms")
        self.epoch_ms = epoch_ms

    def __eq__(self, o): return isinstance(o, Timestamp) and o.epoch_ms == self.epoch_ms
    def __hash__(self): return hash(self.epoch_ms)
    def __repr__(self): return "Timestamp(%d)" % self.epoch_ms
''')

    # ---- ids ----
    id_lines = ['"""Strongly-typed identifiers (ids.yaml). No raw-string IDs."""',
                'from __future__ import annotations', '']
    id_lines += [
        "class PrefixedId:",
        '    """Base for prefixed canonical IDs. Validates the canonical prefix; the body is a UUIDv7."""',
        "    PREFIX = \"\"",
        "    OWNER_CONTEXT = 0",
        "    IMMUTABLE = False",
        "",
        "    __slots__ = (\"value\",)",
        "",
        "    def __init__(self, value: str):",
        "        if not isinstance(value, str) or not value.startswith(self.PREFIX) or len(value) <= len(self.PREFIX):",
        "            raise ValueError(\"%s must start with %r and carry a body\" % (type(self).__name__, self.PREFIX))",
        "        self.value = value",
        "",
        "    @classmethod",
        "    def of(cls, value: str):",
        "        return cls(value)",
        "",
        "    def __str__(self): return self.value",
        "    def __eq__(self, o): return type(o) is type(self) and o.value == self.value",
        "    def __hash__(self): return hash((type(self).__name__, self.value))",
        "    def __repr__(self): return \"%s(%r)\" % (type(self).__name__, self.value)",
        "",
    ]
    for i in c.identifiers:
        cls = pascal(i.id)
        id_lines += [
            "class %s(PrefixedId):" % cls,
            "    PREFIX = %s" % _q(i.prefix),
            "    OWNER_CONTEXT = %d  # %s" % (i.owner_ctx, CONTEXTS[i.owner_ctx]),
            "    IMMUTABLE = %s" % ("True" if i.immutable else "False"),
            "",
        ]
    id_lines += ["ALL_ID_TYPES = [%s]" % ", ".join(pascal(i.id) for i in c.identifiers), ""]
    w.write("%s/ids.py" % base, "\n".join(id_lines))

    # ---- topics (events: messaging.yaml) ----
    t_lines = ['"""Kafka topics + RabbitMQ queues (messaging.yaml). Cross-context = Kafka only (R6)."""',
               'from __future__ import annotations', 'from dataclasses import dataclass, field',
               'from typing import Tuple', '']
    t_lines += [
        "@dataclass(frozen=True)",
        "class TopicMeta:",
        "    name: str",
        "    producer: int",
        "    key: str",
        "    consumers: Tuple[int, ...]",
        "    context: str",
        "    aggregate: str",
        "    event: str",
        "    version: int",
        "",
        "@dataclass(frozen=True)",
        "class QueueMeta:",
        "    name: str",
        "    context: int",
        "    purpose: str",
        "    pii: bool",
        "",
        "class KafkaTopics:",
        '    """59 cross-context Published-Language topics (R6)."""',
    ]
    for t in c.topics:
        t_lines.append("    %s = %s" % (const_name(t.name), _q(t.name)))
    t_lines += ["", "class RabbitQueues:", '    """10 intra-context queues — NOT Published Language (R6)."""']
    for q in c.queues:
        t_lines.append("    %s = %s" % (screaming(q.name), _q(q.name)))
    t_lines += ["", "TOPIC_META = {"]
    for t in c.topics:
        t_lines.append("    %s: TopicMeta(%s, %d, %s, %s, %s, %s, %s, %d)," % (
            _q(t.name), _q(t.name), t.producer, _q(t.key), tuple(t.consumers),
            _q(t.context), _q(t.aggregate), _q(t.event), t.version))
    t_lines += ["}", "",
                "def topic_meta(name: str) -> TopicMeta:",
                "    return TOPIC_META[name]", "",
                "ALL_TOPICS = tuple(TOPIC_META.keys())", ""]
    w.write("%s/topics.py" % base, "\n".join(t_lines))

    # ---- config ----
    cfg_lines = ['"""Canon-named operational constants (configuration.yaml). Values are verbatim from canon."""',
                 'from __future__ import annotations', '']
    for k in c.constants:
        cfg_lines.append("%s = %r  # %s — %s" % (screaming(k.id), k.value, k.human, k.scope))
    cfg_lines += ["", "CONSTANTS = {%s}" % ", ".join("%s: %s" % (_q(k.id), screaming(k.id)) for k in c.constants), ""]
    w.write("%s/config.py" % base, "\n".join(cfg_lines))

    # ---- enums (glossary) ----
    e_lines = ['"""Canonical enum families (glossary.yaml; FR-IDN-310). Values transcribed verbatim."""',
               'from __future__ import annotations', 'from enum import Enum', '']
    for f in c.enum_families:
        if not f.values:
            continue
        cls = pascal(f.family)
        exhaustive = (f.exhaustive is True)
        e_lines += ["class %s(str, Enum):" % cls,
                    "    \"\"\"source=%s; exhaustive=%s\"\"\"" % (f.source, exhaustive)]
        for v in f.values:
            e_lines.append("    %s = %s" % (screaming(v), _q(v)))
        if not exhaustive:
            e_lines.append("    # NOTE: contract marks this family non-exhaustive (illustrative); extend on Phase-2 transcription.")
        e_lines.append("")
    w.write("%s/enums.py" % base, "\n".join(e_lines))

    # ---- errors (taxonomy; codes are framework-only/blocked) ----
    slugs = list(c.error_taxonomy.context_slugs)
    w.write("%s/errors.py" % base, '''"""Error taxonomy (error-codes.yaml): dokandar.<context>.<category>.<reason> (RFC-7807).

Concrete codes are NEEDS-INFO in the frozen contracts (error-codes.yaml codes: []), so this module
provides the format-enforcing BUILDER + the context-slug enum + the typed exception hierarchy +
ProblemDetails — never a fabricated code list. Register codes when the contract is populated.
"""
from __future__ import annotations
import re
from dataclasses import dataclass, field
from enum import Enum
from typing import Optional, Dict, Any

CONTEXT_SLUGS = %s
_CODE_RE = re.compile(r"^dokandar\\.([a-z]+)\\.([a-z0-9_]+)\\.([a-z0-9_]+)$")


class ContextSlug(str, Enum):
%s


def error_code(context: str, category: str, reason: str) -> str:
    code = "dokandar.%%s.%%s.%%s" %% (context, category, reason)
    if context not in CONTEXT_SLUGS:
        raise ValueError("unknown context slug: %%s" %% context)
    if not _CODE_RE.match(code):
        raise ValueError("error code violates taxonomy: %%s" %% code)
    return code


@dataclass
class ProblemDetails:
    """RFC-7807 problem+json carried in the response envelope `error`."""
    type: str
    title: str
    status: int
    code: str
    detail: Optional[str] = None
    instance: Optional[str] = None
    trace_id: Optional[str] = None
    extensions: Dict[str, Any] = field(default_factory=dict)


class DokandarError(Exception):
    """Base typed exception. Subclasses map to problem categories."""
    http_status = 500

    def __init__(self, code: str, message: str, detail: Optional[str] = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.detail = detail

    def to_problem(self) -> ProblemDetails:
        return ProblemDetails(type="about:blank", title=self.message,
                              status=self.http_status, code=self.code, detail=self.detail)


class ValidationError(DokandarError):
    http_status = 400


class BusinessError(DokandarError):
    http_status = 409


class InfrastructureError(DokandarError):
    http_status = 503
''' % (repr(tuple(slugs)),
       "\n".join("    %s = %s" % (screaming(s), _q(s)) for s in slugs)))

    # ---- dto / envelope ----
    w.write("%s/dto.py" % base, '''"""Common DTOs: the {success,data,error,meta} envelope, cursor pagination, trace/audit metadata."""
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Generic, TypeVar, Optional, List, Any, Dict
from .errors import ProblemDetails

T = TypeVar("T")


@dataclass
class PageMeta:
    next_cursor: Optional[str] = None
    has_more: bool = False
    limit: int = 0


@dataclass
class TraceMetadata:
    trace_id: Optional[str] = None
    span_id: Optional[str] = None
    correlation_id: Optional[str] = None


@dataclass
class AuditMetadata:
    actor_did: Optional[str] = None
    occurred_at_ms: Optional[int] = None
    request_id: Optional[str] = None


@dataclass
class Meta:
    page: Optional[PageMeta] = None
    trace: Optional[TraceMetadata] = None
    extra: Dict[str, Any] = field(default_factory=dict)


@dataclass
class Response(Generic[T]):
    """The canonical external REST envelope (EF §7)."""
    success: bool
    data: Optional[T] = None
    error: Optional[ProblemDetails] = None
    meta: Optional[Meta] = None

    @classmethod
    def ok(cls, data: T, meta: Optional[Meta] = None) -> "Response[T]":
        return cls(success=True, data=data, meta=meta)

    @classmethod
    def fail(cls, error: ProblemDetails, meta: Optional[Meta] = None) -> "Response[T]":
        return cls(success=False, error=error, meta=meta)


@dataclass
class Page(Generic[T]):
    items: List[T]
    page: PageMeta
''')

    # ---- events (envelope/base + framework; payloads blocked) ----
    w.write("%s/events.py" % base, '''"""Event envelope/base + headers + metadata + topic binding + serializer protocol.

Per-event PAYLOAD classes are FRAMEWORK-ONLY here: schema-registry.yaml carries all 59 subjects with
schema=NEEDS-INFO, so no payload fields exist in the frozen contracts. EventEnvelope is generic over
the payload; concrete payload types are registered when the schema contract is populated (Phase 2).
"""
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Generic, TypeVar, Dict, Any, Optional, Protocol
from .topics import topic_meta, TopicMeta

P = TypeVar("P")


@dataclass(frozen=True)
class EventHeaders:
    event_id: str            # inbox dedup key (effectively-once)
    occurred_at_ms: int
    producer_context: int
    partition_key: str       # per-aggregate ordering key
    correlation_id: Optional[str] = None
    trace_id: Optional[str] = None
    schema_version: int = 1


@dataclass(frozen=True)
class EventMetadata:
    topic: str
    meta: TopicMeta

    @staticmethod
    def for_topic(topic: str) -> "EventMetadata":
        return EventMetadata(topic=topic, meta=topic_meta(topic))


@dataclass
class EventEnvelope(Generic[P]):
    headers: EventHeaders
    topic: str
    payload: P               # payload type is contract-populated in Phase 2 (NEEDS-INFO)


class PayloadSerializer(Protocol[P]):
    """Extension point. Concrete (de)serializers bind once payload schemas are published."""
    def serialize(self, payload: P) -> bytes: ...
    def deserialize(self, data: bytes) -> P: ...
''')

    # ---- schema registry metadata (framework; schemas blocked) ----
    s_lines = ['"""Schema-registry metadata (schema-registry.yaml): subjects + compatibility + version helpers.',
               '',
               'Per-subject JSON-Schema is NEEDS-INFO in the frozen contracts, so get_schema() is an',
               'extension point (raises until populated) — never a fabricated schema.', '"""',
               'from __future__ import annotations', 'from dataclasses import dataclass',
               'from enum import Enum', 'from typing import Dict, Optional', '']
    s_lines += [
        "class Compatibility(str, Enum):",
        "    BACKWARD = \"BACKWARD\"",
        "",
        "@dataclass(frozen=True)",
        "class SubjectInfo:",
        "    subject: str",
        "    topic: str",
        "    compatibility: str",
        "    schema_status: str",
        "",
        "SUBJECTS: Dict[str, SubjectInfo] = {",
    ]
    for s in c.schema_subjects:
        s_lines.append("    %s: SubjectInfo(%s, %s, %s, %s)," % (
            _q(s.subject), _q(s.subject), _q(s.topic), _q(s.compatibility), _q(s.schema_status)))
    s_lines += [
        "}",
        "",
        "def subject_for(topic: str) -> str:",
        "    return SUBJECTS[topic].subject",
        "",
        "def get_schema(subject: str):",
        "    info = SUBJECTS[subject]",
        "    raise NotImplementedError(",
        "        \"schema for %s is NEEDS-INFO in frozen contracts (Phase-2 transcription)\" % subject)",
        "",
        "def is_compatible(subject: str, new_version: int, old_version: int) -> bool:",
        "    # BACKWARD within a major: a higher minor/patch reads older data (EF §8.4).",
        "    return new_version >= old_version",
        "",
    ]
    w.write("%s/schema.py" % base, "\n".join(s_lines))

    # ---- security ----
    sec_lines = ['"""Security helpers: access principles, JWT claim names, correlation/trace propagation.',
                 '',
                 'Role families are the canonical glossary enums (see enums.py: KycTiers/OversightRoles/',
                 'EnforcementActions) — defined once there. The full permission MATRIX is NEEDS-INFO',
                 '(permissions.yaml matrix: NEEDS-INFO); this module provides principle constants only.',
                 '"""',
                 'from __future__ import annotations', 'from dataclasses import dataclass, field',
                 'from typing import Optional, Dict', '']
    sec_lines += ["PRINCIPLES = {"]
    for p in c.principles:
        sec_lines.append("    %s: %s," % (_q(p.id), _q(p.rule)))
    sec_lines += [
        "}",
        "",
        "class JwtClaims:",
        '    """JWT claim names used fleet-wide (SA security; ABAC/RBAC via Identity PDP)."""',
        "    SUBJECT_DID = \"sub\"",
        "    KYC_TIER = \"kyc_tier\"",
        "    ROLES = \"roles\"",
        "    CORRELATION_ID = \"cid\"",
        "",
        "@dataclass",
        "class CorrelationContext:",
        "    correlation_id: Optional[str] = None",
        "    trace_id: Optional[str] = None",
        "    actor_did: Optional[str] = None",
        "",
        "    def headers(self) -> Dict[str, str]:",
        "        h = {}",
        "        if self.correlation_id: h[\"x-correlation-id\"] = self.correlation_id",
        "        if self.trace_id: h[\"traceparent\"] = self.trace_id",
        "        return h",
        "",
    ]
    w.write("%s/security.py" % base, "\n".join(sec_lines))

    # ---- validation ----
    w.write("%s/validation.py" % base, '''"""Validation utilities for IDs, money, the envelope, and config constants."""
from __future__ import annotations
from typing import Any
from . import ids as _ids
from .money import Money
from .topics import TOPIC_META


def validate_id(id_type, value: str):
    """Return a typed ID or raise ValueError."""
    return id_type(value)


def is_valid_id(id_type, value: str) -> bool:
    try:
        id_type(value)
        return True
    except Exception:
        return False


def validate_money(poisha: Any) -> Money:
    return Money(poisha)


def validate_topic(name: str) -> bool:
    return name in TOPIC_META
''')

    # ---- API Documentation Standard helper (FastAPI) — imported lazily so the SDK stays usable
    #      without FastAPI installed. Centralizes /docs + /swagger/v1/swagger.json + Bearer scheme. ----
    w.write("%s/apidocs.py" % base, '''"""API Documentation Standard helper (Python / FastAPI).

Centralizes the platform OpenAPI/Swagger behavior so every service inherits identical docs with one
call: Swagger UI at /docs, OpenAPI JSON at /swagger/v1/swagger.json, OpenAPI document "v1", a Bearer
(JWT) security scheme, and the standard title/description. FastAPI's built-in OpenAPI + Swagger UI is
an implementation detail of this helper.

Usage:
    from dkd_platform import apidocs
    app = FastAPI(**apidocs.platform_docs_kwargs(cfg.service_name), lifespan=lifespan)
    ...  # register routes
    apidocs.configure_platform_docs(app)   # after routes: injects the Bearer security scheme
"""
from typing import Any

DOCS_URL = "/docs"
OPENAPI_URL = "/swagger/v1/swagger.json"
DOCS_CSP = (
    "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; "
    "img-src 'self' data:; font-src 'self'; connect-src 'self'"
)


def platform_docs_kwargs(title: str) -> dict:
    """FastAPI constructor kwargs realising the API Documentation Standard (UI /docs, JSON /swagger/v1/swagger.json)."""
    return {
        "title": title,
        "version": "v1",
        "description": title + " REST API.",
        "docs_url": DOCS_URL,
        "openapi_url": OPENAPI_URL,
        "redoc_url": None,
    }


def is_docs_path(path: str) -> bool:
    """True for the Swagger UI / OpenAPI paths — used to relax CSP for the UI only."""
    return path.startswith("/docs") or path.startswith("/swagger")


def configure_platform_docs(app: Any) -> None:
    """Install a Bearer (JWT) security scheme into the generated OpenAPI document (call after routes)."""
    from fastapi.openapi.utils import get_openapi

    def _openapi() -> dict:
        if app.openapi_schema:
            return app.openapi_schema
        schema = get_openapi(
            title=app.title, version=app.version,
            description=getattr(app, "description", None), routes=app.routes,
        )
        components = schema.setdefault("components", {})
        components.setdefault("securitySchemes", {})["Bearer"] = {
            "type": "http", "scheme": "bearer", "bearerFormat": "JWT",
            "description": "JWT bearer token (injected by the API gateway in production).",
        }
        app.openapi_schema = schema
        return schema

    app.openapi = _openapi
''')

    # ---- package __init__ ----
    w.write("%s/__init__.py" % base,
            '"""dkd_platform — generated DOKANDAR platform SDK (Python)."""\n'
            "from ._provenance import GENERATOR_VERSION, CONTRACT_VERSION\n"
            "from . import ids, money, topics, config, enums, errors, dto, events, schema, security, validation, apidocs\n\n"
            "__version__ = %s\n" % _q(meta["contract_version"]) +
            '__all__ = ["ids","money","topics","config","enums","errors","dto","events","schema","security","validation","apidocs"]\n')

    # ---- pyproject ----
    w.write("pyproject.toml", '''[build-system]
requires = ["setuptools>=68"]
build-backend = "setuptools.build_meta"

[project]
name = "dkd-platform"
version = "%s"
description = "DOKANDAR platform SDK (Python) — generated from dkd-contracts-spine"
requires-python = ">=3.13"
license = {text = "Proprietary"}

[tool.setuptools.packages.find]
where = ["src"]

[tool.pytest.ini_options]
pythonpath = ["src"]
''' % meta["contract_version"], with_banner=False)

    # ---- a generated regression test ----
    w.write("tests/test_generated.py", '''import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))
import dkd_platform as p
from dkd_platform.ids import DID, PPID, GPID
from dkd_platform.money import Money
from dkd_platform.errors import error_code, ContextSlug, ValidationError
from dkd_platform.topics import KafkaTopics, TOPIC_META, RabbitQueues


def test_provenance():
    assert p.CONTRACT_VERSION == %s


def test_ids_typed_and_validated():
    d = DID("did:dokandar:abc")
    assert str(d) == "did:dokandar:abc" and DID.IMMUTABLE and DID.OWNER_CONTEXT == 1
    try:
        PPID("did:dokandar:x")  # wrong prefix
        assert False
    except ValueError:
        pass
    assert GPID("GP-rice-01").value.startswith("GP-")


def test_topics_count_and_meta():
    assert len(TOPIC_META) == 59
    m = TOPIC_META["custody.passport.CustodyInitialized.v1"]
    assert m.producer == 3 and m.key == "PPID"
    assert len([q for q in dir(RabbitQueues) if not q.startswith("_")]) == 10


def test_money_int64_only():
    assert Money(5000).poisha == 5000
    try:
        Money(50.0); assert False
    except TypeError:
        pass


def test_error_taxonomy():
    code = error_code("finance", "idempotency", "duplicate_key")
    assert code == "dokandar.finance.idempotency.duplicate_key"
    try:
        error_code("frobnicate", "x", "y"); assert False
    except ValueError:
        pass
    assert ContextSlug.FINANCE == "finance"
''' % _q(meta["contract_version"]), with_banner=False)

    return list(w.written)
