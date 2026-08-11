// HAND-AUTHORED platform primitive (NOT dkdgen-generated).
// Idempotency-Key enforcement (PL-03) for unsafe/money/custody writes (EF-API-6 / EF §21.1):
//   - a write MISSING an Idempotency-Key            → HTTP 400 (Bad Request)
//   - a replay: SAME key + SAME request payload     → the ORIGINAL stored response is returned
//   - a conflict: SAME key + DIFFERENT payload       → HTTP 409 (Conflict)
// Backed by a PLUGGABLE store (the PL-02 inbox / a dedicated idempotency table) — the DB is NOT
// hard-wired here. One of five language implementations sharing the SAME contract.

import { createHash } from "node:crypto";

/** HTTP methods that MUST carry an Idempotency-Key (unsafe/money/custody writes). */
const UNSAFE_METHODS: ReadonlySet<string> = new Set(["POST", "PUT", "PATCH", "DELETE"]);

/** True when the method mutates state and therefore requires an Idempotency-Key. */
export function isUnsafeMethod(method: string): boolean {
  return UNSAFE_METHODS.has(method.toUpperCase());
}

/** SHA-256 (lowercase hex) of a request payload — the fingerprint compared on replay. */
export function fingerprint(payload: string | Uint8Array): string {
  return createHash("sha256").update(payload).digest("hex");
}

/** The record persisted for a completed idempotent request (the response to replay). */
export interface IdempotencyRecord {
  key: string;
  /** {@link fingerprint} of the original request payload. */
  payloadHash: string;
  statusCode: number;
  /** Serialized original response body, replayed verbatim. */
  responseBody: string;
  createdAtMs: number;
}

/**
 * Pluggable persistence for idempotency records. Back it with the PL-02 inbox table or a
 * dedicated `idempotency_keys` table — the helper stays storage-agnostic.
 */
export interface IdempotencyStore {
  /** Fetch a previously stored record for `key`, or null when unseen. */
  find(key: string): Promise<IdempotencyRecord | null>;
  /** Persist a record. Returns false when `key` already existed (lost a concurrent race). */
  save(record: IdempotencyRecord): Promise<boolean>;
}

/** Outcome of {@link decide} — a discriminated union the caller acts on. */
export type IdempotencyOutcome =
  /** No Idempotency-Key on an unsafe write → respond 400. */
  | { kind: "missing-key"; status: 400 }
  /** Same key + same payload → replay the stored response verbatim. */
  | { kind: "replay"; status: number; record: IdempotencyRecord }
  /** Same key + different payload → respond 409. */
  | { kind: "conflict"; status: 409 }
  /** Unseen key → proceed with the write, then persist via {@link IdempotencyStore.save}. */
  | { kind: "proceed"; key: string; payloadHash: string };

export interface IdempotencyRequest {
  method: string;
  /** The `Idempotency-Key` header value (undefined when absent). */
  key?: string;
  /** The raw request payload (body) used to compute the fingerprint. */
  payload: string | Uint8Array;
}

/**
 * Enforce the idempotency contract for one request. Safe methods (GET/HEAD/...) always proceed
 * without a key. This is transport-agnostic: HTTP frameworks map the outcome to a response;
 * the three-branch enforcement logic lives here and is unit-tested against a fake store.
 */
export async function decide(
  store: IdempotencyStore,
  req: IdempotencyRequest,
): Promise<IdempotencyOutcome> {
  if (!isUnsafeMethod(req.method)) {
    return { kind: "proceed", key: req.key ?? "", payloadHash: "" };
  }
  if (!req.key) {
    return { kind: "missing-key", status: 400 };
  }
  const payloadHash = fingerprint(req.payload);
  const existing = await store.find(req.key);
  if (existing) {
    if (existing.payloadHash === payloadHash) {
      return { kind: "replay", status: existing.statusCode, record: existing };
    }
    return { kind: "conflict", status: 409 };
  }
  return { kind: "proceed", key: req.key, payloadHash };
}

/**
 * Persist the response produced for a `proceed` outcome so a later replay returns it verbatim.
 * Call this after the handler has produced its response. Returns the stored record.
 */
export async function remember(
  store: IdempotencyStore,
  outcome: Extract<IdempotencyOutcome, { kind: "proceed" }>,
  statusCode: number,
  responseBody: string,
  nowMs: number = Date.now(),
): Promise<IdempotencyRecord> {
  const record: IdempotencyRecord = {
    key: outcome.key,
    payloadHash: outcome.payloadHash,
    statusCode,
    responseBody,
    createdAtMs: nowMs,
  };
  await store.save(record);
  return record;
}
