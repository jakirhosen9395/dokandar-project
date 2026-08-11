package com.dokandar.b2b.db;

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
 * Code-first migrations under pg_advisory_lock(842007) — fleet pattern (custody 842003,
 * inventory 842005, b2c 842006, finance 842008, logistics 842009). Applied versions are
 * skipped; each version runs in one transaction. Runs in @PostConstruct so it completes
 * before Kafka listeners (SmartLifecycle) start.
 */
@Component
public class MigrationRunner {
    private static final Logger log = LoggerFactory.getLogger(MigrationRunner.class);
    private static final long ADVISORY_LOCK_KEY = 842007L;

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
        new Migration(1, "b2b core: trade_orders, party_eligibility, outbox/inbox/idempotency", List.of(
            """
            CREATE TABLE IF NOT EXISTS trade_orders (
              trd TEXT PRIMARY KEY,
              seller_did TEXT NOT NULL,
              buyer_did TEXT NOT NULL,
              items JSONB NOT NULL,
              contract_terms JSONB NOT NULL,
              total_amount_poisha BIGINT NOT NULL CHECK (total_amount_poisha > 0),
              margin_requirement_poisha BIGINT NOT NULL CHECK (margin_requirement_poisha >= 0),
              margin_posted_poisha BIGINT,
              status TEXT NOT NULL CHECK (status IN
                ('DRAFT','MARGIN_PENDING','MARGIN_POSTED','ACTIVE','SETTLEMENT_PENDING','SETTLED','DISPUTED','CANCELLED')),
              recall_flag BOOLEAN NOT NULL DEFAULT FALSE,
              reason TEXT,
              settlement_ppids JSONB,
              created_at BIGINT NOT NULL,
              updated_at BIGINT NOT NULL
            )""",
            "CREATE INDEX IF NOT EXISTS trade_orders_seller_idx ON trade_orders(seller_did)",
            "CREATE INDEX IF NOT EXISTS trade_orders_buyer_idx ON trade_orders(buyer_did)",
            "CREATE INDEX IF NOT EXISTS trade_orders_status_idx ON trade_orders(status)",
            """
            CREATE TABLE IF NOT EXISTS party_eligibility (
              did TEXT PRIMARY KEY,
              kyc_tier TEXT NOT NULL DEFAULT 'UNVERIFIED',
              suspended BOOLEAN NOT NULL DEFAULT FALSE,
              held BOOLEAN NOT NULL DEFAULT FALSE,
              updated_at BIGINT NOT NULL
            )""",
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
        new Migration(2, "GIN index for recall containment probes on trade_orders.items", List.of(
            "CREATE INDEX IF NOT EXISTS trade_orders_items_gin ON trade_orders USING gin(items)"
        )),
        new Migration(3, "B2B-F7: per-key DLQ sink (bounded-retry poison quarantine)", List.of(
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
        ))
    );
}
