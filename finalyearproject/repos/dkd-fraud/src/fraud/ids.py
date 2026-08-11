"""Canonical IDs — UUID v7 bodies per the DM ID conventions; fraud's ordering key is the DID."""

from __future__ import annotations

import os
import time

DID_PREFIX = "did:dokandar:"


def uuid7() -> str:
    ms = int(time.time() * 1000)
    rand = bytearray(os.urandom(16))
    rand[0] = (ms >> 40) & 0xFF
    rand[1] = (ms >> 32) & 0xFF
    rand[2] = (ms >> 24) & 0xFF
    rand[3] = (ms >> 16) & 0xFF
    rand[4] = (ms >> 8) & 0xFF
    rand[5] = ms & 0xFF
    rand[6] = (rand[6] & 0x0F) | 0x70
    rand[8] = (rand[8] & 0x3F) | 0x80
    h = rand.hex()
    return f"{h[0:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}"


def new_event_id() -> str:
    return uuid7()


def new_signal_id() -> str:
    return "FSG-" + uuid7()


def is_did(s: object) -> bool:
    return isinstance(s, str) and s.startswith(DID_PREFIX) and len(s) > len(DID_PREFIX)


def now_ms() -> int:
    return int(time.time() * 1000)
