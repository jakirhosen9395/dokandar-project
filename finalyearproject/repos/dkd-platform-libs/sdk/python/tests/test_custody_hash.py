"""Cross-language CustodyHash gate (Python side) — asserts the shared golden fixture."""
import json
import os

from dkd_platform import custody_hash

_FIXTURE = os.path.join(
    os.path.dirname(__file__), "..", "..", "testvectors", "custodyhash_vectors.json"
)


def _load():
    with open(os.path.abspath(_FIXTURE), encoding="utf-8") as f:
        return json.load(f)["vectors"]


def test_canonical_and_digest_match_shared_fixture():
    for v in _load():
        canon = custody_hash.canonical(
            {k: val for k, val in v["fields"].items() if k != "eventHash"}
        )
        assert canon == v["canonical"], f"{v['name']} canonical mismatch"
        assert custody_hash.event_hash(v["fields"]) == v["digest"], f"{v['name']} digest mismatch"


def test_tv01_known_digest():
    tv01 = next(v for v in _load() if v["name"] == "TV-01-genesis")
    assert tv01["digest"] == "ac543fecee75695fb2b1922ea9e0830f4bddb6ef1ad17e80f278d6171cbe0597"


def test_event_hash_excludes_eventhash():
    fields = {"ppid": "PP-1", "previousHash": "", "eventHash": "f" * 64}
    without = {"ppid": "PP-1", "previousHash": ""}
    assert custody_hash.event_hash(fields) == custody_hash.event_hash(without)


def test_verify_event_roundtrip():
    fields = {"ppid": "PP-1", "quantity": 5, "previousHash": ""}
    h = custody_hash.event_hash(fields)
    assert custody_hash.verify_event({**fields, "eventHash": h}) is True
    assert custody_hash.verify_event({**fields, "eventHash": "0" * 64}) is False
