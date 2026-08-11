// Exactly-once REST commands (fleet semantics, incl. the finance-review hardening):
// the response commits in the SAME tx as the state change keyed (Idempotency-Key, endpoint);
// business rejections are persisted too, so a retry replays the SAME outcome; a concurrent
// duplicate loses the PK race and replays the winner.
import { createHash } from "node:crypto";
import type { PgDb, PgTx } from "../persistence/pg.js";
import { IdemStore } from "../store/spine.js";
import { ApiError } from "../http/router.js";
import { stringifyWithBigInt, RawJson } from "../domain/json.js";

export interface CmdResult { status: number; data: unknown; replayed: boolean }

const sha256 = (s: string): string => createHash("sha256").update(s, "utf8").digest("hex");
const isPkCollision = (e: unknown): boolean =>
  typeof e === "object" && e !== null && (e as { code?: string }).code === "23505";

export class IdemCommands {
  constructor(private readonly db: PgDb, private readonly idem: IdemStore) {}

  async run(idemKey: string, endpoint: string, requestBody: unknown, successStatus: number,
            action: (tx: PgTx) => Promise<unknown>,
            prepare?: () => Promise<void>): Promise<CmdResult> {
    const hash = sha256(JSON.stringify(requestBody ?? {}));
    const existing = await this.idem.find(idemKey, endpoint);
    if (existing) return this.replay(existing.requestHash, existing.status, existing.bodyJson, hash);
    try {
      // Slow outbound work (catalog checks, inventory reserves) happens HERE — never
      // inside withTx, which would pin a pool connection across 8s HTTP timeouts.
      if (prepare) await prepare();
      return await this.db.withTx(async (tx) => {
        const data = await action(tx);
        // stringifyWithBigInt: the response body may carry >2^53 poisha (bigint) — never JSON.stringify
        // it (throws) nor JSON.parse it back (lossy). Store exact bytes; return the original object.
        const body = stringifyWithBigInt(data ?? null);
        await this.idem.insert(tx, idemKey, endpoint, hash, successStatus, body, Date.now());
        return { status: successStatus, data, replayed: false };
      });
    } catch (e) {
      if (isPkCollision(e)) {
        const winner = await this.idem.find(idemKey, endpoint);
        if (winner) return this.replay(winner.requestHash, winner.status, winner.bodyJson, hash);
        throw e;
      }
      if (e instanceof ApiError && e.status < 500) {
        try {
          await this.storeFailure(idemKey, endpoint, hash, e);
        } catch (secondary) {
          // never mask the business verdict with a storage failure
          console.error(JSON.stringify({ level: "error", msg: "idem failure-store failed",
            err: String(secondary) }));
        }
        throw e;
      }
      throw e;
    }
  }

  private async storeFailure(idemKey: string, endpoint: string, hash: string, e: ApiError): Promise<void> {
    const body = JSON.stringify({ __error: { code: e.code, message: e.message } });
    try {
      await this.db.withTx((tx) => this.idem.insert(tx, idemKey, endpoint, hash, e.status, body, Date.now()));
    } catch (raceLost) {
      if (!isPkCollision(raceLost)) throw raceLost;
    }
  }

  private replay(storedHash: string, status: number, bodyJson: string, hash: string): CmdResult {
    if (storedHash !== hash)
      throw new ApiError(409, "dokandar.b2c.request.idempotency_key_reuse",
        "Idempotency-Key was already used with a different request body");
    // Probe only to detect a stored business error; the parsed numbers are NOT trusted for money —
    // the success body is replayed verbatim via RawJson so >2^53 poisha survives the round-trip.
    const probe = JSON.parse(bodyJson) as Record<string, unknown> | null;
    if (probe !== null && typeof probe === "object" && "__error" in probe) {
      const err = (probe as { __error: { code: string; message: string } }).__error;
      throw new ApiError(status, err.code, err.message);
    }
    return { status, data: probe === null ? null : new RawJson(bodyJson), replayed: true };
  }
}
