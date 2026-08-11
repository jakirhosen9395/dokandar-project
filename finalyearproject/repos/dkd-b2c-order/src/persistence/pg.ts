// Concrete Postgres adapter over `pg`. One bounded context = one DB (dkd_b2c, R6).
import pg from "pg";
import type { Db, Tx } from "./persistence.js";

export interface Row { [column: string]: unknown }

export interface PgTx extends Tx {
  query(sql: string, args?: unknown[]): Promise<Row[]>;
}

export class PgDb implements Db {
  private readonly pool: pg.Pool;

  constructor(dsn: string) {
    this.pool = new pg.Pool({ connectionString: dsn, max: 10 });
  }

  async ping(): Promise<void> {
    await this.pool.query("SELECT 1");
  }

  async query(sql: string, args: unknown[] = []): Promise<Row[]> {
    const res = await this.pool.query(sql, args);
    return res.rows as Row[];
  }

  async withTx<T>(fn: (tx: PgTx) => Promise<T>): Promise<T> {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const tx: PgTx = {
        exec: async (sql, args = []) => { await client.query(sql, args as unknown[]); },
        query: async (sql, args = []) => (await client.query(sql, args as unknown[])).rows as Row[],
      };
      const out = await fn(tx);
      await client.query("COMMIT");
      return out;
    } catch (e) {
      await client.query("ROLLBACK").catch(() => undefined);
      throw e;
    } finally {
      client.release();
    }
  }

  async close(): Promise<void> {
    await this.pool.end();
  }
}
