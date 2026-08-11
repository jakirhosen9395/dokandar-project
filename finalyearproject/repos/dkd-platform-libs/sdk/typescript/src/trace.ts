// HAND-AUTHORED platform primitive (NOT dkdgen-generated).
// W3C Trace Context `traceparent` parse/format/inject/extract (PL-05). Replaces the bare header
// passthrough in security.ts. Full OTel-SDK span creation is a SERVICE-level concern; the SDK
// gives correct W3C wire handling + new trace/span-id helpers so trace context propagates across
// outgoing HTTP calls AND event headers (wired into OutboxRelay, EF-OBS-7 / EF §21.1).
// One of five language implementations sharing the SAME contract.

import { randomBytes } from "node:crypto";

/** Header name for W3C trace context (lowercase — HTTP/1 header names are case-insensitive). */
export const TRACEPARENT_HEADER = "traceparent";

/** A parsed W3C traceparent: `version-traceId-spanId-flags`, all lowercase hex. */
export interface TraceParent {
  /** 1 byte / 2 hex. Only `00` is defined; `ff` is invalid. */
  version: string;
  /** 16 bytes / 32 hex, not all-zero. */
  traceId: string;
  /** 8 bytes / 16 hex, not all-zero (the parent/caller span id). */
  spanId: string;
  /** 1 byte / 2 hex. Bit 0 = sampled. */
  flags: string;
}

const HEX2 = /^[0-9a-f]{2}$/;
const HEX16 = /^[0-9a-f]{16}$/;
const HEX32 = /^[0-9a-f]{32}$/;
const ZERO_TRACE = "0".repeat(32);
const ZERO_SPAN = "0".repeat(16);

/** Random non-zero 16-hex span id (8 bytes). */
export function newSpanId(): string {
  let id = randomBytes(8).toString("hex");
  while (id === ZERO_SPAN) id = randomBytes(8).toString("hex");
  return id;
}

/** Random non-zero 32-hex trace id (16 bytes). */
export function newTraceId(): string {
  let id = randomBytes(16).toString("hex");
  while (id === ZERO_TRACE) id = randomBytes(16).toString("hex");
  return id;
}

/** Start a brand-new root trace (sampled) — a fresh trace id + span id, version 00, flags 01. */
export function newRootTraceParent(): TraceParent {
  return { version: "00", traceId: newTraceId(), spanId: newSpanId(), flags: "01" };
}

/**
 * Parse a `traceparent` header value. Returns null on any malformed input (wrong field count,
 * bad lengths, non-hex, all-zero ids, or the invalid `ff` version) — never throws.
 */
export function parseTraceparent(value: string | undefined | null): TraceParent | null {
  if (typeof value !== "string") return null;
  const parts = value.split("-");
  if (parts.length !== 4) return null;
  const [version, traceId, spanId, flags] = parts;
  if (!HEX2.test(version) || version === "ff") return null;
  if (!HEX32.test(traceId) || traceId === ZERO_TRACE) return null;
  if (!HEX16.test(spanId) || spanId === ZERO_SPAN) return null;
  if (!HEX2.test(flags)) return null;
  return { version, traceId, spanId, flags };
}

/** Format a TraceParent back to its `version-traceId-spanId-flags` wire form. */
export function formatTraceparent(tp: TraceParent): string {
  return `${tp.version}-${tp.traceId}-${tp.spanId}-${tp.flags}`;
}

/**
 * Derive the child context to propagate downstream: same trace id, a FRESH span id (this hop
 * becomes the parent of the next). Full span timing/attributes are the service OTel SDK's job.
 */
export function childContext(parent: TraceParent): TraceParent {
  return { version: parent.version, traceId: parent.traceId, spanId: newSpanId(), flags: parent.flags };
}

/** Inject `traceparent` into a mutable header/record carrier (HTTP headers OR event headers). */
export function injectTraceparent<T extends Record<string, string>>(carrier: T, tp: TraceParent): T {
  carrier[TRACEPARENT_HEADER] = formatTraceparent(tp);
  return carrier;
}

/** Extract a TraceParent from a header/record carrier (case-insensitive lookup); null if absent/bad. */
export function extractTraceparent(carrier: Record<string, string | string[] | undefined>): TraceParent | null {
  for (const [k, v] of Object.entries(carrier)) {
    if (k.toLowerCase() !== TRACEPARENT_HEADER) continue;
    const raw = Array.isArray(v) ? v[0] : v;
    return parseTraceparent(raw);
  }
  return null;
}
