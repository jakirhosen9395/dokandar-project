"""
dkdgen.ir — the SINGLE canonical contract model (Intermediate Representation).

Every SDK emitter consumes this one IR, so all four languages have identical semantics.
The IR carries ONLY what the frozen v1.0.0 contracts contain; deferred data is represented
explicitly as NEEDS-INFO status flags (never fabricated).
"""
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any

# Canonical bounded-context map (messaging.yaml header; DM). The single source of context identity.
CONTEXTS: dict[int, str] = {
    1: "identity", 2: "catalog", 3: "custody", 4: "provenance", 5: "inventory", 6: "b2c",
    7: "b2b", 8: "finance", 9: "logistics", 10: "fraud", 11: "government", 12: "analytics",
    13: "platform",
}

NEEDS_INFO = "NEEDS-INFO"


@dataclass(frozen=True)
class TypeConventions:
    money_unit: str            # "poisha"
    money_repr: str            # "int64"
    timestamp_repr: str        # "int64"
    timestamp_unit: str        # "unix-milliseconds"
    uuid_spec: str             # "UUIDv7 (RFC 9562, time-ordered)"
    integer_encoding: str


@dataclass(frozen=True)
class Identifier:
    id: str                    # DID, PPID, ...
    prefix: str                # "did:dokandar:", "PP-", ...
    body: str                  # "uuid7" | "{categoryCode}-{uuid7}"
    owner_ctx: int
    immutable: bool = False


@dataclass(frozen=True)
class PiiIdentifier:
    id: str
    fmt: str
    note: str = ""


@dataclass(frozen=True)
class Topic:
    name: str                  # full topic
    producer: int
    key: str                   # ordering key
    consumers: tuple[int, ...]
    context: str               # derived: segment 1
    aggregate: str             # derived: segment 2
    event: str                 # derived: segment 3 (PascalCase)
    version: int               # derived: vN


@dataclass(frozen=True)
class Queue:
    name: str
    context: int
    purpose: str
    pii: bool = False


@dataclass(frozen=True)
class Constant:
    id: str
    value: Any
    human: str
    scope: str
    rule: str
    configurable: Any


@dataclass(frozen=True)
class EnumFamily:
    family: str
    values: tuple[str, ...]
    exhaustive: Any            # True | NEEDS-INFO
    source: str


@dataclass(frozen=True)
class OhsService:
    id: str
    owner_ctx: int
    operations: tuple[str, ...]
    proto_status: str          # NEEDS-INFO (no proto in frozen contracts)


@dataclass(frozen=True)
class SchemaSubject:
    subject: str
    topic: str
    compatibility: str         # BACKWARD
    schema_status: str         # NEEDS-INFO (no payload schema in frozen contracts)


@dataclass(frozen=True)
class Principle:
    id: str
    rule: str


@dataclass(frozen=True)
class ErrorTaxonomy:
    fmt: str                   # "dokandar.<context>.<category>.<reason>"
    context_slugs: tuple[str, ...]
    categories_status: str     # NEEDS-INFO
    codes: tuple               # () — none in frozen contracts


@dataclass(frozen=True)
class Contracts:
    """The whole frozen spine as one immutable model."""
    spine_version: str
    types: TypeConventions
    identifiers: tuple[Identifier, ...]
    pii_identifiers: tuple[PiiIdentifier, ...]
    ordering_keys: dict
    topics: tuple[Topic, ...]
    queues: tuple[Queue, ...]
    constants: tuple[Constant, ...]
    enum_families: tuple[EnumFamily, ...]
    ohs_services: tuple[OhsService, ...]
    schema_subjects: tuple[SchemaSubject, ...]
    principles: tuple[Principle, ...]
    roles: dict
    error_taxonomy: ErrorTaxonomy
    needs_info: dict = field(default_factory=dict)

    @property
    def contexts(self) -> dict[int, str]:
        return CONTEXTS

    def context_slug(self, n: int) -> str:
        return CONTEXTS[n]
