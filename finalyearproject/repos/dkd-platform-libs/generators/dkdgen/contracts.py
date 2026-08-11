"""
dkdgen.contracts — parse the frozen v1.0.0 contracts into the single IR.

On load it VERIFIES freeze-lock integrity (sha256 of every contract == spine.lock.yaml) so the
generator can never emit from a drifted/edited contract — this IS the platform-libs side of
"contract compatibility verification". It transcribes nothing it cannot read from the contracts;
deferred data becomes NEEDS-INFO status, never invented.
"""
from __future__ import annotations
import os
import re
import hashlib
import yaml

from .ir import (Contracts, TypeConventions, Identifier, PiiIdentifier, Topic, Queue, Constant,
                 EnumFamily, OhsService, SchemaSubject, Principle, ErrorTaxonomy, CONTEXTS, NEEDS_INFO)

TOPIC_RE = re.compile(r"^([a-z][a-z0-9]*)\.([a-z][a-z0-9]*)\.([A-Z][A-Za-z0-9]+)\.v([1-9][0-9]*)$")


class ContractError(RuntimeError):
    pass


def _load_yaml(d: str, name: str):
    p = os.path.join(d, name)
    if not os.path.isfile(p):
        raise ContractError("missing contract: %s" % name)
    with open(p, encoding="utf-8") as f:
        return yaml.safe_load(f)


def verify_freeze(contracts_dir: str) -> str:
    """Recompute every contract's sha256 and assert it matches spine.lock.yaml. Returns spine version."""
    lock = _load_yaml(contracts_dir, "spine.lock.yaml")
    version = str(lock.get("version"))
    for entry in lock.get("contracts", []):
        fp = os.path.join(contracts_dir, entry["file"])
        if not os.path.isfile(fp):
            raise ContractError("locked contract missing: %s" % entry["file"])
        with open(fp, "rb") as f:
            h = hashlib.sha256(f.read()).hexdigest()
        if h != entry.get("sha256"):
            raise ContractError("FREEZE DRIFT: %s changed vs spine.lock (refusing to generate)" % entry["file"])
    return version


def load(contracts_dir: str) -> Contracts:
    version = verify_freeze(contracts_dir)

    ids_doc = _load_yaml(contracts_dir, "ids.yaml")
    t = ids_doc["types"]
    types = TypeConventions(
        money_unit=t["money"]["unit"], money_repr=t["money"]["repr"],
        timestamp_repr=t["timestamp"]["repr"], timestamp_unit=t["timestamp"]["unit"],
        uuid_spec=t["uuid"]["spec"], integer_encoding=t["integer_encoding"],
    )
    identifiers = tuple(
        Identifier(id=i["id"], prefix=i["prefix"], body=str(i["body"]),
                   owner_ctx=int(i["owner_ctx"]), immutable=bool(i.get("immutable", False)))
        for i in ids_doc["identifiers"])
    pii = tuple(PiiIdentifier(id=p["id"], fmt=p["format"], note=p.get("note", ""))
                for p in ids_doc.get("pii_identifiers", []))
    ordering_keys = dict(ids_doc.get("ordering_keys", {}))

    msg = _load_yaml(contracts_dir, "messaging.yaml")
    topics = []
    for entry in msg["buses"]["kafka"]["topics"]:
        m = TOPIC_RE.match(entry["topic"])
        if not m:
            raise ContractError("topic violates grammar: %s" % entry["topic"])
        topics.append(Topic(
            name=entry["topic"], producer=int(entry["producer"]), key=entry["key"],
            consumers=tuple(int(c) for c in entry["consumers"]),
            context=m.group(1), aggregate=m.group(2), event=m.group(3), version=int(m.group(4))))
    queues = tuple(Queue(name=q["queue"], context=int(q["context"]),
                         purpose=q.get("purpose", ""), pii=bool(q.get("pii", False)))
                   for q in msg["buses"]["rabbitmq"]["queues"])

    cfg = _load_yaml(contracts_dir, "configuration.yaml")
    constants = tuple(Constant(id=c["id"], value=c.get("value_ms", c.get("value")),
                               human=c.get("human", ""), scope=c.get("scope", ""),
                               rule=c.get("rule", ""), configurable=c.get("configurable"))
                      for c in cfg.get("constants", []))

    gloss = _load_yaml(contracts_dir, "glossary.yaml")
    enum_families = tuple(EnumFamily(family=f["family"],
                                     values=tuple(f.get("values", []) or []),
                                     exhaustive=f.get("exhaustive"), source=str(f.get("source", "")))
                          for f in gloss.get("term_families", []))

    api = _load_yaml(contracts_dir, "api-registry.yaml")
    ohs = tuple(OhsService(id=s["id"], owner_ctx=int(s["owner_ctx"]),
                           operations=tuple(s.get("operations", []) or []),
                           proto_status=str(s.get("proto", NEEDS_INFO)))
                for s in api.get("ohs_services", []))

    schema = _load_yaml(contracts_dir, "schema-registry.yaml")
    subjects = tuple(SchemaSubject(subject=s["subject"], topic=s["topic"],
                                   compatibility=str(s.get("compatibility", "BACKWARD")),
                                   schema_status=str(s.get("schema", NEEDS_INFO)))
                     for s in schema.get("subjects", []))

    perm = _load_yaml(contracts_dir, "permissions.yaml")
    principles = tuple(Principle(id=p["id"], rule=p["rule"]) for p in perm.get("principles", []))
    roles = {k: list((v or {}).get("values", []) if isinstance(v, dict) else (v or []))
             for k, v in (perm.get("roles", {}) or {}).items()}

    err = _load_yaml(contracts_dir, "error-codes.yaml")
    tax = err.get("taxonomy", {})
    error_taxonomy = ErrorTaxonomy(
        fmt=tax.get("format", "dokandar.<context>.<category>.<reason>"),
        context_slugs=tuple(tax.get("context_slugs", [])),
        categories_status=str(err.get("categories", NEEDS_INFO)),
        codes=tuple(err.get("codes", []) or []))

    needs_info = {
        "event_payloads": "schema-registry.yaml: all 59 subjects schema=NEEDS-INFO (no payload fields in frozen contracts)",
        "json_schemas": "schema-registry.yaml: per-subject JSON-Schema deferred to Phase-2",
        "openapi_rest": "api-registry.yaml: rest_apis=NEEDS-INFO; OHS proto=NEEDS-INFO (no OpenAPI/proto spec)",
        "error_codes": "error-codes.yaml: codes=[] , categories=NEEDS-INFO (taxonomy frozen, codes deferred)",
        "permission_matrix": "permissions.yaml: matrix=NEEDS-INFO",
    }

    return Contracts(
        spine_version=version, types=types, identifiers=identifiers, pii_identifiers=pii,
        ordering_keys=ordering_keys, topics=tuple(topics), queues=queues, constants=constants,
        enum_families=enum_families, ohs_services=ohs, schema_subjects=subjects,
        principles=principles, roles=roles, error_taxonomy=error_taxonomy, needs_info=needs_info)
