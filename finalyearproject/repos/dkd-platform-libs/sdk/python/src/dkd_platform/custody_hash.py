# HAND-AUTHORED platform primitive (NOT dkdgen-generated).
# CustodyHash Specification v2 — DM §2 (RFC-8785 subset R1-R9). One of five byte-identical
# runtime implementations; the shared gate is sdk/testvectors/custodyhash_vectors.json (PL-01).
"""Deterministic canonical-JSON serializer + SHA-256 event-hash for the custody chain.

All five runtimes (Go/Java/C#/Python/Node-TS) MUST produce byte-identical `canonical()` output
and identical `event_hash()` digests for every vector in the shared test-vector fixture.
"""
from __future__ import annotations

import hashlib
from typing import Any

_CTRL_ESCAPES = {0x08: "\\b", 0x09: "\\t", 0x0A: "\\n", 0x0C: "\\f", 0x0D: "\\r"}


def canonical(value: Any) -> str:
    """Serialize `value` per CustodyHash Spec v2 rules R1-R9 (see DM §2)."""
    # R7 booleans — MUST be tested before int (bool is a subclass of int in Python).
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        raise ValueError("custody: null forbidden outside omitted object members (R2)")
    if isinstance(value, dict):
        # R2 omit null members; R3 sort keys ascending by UTF-8 byte value.
        keys = sorted(k for k, v in value.items() if v is not None)
        return "{" + ",".join(_enc_str(k) + ":" + canonical(value[k]) for k in keys) + "}"  # R4
    if isinstance(value, (list, tuple)):
        return "[" + ",".join(canonical(e) for e in value) + "]"  # R8 order preserved, R9 recurse
    if isinstance(value, int):
        return str(value)  # R6 plain decimal
    if isinstance(value, float):
        # Payloads are built natively with int; floats appear only after a JSON round-trip.
        # Integral floats re-encode as R6 integers; anything else has no canonical encoding.
        if value.is_integer() and abs(value) <= 2 ** 53:
            return str(int(value))
        raise ValueError(f"custody: non-integral number {value!r} has no canonical encoding (R6)")
    if isinstance(value, str):
        return _enc_str(value)
    raise TypeError(f"custody: type {type(value).__name__} has no canonical encoding")


def _enc_str(s: str) -> str:
    """R5 — UTF-8, no HTML escaping, no \\uXXXX for code points >= U+0080; only mandatory escapes."""
    out = ['"']
    for ch in s:
        o = ord(ch)
        if ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        elif o in _CTRL_ESCAPES:
            out.append(_CTRL_ESCAPES[o])
        elif o < 0x20:
            out.append("\\u%04x" % o)
        else:
            out.append(ch)  # literal UTF-8 (incl. <, >, &, Bangla, emoji)
    out.append('"')
    return "".join(out)


def event_hash(fields: dict[str, Any]) -> str:
    """lowercase-hex SHA-256 over canonical(fields) with `eventHash` unconditionally excluded.

    `previousHash`, when the event type carries one, must already be present in `fields`
    (including the genesis empty string "").
    """
    canon = {k: v for k, v in fields.items() if k != "eventHash"}
    return hashlib.sha256(canonical(canon).encode("utf-8")).hexdigest()


def verify_event(fields: dict[str, Any]) -> bool:
    """Recompute the hash of a stored payload (with eventHash present) and report a match."""
    recorded = fields.get("eventHash")
    if not isinstance(recorded, str) or recorded == "":
        raise ValueError("custody: event has no recorded eventHash")
    return event_hash(fields) == recorded
