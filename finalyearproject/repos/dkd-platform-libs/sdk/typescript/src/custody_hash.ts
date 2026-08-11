// HAND-AUTHORED platform primitive (NOT dkdgen-generated).
// CustodyHash Specification v2 — DM §2 (RFC-8785 subset R1-R9). One of five byte-identical
// runtime implementations; the shared gate is sdk/testvectors/custodyhash_vectors.json (PL-01).
import { createHash } from "node:crypto";

/** A JSON-ish value permitted in a custody event payload. Money/time arrive as bigint/number. */
export type CanonicalValue =
  | string
  | number
  | bigint
  | boolean
  | null
  | undefined
  | CanonicalValue[]
  | { [k: string]: CanonicalValue };

const CTRL_ESCAPES: Record<number, string> = {
  0x08: "\\b", 0x09: "\\t", 0x0a: "\\n", 0x0c: "\\f", 0x0d: "\\r",
};

const UTF8 = new TextEncoder();

/** R3 key ordering: ascending by UTF-8 byte value (not UTF-16 code unit). */
function byUtf8Bytes(a: string, b: string): number {
  const ba = UTF8.encode(a);
  const bb = UTF8.encode(b);
  const n = Math.min(ba.length, bb.length);
  for (let i = 0; i < n; i++) {
    if (ba[i] !== bb[i]) return ba[i] - bb[i];
  }
  return ba.length - bb.length;
}

/** Serialize `value` per CustodyHash Spec v2 rules R1-R9 (see DM §2). */
export function canonical(value: CanonicalValue): string {
  if (value === null || value === undefined) {
    throw new Error("custody: null forbidden outside omitted object members (R2)");
  }
  if (typeof value === "boolean") {
    return value ? "true" : "false"; // R7
  }
  if (typeof value === "bigint") {
    return value.toString(10); // R6 plain decimal
  }
  if (typeof value === "number") {
    // int64 values > 2^53 lose precision as JS `number` and MUST be passed as bigint.
    // The safe-integer boundary (<= 2^53, inclusive) matches the Go/Python oracle exactly.
    if (!Number.isInteger(value) || Math.abs(value) > 2 ** 53) {
      throw new Error(`custody: number ${value} has no canonical encoding — use bigint for int64 (R6)`);
    }
    return value.toString(10); // R6
  }
  if (typeof value === "string") {
    return encString(value);
  }
  if (Array.isArray(value)) {
    return "[" + value.map(canonical).join(",") + "]"; // R8 order preserved, R9 recurse
  }
  if (typeof value === "object") {
    const keys = Object.keys(value)
      .filter((k) => value[k] !== null && value[k] !== undefined) // R2 omit null/absent
      .sort(byUtf8Bytes); // R3
    return "{" + keys.map((k) => encString(k) + ":" + canonical(value[k])).join(",") + "}"; // R4
  }
  throw new TypeError(`custody: type ${typeof value} has no canonical encoding`);
}

/** R5 — UTF-8, no HTML escaping, no \\uXXXX for code points >= U+0080; only mandatory escapes. */
function encString(s: string): string {
  let out = '"';
  for (const ch of s) {
    const o = ch.codePointAt(0)!;
    if (ch === '"') out += '\\"';
    else if (ch === "\\") out += "\\\\";
    else if (CTRL_ESCAPES[o] !== undefined) out += CTRL_ESCAPES[o];
    else if (o < 0x20) out += "\\u" + o.toString(16).padStart(4, "0");
    else out += ch; // literal UTF-8 (incl. <, >, &, Bangla, emoji)
  }
  return out + '"';
}

/** lowercase-hex SHA-256 over canonical(fields) with `eventHash` unconditionally excluded. */
export function eventHash(fields: Record<string, CanonicalValue>): string {
  const canon: Record<string, CanonicalValue> = {};
  for (const [k, v] of Object.entries(fields)) {
    if (k !== "eventHash") canon[k] = v;
  }
  return createHash("sha256").update(canonical(canon), "utf8").digest("hex");
}

/** Recompute the hash of a stored payload (with eventHash present) and report a match. */
export function verifyEvent(fields: Record<string, CanonicalValue>): boolean {
  const recorded = fields["eventHash"];
  if (typeof recorded !== "string" || recorded === "") {
    throw new Error("custody: event has no recorded eventHash");
  }
  return eventHash(fields) === recorded;
}
