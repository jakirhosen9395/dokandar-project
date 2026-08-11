"""
Tests for the OpenAPI generator (openapi_emit): proves the document is generated FROM the contracts,
carries the mandated cross-cutting components, faithfully reflects the registered OHS services, and
fabricates NO business endpoint (only the universal operational paths appear).
"""
import json
import os
import sys
import tempfile

HERE = os.path.dirname(__file__)
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))          # platform-libs
GEN = os.path.join(ROOT, "generators")
CONTRACTS = os.path.join(ROOT, "contracts")
if GEN not in sys.path:
    sys.path.insert(0, GEN)

from dkdgen.contracts import load                                # noqa: E402
from dkdgen.version import build_metadata                        # noqa: E402
from dkdgen.emitters import openapi_emit                         # noqa: E402


def _generate():
    c = load(CONTRACTS)
    meta = build_metadata(c.spine_version, build_time="2026-06-29T00:00:00Z")
    tmp = tempfile.mkdtemp()
    written = openapi_emit.emit(c, meta, tmp)
    doc = json.load(open(os.path.join(tmp, "dkd-platform.openapi.json"), encoding="utf-8"))
    return c, doc, written


def test_openapi_is_valid_31_and_versioned_from_contracts():
    c, doc, _ = _generate()
    assert doc["openapi"].startswith("3.1")
    assert doc["info"]["version"] == c.spine_version
    assert doc["info"]["x-dkd-contract-version"] == c.spine_version


def test_operational_paths_present():
    _, doc, _ = _generate()
    for p in ("/health", "/ready", "/live", "/version"):
        assert p in doc["paths"], "missing operational path %s" % p
        assert "get" in doc["paths"][p]


def test_no_fabricated_business_paths():
    # ONLY the four universal operational endpoints — never an invented business path.
    _, doc, _ = _generate()
    assert set(doc["paths"].keys()) == {"/health", "/ready", "/live", "/version"}


def test_cross_cutting_components_present():
    _, doc, _ = _generate()
    sch = doc["components"]["schemas"]
    for s in ("ResponseEnvelope", "ProblemDetails", "Meta", "PageInfo", "ErrorContextSlug", "Money", "TimestampMs"):
        assert s in sch, "missing component schema %s" % s
    assert doc["components"]["securitySchemes"]["bearerAuth"]["scheme"] == "bearer"
    params = doc["components"]["parameters"]
    assert params["IdempotencyKey"]["required"] is True
    assert "Cursor" in params and "Limit" in params


def test_error_context_enum_matches_contract():
    c, doc, _ = _generate()
    assert doc["components"]["schemas"]["ErrorContextSlug"]["enum"] == list(c.error_taxonomy.context_slugs)


def test_ohs_services_carried_faithfully_with_deferred_proto():
    c, doc, _ = _generate()
    ohs = doc["x-dkd-ohs-services"]
    assert len(ohs) == len(c.ohs_services)
    # every registered OHS operation is carried; proto is NEEDS-INFO (never fabricated)
    for entry in ohs:
        assert entry["protoStatus"] == "NEEDS-INFO"
    assert doc["x-dkd-deferred"]["rest_apis"] == "NEEDS-INFO"
    assert doc["x-dkd-deferred"]["ohs_proto"] == "NEEDS-INFO"


def test_deterministic_regeneration():
    _, d1, _ = _generate()
    _, d2, _ = _generate()
    assert json.dumps(d1, sort_keys=True) == json.dumps(d2, sort_keys=True)
