"""PL-03..PL-06 + PL-08 SDK helpers — idempotency, uuid7, traceparent, http status map, openapi pin.

Stdlib-only, pytest-optional (a runner at the bottom mirrors test_quartet.py) — this environment
has no pytest, so `python3 tests/test_platform_libs.py` proves the three-branch / round-trip claims.
"""
from __future__ import annotations

import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from dkd_platform import apidocs, http_status, idempotency, traceparent, uuid7
from dkd_platform.idempotency import Action, IdempotencyGuard, StoredResponse
from dkd_platform.ids import DID, GPID, PPID


# --- PL-04 UUIDv7 --------------------------------------------------------------------------------

_V7 = "0198c0de-0000-7000-8000-000000000001"          # canonical UUIDv7
_V4 = "9b2e4f7a-1c3d-4a5b-8c6d-2e1f0a3b4c5d"          # version nibble 4
_GARBAGE = "not-a-uuid-at-all"


def test_uuid7_generate_is_valid_and_v7():
    generated = uuid7.generate()
    assert uuid7.is_valid(generated)                   # generator output round-trips through the validator
    assert generated[14] == "7"                        # version nibble
    assert generated[19] in "89ab"                     # variant nibble (RFC-4122)


def test_uuid7_generate_deterministic_timestamp():
    ms = 0x0198C0DE0000
    g = uuid7.generate(ms=ms)
    assert uuid7.timestamp_ms(g) == ms


def test_uuid7_rejects_v4_and_garbage():
    assert uuid7.is_valid(_V7) is True
    assert uuid7.is_valid(_V4) is False                # a v4 body is rejected
    assert uuid7.is_valid(_GARBAGE) is False           # garbage is rejected
    assert uuid7.is_valid("") is False


def test_prefixed_id_validates_embedded_uuid_as_v7():
    assert DID("did:dokandar:" + _V7).value.endswith(_V7)
    assert PPID("PP-" + _V7).value.startswith("PP-")
    assert GPID("GP-rice-" + _V7).value.startswith("GP-")   # category segment permitted
    for bad in ("did:dokandar:" + _V4, "PP-" + _GARBAGE, "GP-rice-fish-" + _V7):
        try:
            DID(bad) if bad.startswith("did") else (PPID(bad) if bad.startswith("PP") else GPID(bad))
            assert False, "expected rejection: %r" % bad
        except ValueError:
            pass


def test_prefixed_id_generate_round_trips():
    d = DID.generate()
    assert isinstance(d, DID) and d.value.startswith("did:dokandar:")
    assert DID(d.value) == d                            # round-trips through the validator
    g = GPID.generate("rice")
    assert g.value.startswith("GP-rice-") and GPID(g.value) == g


# --- PL-03 Idempotency-Key enforcement -----------------------------------------------------------

class FakeIdemStore:
    """In-memory pluggable store (stands in for the PL-02 inbox / an idempotency table)."""

    def __init__(self):
        self._rows: dict[str, StoredResponse] = {}

    def load(self, key):
        return self._rows.get(key)

    def save(self, key, response):
        if key in self._rows:
            return False                                # insert-if-absent (ON CONFLICT DO NOTHING)
        self._rows[key] = response
        return True


def test_idempotency_missing_key_is_400():
    guard = IdempotencyGuard(FakeIdemStore())
    d = guard.begin(None, b'{"amount":100}')
    assert d.action is Action.REJECT and d.status == 400


def test_idempotency_same_key_same_payload_replays():
    store = FakeIdemStore()
    guard = IdempotencyGuard(store)
    payload = b'{"amount":100}'
    assert guard.begin("K1", payload).action is Action.PROCEED
    guard.commit("K1", payload, status=201, body=b'{"txn":"TXN-1"}')

    replay = guard.begin("K1", payload)
    assert replay.action is Action.REPLAY and replay.status == 201
    assert replay.response.body == b'{"txn":"TXN-1"}'   # original response returned verbatim


def test_idempotency_same_key_different_payload_is_409():
    store = FakeIdemStore()
    guard = IdempotencyGuard(store)
    guard.begin("K2", b'{"amount":100}')
    guard.commit("K2", b'{"amount":100}', status=201)

    d = guard.begin("K2", b'{"amount":999}')            # SAME key, DIFFERENT payload
    assert d.action is Action.REJECT and d.status == 409


# --- PL-05 W3C traceparent -----------------------------------------------------------------------

_TP = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"


def test_traceparent_parse_format_round_trip():
    tp = traceparent.parse(_TP)
    assert tp is not None
    assert tp.trace_id == "4bf92f3577b34da6a3ce929d0e0e4736"
    assert tp.span_id == "00f067aa0ba902b7"
    assert tp.sampled is True
    assert tp.format() == _TP                            # parse -> format round-trips


def test_traceparent_rejects_malformed():
    for bad in (None, "", "abc", "00-tooshort-00f067aa0ba902b7-01",
                "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",   # forbidden version ff
                "00-" + "0" * 32 + "-00f067aa0ba902b7-01",                    # all-zero trace-id
                "00-4bf92f3577b34da6a3ce929d0e0e4736-" + "0" * 16 + "-01",    # all-zero span-id
                "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-0g"):   # non-hex flags
        assert traceparent.parse(bad) is None


def test_traceparent_inject_http_and_event_and_extract():
    tp = traceparent.parse(_TP)
    http_headers = traceparent.inject(tp, {"content-type": "application/json"})
    assert http_headers["traceparent"] == _TP and http_headers["content-type"] == "application/json"

    event_headers = traceparent.inject_event_headers(tp, [("event_id", b"e1")])
    assert ("traceparent", _TP.encode()) in event_headers and ("event_id", b"e1") in event_headers

    # to_header feeds straight into the PL-02 OutboxRelay.headers(traceparent=...) contract
    assert traceparent.to_header(tp) == _TP

    # extract is case-insensitive (inbox side)
    assert traceparent.extract({"TraceParent": _TP}).trace_id == tp.trace_id


def test_traceparent_child_new_span_same_trace():
    tp = traceparent.new()
    child = tp.child()
    assert child.trace_id == tp.trace_id and child.span_id != tp.span_id


# --- PL-06 error -> HTTP status vocabulary -------------------------------------------------------

def test_status_map_covers_full_canon_vocabulary():
    cases = {
        http_status.MalformedRequestError("dokandar.b2c.request.malformed", "bad"): 400,
        http_status.BusinessValidationError("dokandar.b2c.order.invalid", "rule"): 422,
        http_status.AuthorizationError("dokandar.finance.authz.denied", "four-eyes"): 403,
        http_status.StateConflictError("dokandar.finance.idempotency.mismatch", "conflict"): 409,
        http_status.LockedError("dokandar.custody.fence.parked", "frozen"): 423,
        http_status.RateLimitError("dokandar.edge.rate.limited", "slow down", retry_after=30): 429,
        http_status.AsyncAcceptedError("dokandar.finance.escrow.accepted", "settling"): 202,
    }
    for exc, expected in cases.items():
        assert http_status.status_for(exc) == expected, (type(exc).__name__, expected)


def test_status_map_retry_after_header_and_default_500():
    rl = http_status.RateLimitError("dokandar.edge.rate.limited", "slow", retry_after=42)
    assert http_status.response_headers(rl) == {"Retry-After": "42"}
    assert http_status.response_headers(http_status.LockedError("x.y.z.w", "m")) == {}
    assert http_status.status_for(ValueError("not a dokandar error")) == 500


# --- PL-08 OpenAPI version pin -------------------------------------------------------------------

def test_openapi_version_pinned_to_310():
    assert apidocs.OPENAPI_VERSION == "3.1.0"
    for drift in ("3.0.1", "3.0.3", "3.1"):
        schema = {"openapi": drift, "info": {}}
        assert apidocs.pin_openapi_version(schema)["openapi"] == "3.1.0"


if __name__ == "__main__":  # pytest-free runner (this environment has no pytest)
    tests = sorted((n, f) for n, f in globals().items()
                   if n.startswith("test_") and callable(f))
    failed = 0
    for name, fn in tests:
        try:
            fn()
            print(f"PASS {name}")
        except Exception as exc:  # noqa: BLE001
            failed += 1
            print(f"FAIL {name}: {exc!r}")
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    sys.exit(1 if failed else 0)
