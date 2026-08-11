// offline-sync-gateway — DOKANDAR edge (R8 offline-first store-and-forward). A feature-phone/2G device
// that acted offline queues its writes locally, then flushes the queue here as ONE ordered batch. This
// gateway replays each operation IN ORDER to the fleet — carrying the device's Idempotency-Key so a
// re-flushed batch (spotty 2G) never double-applies. HLC timestamps preserve the device's causal order.
//
// Server-side replay-safety = the target contexts' Idempotency-Key inboxes (a queued op MUST carry a
// stable idempotencyKey); this gateway just forwards + orders, never a business write of its own.

export interface SyncOp {
  opId: string;
  idempotencyKey: string;
  method: "POST" | "PATCH" | "PUT";
  path: string; // an allow-listed /v1/... write path
  body?: unknown;
  hlc?: string; // device hybrid-logical-clock stamp (causal order)
}

export interface OpResult {
  opId: string;
  status: number;
  ok: boolean;
  data?: unknown;
  error?: string;
}

export type Forwarder = (op: SyncOp) => Promise<{ status: number; body: unknown }>;

// Only replay write ops onto the allow-listed write surface (never /internal/*, never arbitrary hosts).
const ALLOW = [/^\/v1\/b2c\/orders/, /^\/v1\/parties/, /^\/v1\/custody\//, /^\/v1\/logistics\//, /^\/v1\/finance\//];

export function isAllowed(path: string): boolean {
  return ALLOW.some((re) => re.test(path));
}

/** Validate + order a batch, then replay each op in sequence (a failed op does NOT abort the rest —
 *  the device gets a per-op verdict and can re-flush only the failures). */
export async function replayBatch(ops: SyncOp[], forward: Forwarder): Promise<OpResult[]> {
  // deterministic causal order: by HLC when present, else preserve submission order.
  const ordered = [...ops].map((o, i) => ({ o, i }))
    .sort((a, b) => (a.o.hlc && b.o.hlc ? a.o.hlc.localeCompare(b.o.hlc) : a.i - b.i))
    .map((x) => x.o);

  const results: OpResult[] = [];
  for (const op of ordered) {
    if (!op.opId || !op.idempotencyKey || !op.method || !op.path) {
      results.push({ opId: op.opId ?? "?", status: 400, ok: false, error: "opId, idempotencyKey, method, path are required" });
      continue;
    }
    if (!isAllowed(op.path)) {
      results.push({ opId: op.opId, status: 403, ok: false, error: `path not permitted for offline replay: ${op.path}` });
      continue;
    }
    try {
      const { status, body } = await forward(op);
      results.push({ opId: op.opId, status, ok: status >= 200 && status < 300, data: (body as any)?.data ?? body });
    } catch (e) {
      results.push({ opId: op.opId, status: 503, ok: false, error: String(e) });
    }
  }
  return results;
}
