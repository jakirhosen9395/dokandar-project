// Code-first migrations under pg_advisory_lock(842011) — fleet pattern. Migration v1 also
// provisions the SELECT-only `gov_read` role over the projection tables: R5 is enforced AT
// THE DATABASE (DM checklist: "Government PostgreSQL: SELECT-only grants"). The owner role
// is used only by the projection workers and the intervention decision store.
using Npgsql;

namespace OversightSvc;

public static class Db
{
    private const long AdvisoryLockKey = 842011;

    private static readonly (int Version, string Description, string[] Statements)[] Migrations =
    [
        (1, "oversight core: 4 DM read models, intervention_cases, outbox/inbox/idempotency, gov_read role",
        [
            """
            CREATE TABLE IF NOT EXISTS national_trade_view (
              trd TEXT PRIMARY KEY,
              seller_did TEXT NOT NULL,
              buyer_did TEXT NOT NULL,
              total_amount_poisha BIGINT NOT NULL,
              status TEXT NOT NULL,
              created_at BIGINT NOT NULL,
              as_of BIGINT NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS national_inventory_summary (
              gpid TEXT PRIMARY KEY,
              total_quantity BIGINT NOT NULL,
              unit TEXT NOT NULL,
              computed_at BIGINT NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS escrow_summary (
              esc TEXT PRIMARY KEY,
              amount_poisha BIGINT NOT NULL,
              status TEXT NOT NULL,
              reference_id TEXT NOT NULL,
              as_of BIGINT NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS party_compliance_view (
              did TEXT PRIMARY KEY,
              kyc_tier TEXT NOT NULL DEFAULT 'UNVERIFIED',
              status TEXT NOT NULL DEFAULT 'ACTIVE',
              suspension_history JSONB NOT NULL DEFAULT '[]',
              fraud_flags JSONB NOT NULL DEFAULT '[]',
              as_of BIGINT NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS intervention_cases (
              con TEXT PRIMARY KEY,
              kind TEXT NOT NULL CHECK (kind IN ('RECALL','TRADE_FREEZE','WALLET_FREEZE')),
              payload JSONB NOT NULL,
              payload_hash TEXT NOT NULL,
              maker_did TEXT NOT NULL,
              checker_did TEXT,
              status TEXT NOT NULL CHECK (status IN
                ('DRAFTED','PROPOSED','APPROVED','ORDERED','REJECTED','CLOSED','LAPSED')),
              reason TEXT,
              directive_id TEXT,
              requested_at BIGINT NOT NULL,
              decided_at BIGINT,
              updated_at BIGINT NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS outbox (
              id BIGSERIAL PRIMARY KEY,
              event_id TEXT NOT NULL UNIQUE,
              topic TEXT NOT NULL,
              partition_key TEXT NOT NULL,
              payload JSONB NOT NULL,
              occurred_at BIGINT NOT NULL,
              published_at BIGINT
            )
            """,
            "CREATE INDEX IF NOT EXISTS outbox_unpublished_idx ON outbox(id) WHERE published_at IS NULL",
            """
            CREATE TABLE IF NOT EXISTS inbox (
              event_id TEXT PRIMARY KEY,
              topic TEXT NOT NULL,
              processed_at BIGINT NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS cmd_idempotency (
              idem_key TEXT NOT NULL,
              endpoint TEXT NOT NULL,
              request_hash TEXT NOT NULL,
              response_status INT NOT NULL,
              response_body JSONB NOT NULL,
              created_at BIGINT NOT NULL,
              PRIMARY KEY (idem_key, endpoint)
            )
            """,
            // R5 at the database: SELECT-only grants for gov_read. The ROLE ITSELF is
            // provisioned by the deploy pipeline with a real credential (reviewer H-3 —
            // PASSWORD NULL cannot authenticate under scram); grants apply when present.
            """
            DO $$ BEGIN
              IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'gov_read') THEN
                GRANT CONNECT ON DATABASE dkd_government TO gov_read;
                GRANT USAGE ON SCHEMA public TO gov_read;
                GRANT SELECT ON national_trade_view, national_inventory_summary,
                  escrow_summary, party_compliance_view, intervention_cases TO gov_read;
              ELSE
                RAISE WARNING 'gov_read role missing — provision it before serving reads (R5)';
              END IF;
            END $$
            """,
        ]),
        (2, "per-field event-time guards on party_compliance_view (reviewer H-2)",
        [
            "ALTER TABLE party_compliance_view ADD COLUMN IF NOT EXISTS kyc_tier_as_of BIGINT NOT NULL DEFAULT 0",
            "ALTER TABLE party_compliance_view ADD COLUMN IF NOT EXISTS status_as_of BIGINT NOT NULL DEFAULT 0",
        ]),
    ];

    public static async Task MigrateAsync(NpgsqlDataSource ds, CancellationToken ct)
    {
        await using var cx = await ds.OpenConnectionAsync(ct);
        await Exec(cx, $"SELECT pg_advisory_lock({AdvisoryLockKey})", ct);
        try
        {
            await Exec(cx,
                "CREATE TABLE IF NOT EXISTS schema_migrations (" +
                "version INT PRIMARY KEY, description TEXT NOT NULL, applied_at BIGINT NOT NULL)", ct);
            foreach (var (version, description, statements) in Migrations)
            {
                await using (var check = new NpgsqlCommand(
                    "SELECT 1 FROM schema_migrations WHERE version = $1", cx))
                {
                    check.Parameters.AddWithValue(version);
                    if (await check.ExecuteScalarAsync(ct) is not null) continue;
                }
                await using var tx = await cx.BeginTransactionAsync(ct);
                foreach (var sql in statements)
                    await Exec(cx, sql, ct, tx);
                await using (var mark = new NpgsqlCommand(
                    "INSERT INTO schema_migrations(version, description, applied_at) VALUES ($1,$2,$3)",
                    cx, tx))
                {
                    mark.Parameters.AddWithValue(version);
                    mark.Parameters.AddWithValue(description);
                    mark.Parameters.AddWithValue(Domain.NowMs());
                    await mark.ExecuteNonQueryAsync(ct);
                }
                await tx.CommitAsync(ct);
            }
        }
        finally
        {
            await Exec(cx, $"SELECT pg_advisory_unlock({AdvisoryLockKey})", ct);
        }
    }

    private static async Task Exec(NpgsqlConnection cx, string sql, CancellationToken ct,
        NpgsqlTransaction? tx = null)
    {
        await using var cmd = new NpgsqlCommand(sql, cx, tx);
        await cmd.ExecuteNonQueryAsync(ct);
    }
}
