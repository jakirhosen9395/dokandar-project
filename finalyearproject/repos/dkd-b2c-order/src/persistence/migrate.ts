// Code-first migrations under pg_advisory_lock (fleet pattern; b2c key 842006).
// Applied versions are skipped; each version runs in one transaction.
import pg from "pg";

const ADVISORY_LOCK_KEY = 842006;

export interface Migration { version: number; description: string; statements: string[] }

export async function migrate(dsn: string, migrations: Migration[],
                              log: (msg: string) => void): Promise<void> {
  const client = new pg.Client({ connectionString: dsn });
  await client.connect();
  try {
    await client.query(`SELECT pg_advisory_lock(${ADVISORY_LOCK_KEY})`);
    await client.query(
      "CREATE TABLE IF NOT EXISTS schema_migrations (" +
      "version INT PRIMARY KEY, description TEXT NOT NULL, applied_at BIGINT NOT NULL)");
    for (const m of migrations) {
      const seen = await client.query("SELECT 1 FROM schema_migrations WHERE version = $1", [m.version]);
      if (seen.rowCount) continue;
      try {
        await client.query("BEGIN");
        for (const sql of m.statements) await client.query(sql);
        await client.query(
          "INSERT INTO schema_migrations(version, description, applied_at) VALUES ($1,$2,$3)",
          [m.version, m.description, Date.now()]);
        await client.query("COMMIT");
        log(`migration v${m.version} applied: ${m.description}`);
      } catch (e) {
        await client.query("ROLLBACK").catch(() => undefined);
        throw e;
      }
    }
  } finally {
    await client.query(`SELECT pg_advisory_unlock(${ADVISORY_LOCK_KEY})`).catch(() => undefined);
    await client.end();
  }
}
