# HAND-AUTHORED platform primitive (NOT dkdgen-generated).
# PL-05 — W3C traceparent parse/format/inject/extract (R6 spine correlation).
"""W3C Trace Context `traceparent` support for HTTP and the Kafka event spine.

Replaces the bare header pass-through (security.py CorrelationContext) with a real, validated
`traceparent` so a trace stitches across services and across the outbox → Kafka → inbox hop.

Wire format (W3C Trace Context level 1):

    traceparent = version "-" trace-id "-" parent-id "-" trace-flags
                =  2hex   "-"  32hex   "-"   16hex   "-"     2hex

This SDK owns only correct parse / format / inject / extract + a fresh span-id — full OTel span
creation stays a service concern. `to_header()` feeds straight into the PL-02
`OutboxRelay.headers(..., traceparent=...)` so the trace rides the event to the consumer's inbox.
"""
from __future__ import annotations

import os
import re
from dataclasses import dataclass
from typing import Iterable, Mapping, Optional

HEADER = "traceparent"

_VERSION_LEN = 2
_TRACE_ID_LEN = 32
_SPAN_ID_LEN = 16
_FLAGS_LEN = 2

_HEX = re.compile(r"\A[0-9a-f]+\Z")

_INVALID_VERSION = "ff"
_ZERO_TRACE = "0" * _TRACE_ID_LEN
_ZERO_SPAN = "0" * _SPAN_ID_LEN

FLAG_SAMPLED = 0x01


def _is_hex(s: str, length: int) -> bool:
    return len(s) == length and bool(_HEX.match(s))


@dataclass(frozen=True)
class TraceParent:
    """A parsed, validated traceparent. `trace_id`/`span_id` are lowercase hex."""

    trace_id: str
    span_id: str
    flags: int = FLAG_SAMPLED
    version: str = "00"

    @property
    def sampled(self) -> bool:
        return bool(self.flags & FLAG_SAMPLED)

    def format(self) -> str:
        """Serialize back to the wire form (round-trips with `parse`)."""
        return "%s-%s-%s-%02x" % (self.version, self.trace_id, self.span_id, self.flags & 0xFF)

    def child(self) -> "TraceParent":
        """Same trace, a fresh span-id — the correlation of a downstream call/event."""
        return TraceParent(self.trace_id, new_span_id(), self.flags, self.version)


def new_trace_id() -> str:
    return os.urandom(16).hex()


def new_span_id() -> str:
    return os.urandom(8).hex()


def new(sampled: bool = True) -> TraceParent:
    """A brand-new root traceparent (fresh trace-id + span-id)."""
    return TraceParent(new_trace_id(), new_span_id(), FLAG_SAMPLED if sampled else 0)


def parse(header: Optional[str]) -> Optional[TraceParent]:
    """Parse a traceparent header; return None on any malformed / disallowed value."""
    if not header:
        return None
    parts = header.strip().split("-")
    if len(parts) != 4:
        return None
    version, trace_id, span_id, flags = parts
    if not (_is_hex(version, _VERSION_LEN) and _is_hex(trace_id, _TRACE_ID_LEN)
            and _is_hex(span_id, _SPAN_ID_LEN) and _is_hex(flags, _FLAGS_LEN)):
        return None
    if version == _INVALID_VERSION:          # 0xff is forbidden by the spec
        return None
    if trace_id == _ZERO_TRACE or span_id == _ZERO_SPAN:  # all-zero ids are invalid
        return None
    return TraceParent(trace_id, span_id, int(flags, 16), version)


def to_header(tp: TraceParent) -> str:
    """The wire string — for an outgoing HTTP header or `OutboxRelay.headers(traceparent=...)`."""
    return tp.format()


def inject(tp: TraceParent, headers: Optional[Mapping[str, str]] = None) -> dict[str, str]:
    """Return a new header mapping with `traceparent` set (immutable: never mutates the input)."""
    out = dict(headers or {})
    out[HEADER] = tp.format()
    return out


def inject_event_headers(tp: TraceParent,
                         headers: Optional[Iterable[tuple[str, bytes]]] = None
                         ) -> list[tuple[str, bytes]]:
    """Kafka/event header list with `traceparent` appended — mirrors OutboxRelay.headers shape."""
    out = list(headers or [])
    out.append((HEADER, tp.format().encode()))
    return out


def extract(headers: Optional[Mapping[str, str]]) -> Optional[TraceParent]:
    """Inbox side: pull a traceparent out of a header mapping (case-insensitive lookup)."""
    if not headers:
        return None
    for k, v in headers.items():
        if k.lower() == HEADER:
            return parse(v)
    return None
