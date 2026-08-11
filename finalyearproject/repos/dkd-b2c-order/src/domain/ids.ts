// Canonical IDs (UUID v7 bodies per Domain-Model ID conventions).
import { randomBytes } from "node:crypto";

export function uuid7(unixMs = Date.now()): string {
  const b = randomBytes(16);
  b[0] = Number((BigInt(unixMs) >> 40n) & 0xffn);
  b[1] = Number((BigInt(unixMs) >> 32n) & 0xffn);
  b[2] = (unixMs >>> 24) & 0xff;
  b[3] = (unixMs >>> 16) & 0xff;
  b[4] = (unixMs >>> 8) & 0xff;
  b[5] = unixMs & 0xff;
  b[6] = (b[6] & 0x0f) | 0x70; // version 7
  b[8] = (b[8] & 0x3f) | 0x80; // variant 10
  const h = b.toString("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

export const newOrd = (): string => `ORD-${uuid7()}`;
export const newEventId = (): string => uuid7();

export const isDid = (s: unknown): s is string =>
  typeof s === "string" && s.startsWith("did:dokandar:") && s.length > "did:dokandar:".length;
export const isGpid = (s: unknown): s is string =>
  typeof s === "string" && s.startsWith("GP-") && s.length > 3;
export const isOrd = (s: unknown): s is string =>
  typeof s === "string" && s.startsWith("ORD-") && s.length > 4;
