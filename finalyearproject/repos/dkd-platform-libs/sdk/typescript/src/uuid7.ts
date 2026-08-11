// HAND-AUTHORED platform primitive (NOT dkdgen-generated).
// UUID v7 generator + validator (PL-04). DOKANDAR IDs are UUID v7 (DM-TYPE-003):
// unix-ms timestamp in the high 48 bits, version nibble 7, RFC-4122 variant (10xx).
// The generated id validators only checked prefix+length; this adds a REAL v7 check so a
// v4/garbage body is rejected, plus a spec-conformant generator.
// One of five language implementations sharing the SAME contract.

import { randomBytes } from "node:crypto";

/** Canonical 8-4-4-4-12 lowercase-hex UUID shape (any version/variant). */
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** Format a 16-byte buffer as a canonical lowercase-hex UUID string. */
function bytesToUuid(b: Uint8Array): string {
  const hex = Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
  return (
    hex.slice(0, 8) + "-" + hex.slice(8, 12) + "-" + hex.slice(12, 16) + "-" +
    hex.slice(16, 20) + "-" + hex.slice(20, 32)
  );
}

/**
 * Generate a UUID v7. The high 48 bits are `unix_ts_ms` (big-endian); the version nibble is
 * 7 and the variant bits are 10; the remaining 74 bits are random. Monotonic-enough for IDs;
 * this is NOT a sortable-within-millisecond generator (no sub-ms counter) — that is not required.
 * @param unixTsMs override the timestamp (defaults to Date.now()); must be a non-negative int48.
 */
export function uuidv7(unixTsMs: number = Date.now()): string {
  if (!Number.isInteger(unixTsMs) || unixTsMs < 0 || unixTsMs > 0xffffffffffff) {
    throw new Error(`uuidv7: unixTsMs must be a non-negative 48-bit integer, got ${unixTsMs}`);
  }
  const b = randomBytes(16);
  // 48-bit big-endian timestamp in bytes 0..5.
  b[0] = (unixTsMs / 2 ** 40) & 0xff;
  b[1] = (unixTsMs / 2 ** 32) & 0xff;
  b[2] = (unixTsMs / 2 ** 24) & 0xff;
  b[3] = (unixTsMs / 2 ** 16) & 0xff;
  b[4] = (unixTsMs / 2 ** 8) & 0xff;
  b[5] = unixTsMs & 0xff;
  // Version 7 in the high nibble of byte 6.
  b[6] = (b[6] & 0x0f) | 0x70;
  // Variant 10xx in the high bits of byte 8.
  b[8] = (b[8] & 0x3f) | 0x80;
  return bytesToUuid(b);
}

/** True when `value` is a syntactically valid UUID v7 (version nibble 7 + RFC-4122 variant). */
export function isUuidV7(value: string): boolean {
  if (typeof value !== "string" || !UUID_RE.test(value)) return false;
  // version nibble = first hex char of the 3rd group.
  if (value[14] !== "7") return false;
  // variant = high bits of the 4th group's first nibble must be 10xx → hex 8,9,a,b.
  const variant = value[19];
  return variant === "8" || variant === "9" || variant === "a" || variant === "b";
}

/** Assert `value` is a UUID v7, throwing a descriptive error otherwise. Returns the value. */
export function assertUuidV7(value: string): string {
  if (!isUuidV7(value)) {
    throw new Error(`not a UUID v7: ${JSON.stringify(value)}`);
  }
  return value;
}

/** Extract the embedded unix-ms timestamp from a UUID v7 (its high 48 bits). */
export function timestampOf(uuid: string): number {
  assertUuidV7(uuid);
  const hex = uuid.replace(/-/g, "").slice(0, 12);
  return parseInt(hex, 16);
}
