package com.dokandar.finance.db;

import jakarta.annotation.PostConstruct;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.List;
import javax.sql.DataSource;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

/**
 * Code-first migrations under pg_advisory_lock(842008) — fleet pattern (catalog n/a,
 * custody 842003, inventory 842005). Applied versions are skipped; each version runs
 * in one transaction. Runs in @PostConstruct so it completes before Kafka listeners
 * (SmartLifecycle) start.
 */
@Component
public class MigrationRunner {
    private static final Logger log = LoggerFactory.getLogger(MigrationRunner.class);
    private static final long ADVISORY_LOCK_KEY = 842008L;

    private record Migration(int version, String description, List<String> statements) {}

    private final DataSource dataSource;

    public MigrationRunner(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    @PostConstruct
    public void migrate() throws SQLException {
        try (Connection cx = dataSource.getConnection()) {
            cx.setAutoCommit(true);
            try (Statement st = cx.createStatement()) {
                st.execute("SELECT pg_advisory_lock(" + ADVISORY_LOCK_KEY + ")");
            }
            try {
                ensureVersionTable(cx);
                for (Migration m : MIGRATIONS) {
                    if (isApplied(cx, m.version())) continue;
                    apply(cx, m);
                    log.info("migration v{} applied: {}", m.version(), m.description());
                }
            } finally {
                try (Statement st = cx.createStatement()) {
                    st.execute("SELECT pg_advisory_unlock(" + ADVISORY_LOCK_KEY + ")");
                }
            }
        }
    }

    private void ensureVersionTable(Connection cx) throws SQLException {
        try (Statement st = cx.createStatement()) {
            st.execute("CREATE TABLE IF NOT EXISTS schema_migrations (" +
                "version INT PRIMARY KEY, description TEXT NOT NULL, applied_at BIGINT NOT NULL)");
        }
    }

    private boolean isApplied(Connection cx, int version) throws SQLException {
        try (var ps = cx.prepareStatement("SELECT 1 FROM schema_migrations WHERE version = ?")) {
            ps.setInt(1, version);
            try (ResultSet rs = ps.executeQuery()) {
                return rs.next();
            }
        }
    }

    private void apply(Connection cx, Migration m) throws SQLException {
        cx.setAutoCommit(false);
        try {
            try (Statement st = cx.createStatement()) {
                for (String sql : m.statements()) st.execute(sql);
            }
            try (var ps = cx.prepareStatement(
                    "INSERT INTO schema_migrations(version, description, applied_at) VALUES (?,?,?)")) {
                ps.setInt(1, m.version());
                ps.setString(2, m.description());
                ps.setLong(3, System.currentTimeMillis());
                ps.execute();
            }
            cx.commit();
        } catch (SQLException e) {
            cx.rollback();
            throw e;
        } finally {
            cx.setAutoCommit(true);
        }
    }

    private static final List<Migration> MIGRATIONS = List.of(
        new Migration(1, "finance core: wallets, mfs, WORM ledger, escrows, limits, outbox/inbox/idempotency", List.of(
            """
            CREATE TABLE IF NOT EXISTS wallets (
              wlt TEXT PRIMARY KEY,
              owner_did TEXT NOT NULL UNIQUE,
              status TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','FROZEN','CLOSED')),
              kyc_tier TEXT NOT NULL DEFAULT 'V1' CHECK (kyc_tier IN ('V0','V1','V2','V3')),
              freeze_reason TEXT,
              freeze_ref TEXT,
              created_at BIGINT NOT NULL,
              updated_at BIGINT NOT NULL
            )""",
            """
            CREATE TABLE IF NOT EXISTS mfs_accounts (
              id TEXT PRIMARY KEY,
              wlt TEXT NOT NULL REFERENCES wallets(wlt),
              provider TEXT NOT NULL,
              mobile TEXT NOT NULL,
              account_name TEXT NOT NULL,
              is_primary BOOLEAN NOT NULL DEFAULT FALSE,
              status TEXT NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','VERIFIED','REMOVED')),
              created_at BIGINT NOT NULL
            )""",
            "CREATE UNIQUE INDEX IF NOT EXISTS mfs_one_primary ON mfs_accounts(wlt) WHERE is_primary",
            """
            CREATE TABLE IF NOT EXISTS ledger_entries (
              id BIGSERIAL PRIMARY KEY,
              txn_id TEXT NOT NULL,
              account TEXT NOT NULL,
              entry_type TEXT NOT NULL CHECK (entry_type IN ('DEBIT','CREDIT')),
              amount_poisha BIGINT NOT NULL CHECK (amount_poisha > 0),
              counterpart_account TEXT,
              reference_id TEXT NOT NULL,
              reference_type TEXT NOT NULL CHECK (reference_type IN
                ('ORDER','TRADE','ESCROW','DEPOSIT','WITHDRAWAL','MFS_SETTLEMENT')),
              is_withdrawable BOOLEAN NOT NULL DEFAULT TRUE,
              idempotency_key TEXT,
              created_at BIGINT NOT NULL
            )""",
            "CREATE INDEX IF NOT EXISTS ledger_account_idx ON ledger_entries(account)",
            "CREATE INDEX IF NOT EXISTS ledger_txn_idx ON ledger_entries(txn_id)",
            "CREATE INDEX IF NOT EXISTS ledger_account_day_idx ON ledger_entries(account, created_at)",
            """
            CREATE OR REPLACE FUNCTION ledger_entries_worm() RETURNS trigger AS $$
            BEGIN
              RAISE EXCEPTION 'ledger_entries is append-only (WORM): % blocked', TG_OP;
            END $$ LANGUAGE plpgsql""",
            "DROP TRIGGER IF EXISTS ledger_worm ON ledger_entries",
            """
            CREATE TRIGGER ledger_worm BEFORE UPDATE OR DELETE ON ledger_entries
            FOR EACH ROW EXECUTE FUNCTION ledger_entries_worm()""",
            """
            CREATE TABLE IF NOT EXISTS escrows (
              esc TEXT PRIMARY KEY,
              reference_id TEXT NOT NULL,
              reference_type TEXT NOT NULL,
              buyer_wlt TEXT NOT NULL REFERENCES wallets(wlt),
              seller_wlt TEXT NOT NULL REFERENCES wallets(wlt),
              amount_poisha BIGINT NOT NULL CHECK (amount_poisha > 0),
              status TEXT NOT NULL CHECK (status IN
                ('ACTIVE','SETTLEMENT_HELD','RELEASED','REVERSED','CLAWED_BACK','EXPIRED')),
              pod_evidence TEXT,
              reason TEXT,
              created_at BIGINT NOT NULL,
              released_at BIGINT,
              cooling_off_expires_at BIGINT,
              closed_at BIGINT,
              UNIQUE (reference_id, reference_type)
            )""",
            """
            CREATE TABLE IF NOT EXISTS wallet_limits (
              tier TEXT PRIMARY KEY,
              single_txn_max_poisha BIGINT,
              daily_out_max_poisha BIGINT,
              max_balance_poisha BIGINT
            )""",
            """
            INSERT INTO wallet_limits(tier, single_txn_max_poisha, daily_out_max_poisha, max_balance_poisha) VALUES
              ('V0', NULL, 0, 500000),
              ('V1', 2500000, 5000000, 50000000),
              ('V2', 50000000, 100000000, 1000000000),
              ('V3', NULL, NULL, NULL)
            ON CONFLICT (tier) DO NOTHING""",
            """
            CREATE TABLE IF NOT EXISTS outbox (
              id BIGSERIAL PRIMARY KEY,
              event_id TEXT NOT NULL UNIQUE,
              topic TEXT NOT NULL,
              partition_key TEXT NOT NULL,
              payload JSONB NOT NULL,
              occurred_at BIGINT NOT NULL,
              published_at BIGINT
            )""",
            "CREATE INDEX IF NOT EXISTS outbox_unpublished_idx ON outbox(id) WHERE published_at IS NULL",
            """
            CREATE TABLE IF NOT EXISTS inbox (
              event_id TEXT PRIMARY KEY,
              topic TEXT NOT NULL,
              processed_at BIGINT NOT NULL
            )""",
            """
            CREATE TABLE IF NOT EXISTS cmd_idempotency (
              idem_key TEXT NOT NULL,
              endpoint TEXT NOT NULL,
              request_hash TEXT NOT NULL,
              response_status INT NOT NULL,
              response_body JSONB NOT NULL,
              created_at BIGINT NOT NULL,
              PRIMARY KEY (idem_key, endpoint)
            )"""
        )),
        new Migration(2, "saga 4: trade_refs party projection (TradeOrderCreated -> MarginPosted escrow)", List.of(
            """
            CREATE TABLE IF NOT EXISTS trade_refs (
              trd TEXT PRIMARY KEY,
              buyer_did TEXT NOT NULL,
              seller_did TEXT NOT NULL,
              created_at BIGINT NOT NULL
            )"""
        )),
        new Migration(3, "PL-02 DLQ quarantine — per-key park-and-freeze for poison money events (F-2b/F-2c)", List.of(
            """
            CREATE TABLE IF NOT EXISTS dlq (
              id            BIGSERIAL PRIMARY KEY,
              event_id      TEXT        NOT NULL,
              topic         TEXT        NOT NULL,
              key           TEXT        NOT NULL,
              payload       JSONB       NOT NULL,
              error         TEXT        NOT NULL,
              aggregate_key TEXT        NOT NULL,
              parked_at     TIMESTAMPTZ NOT NULL DEFAULT now()
            )""",
            "CREATE INDEX IF NOT EXISTS dlq_aggregate_key_idx ON dlq (aggregate_key)"
        )),
        new Migration(4, "F-7: ledger effectively-once — dedup a re-append on the canon idempotency key", List.of(
            """
            CREATE TABLE IF NOT EXISTS ledger_idempotency (
              idempotency_key TEXT PRIMARY KEY,
              txn_id          TEXT   NOT NULL,
              created_at      BIGINT NOT NULL
            )"""
        ))
    );
}
