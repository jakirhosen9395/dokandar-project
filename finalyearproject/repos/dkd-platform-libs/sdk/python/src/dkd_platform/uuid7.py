# HAND-AUTHORED platform primitive (NOT dkdgen-generated).
# PL-04 — UUIDv7 generator + strict v7 validation (Engineering-Foundation: IDs are UUID v7).
"""RFC-9562 UUID version 7: a real generator plus strict version/variant validation.

The prefixed-ID helpers (ids.py) previously checked prefix + length only, so a v4 or a garbage
body slipped through. This module provides the missing pieces:

  * `generate()`  — a fresh UUIDv7 string: 48-bit Unix-ms timestamp in the high bits, version
    nibble `7`, RFC-4122 variant (`10`), random remainder.
  * `is_valid()`  — True ONLY for a canonical UUIDv7 (version == 7 AND variant == RFC-4122);
    a v4, a nil UUID, or any non-UUID string is rejected.
  * `timestamp_ms()` — the embedded Unix-millisecond timestamp (monotone-ish, sortable).

Stdlib only (`uuid`, `os`, `time`) — no third-party dependency, so every runtime can vendor it.
"""
from __future__ import annotations

import os
import time
import uuid

# UUID string is 8-4-4-4-12 hex = 36 chars; this length is relied on by ids.py to slice the
# trailing UUID out of a (possibly category-segmented) prefixed body.
UUID_STR_LEN = 36

_VERSION_7 = 7


def generate(ms: int | None = None) -> str:
    """Mint a fresh UUIDv7 string. `ms` overrides the timestamp (deterministic tests only)."""
    if ms is None:
        ms = int(time.time() * 1000)
    if ms < 0 or ms >= (1 << 48):
        raise ValueError("uuid7 timestamp must fit in 48 unsigned bits: %d" % ms)
    b = bytearray(ms.to_bytes(6, "big") + os.urandom(10))
    b[6] = (b[6] & 0x0F) | 0x70   # version nibble -> 7
    b[8] = (b[8] & 0x3F) | 0x80   # variant bits   -> 10 (RFC-4122/9562)
    return str(uuid.UUID(bytes=bytes(b)))


def is_valid(value: str) -> bool:
    """True only for a canonical UUIDv7 (correct version nibble AND variant bits)."""
    if not isinstance(value, str):
        return False
    try:
        u = uuid.UUID(value)
    except ValueError:
        return False
    return u.version == _VERSION_7 and u.variant == uuid.RFC_4122


def timestamp_ms(value: str) -> int:
    """Extract the 48-bit Unix-ms timestamp from a UUIDv7. Raises ValueError if not a v7."""
    if not is_valid(value):
        raise ValueError("not a UUIDv7: %r" % value)
    return int.from_bytes(uuid.UUID(value).bytes[0:6], "big")
