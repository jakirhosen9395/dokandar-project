// HAND-AUTHORED platform primitive (NOT dkdgen-generated).
// PL-02 — transactional outbox + async relay. Canonical SDK standard for the fleet, matching the
// proven per-service references (Go dkd-custody-ledger/internal/outbox/relay.go; Java
// dkd-finance/.../store/OutboxStore.java). EF §21.1 / EF-EVT-6 / SA-CONV-QUARTET.
package com.dokandar.platform;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Transactional outbox: the aggregate state change and the event row commit in ONE local tx
 * (pass the aggregate write's {@link SqlExecutor} to {@link #enqueue}); {@link OutboxRelay} drains
 * unpublished rows asynchronously to the Kafka spine (R6 Published Language).
 */
public final class Outbox {

    private Outbox() {
    }

    static String requireNonBlank(String v, String field) {
        if (v == null || v.isBlank()) {
            throw new IllegalArgumentException("outbox: " + field + " must be non-blank");
        }
        return v;
    }

    /** Canonical outbox DDL — the SDK standard every context provisions (already used by custody). */
    public static final String DDL = """
        CREATE TABLE IF NOT EXISTS outbox (
          id             BIGSERIAL PRIMARY KEY,
          event_id       TEXT        NOT NULL UNIQUE,
          topic          TEXT        NOT NULL,
          key            TEXT        NOT NULL,
          payload        JSONB       NOT NULL,
          occurred_at_ms BIGINT      NOT NULL,
          created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
          published_at   TIMESTAMPTZ NULL
        );
        CREATE INDEX IF NOT EXISTS outbox_unpublished_idx ON outbox (id) WHERE published_at IS NULL;""";

    private static final String INSERT_SQL =
        "INSERT INTO outbox (event_id, topic, key, payload, occurred_at_ms) "
        + "VALUES (?, ?, ?, ?::jsonb, ?) ON CONFLICT (event_id) DO NOTHING";

    /** An event awaiting publication (payload as raw canonical JSON, IDs only — never PII). */
    public record Record(String eventId, String topic, String key, String payload, long occurredAtMs) {
        public Record {
            requireNonBlank(eventId, "eventId");
            requireNonBlank(topic, "topic");
            requireNonBlank(key, "key");
            requireNonBlank(payload, "payload");
        }
    }

    /** A drained outbox row (id needed so the relay can mark it published). */
    public record Row(long id, String eventId, String topic, String key, String payload, long occurredAtMs) {}

    /**
     * Insert the event row in the caller-provided transaction (atomic with the aggregate write).
     * Idempotent: a duplicate {@code eventId} is a no-op via {@code ON CONFLICT (event_id) DO NOTHING}.
     */
    public static void enqueue(SqlExecutor tx, Record rec) {
        tx.execute(INSERT_SQL, rec.eventId(), rec.topic(), rec.key(), rec.payload(), rec.occurredAtMs());
    }

    /** Async publisher loop over the outbox. Stateless — a thin projection of {@link SqlExecutor}. */
    public static final class OutboxRelay {

        /** producer_context header value stamped on every drained event (this service's context id). */
        private final String producerContext;

        public OutboxRelay(String producerContext) {
            this.producerContext = requireNonBlank(producerContext, "producerContext");
        }

        private static final String FETCH_SQL =
            "SELECT id, event_id, topic, key, payload, occurred_at_ms "
            + "FROM outbox WHERE published_at IS NULL ORDER BY id ASC LIMIT ?";

        private static final String MARK_SQL = "UPDATE outbox SET published_at = now() WHERE id = ?";

        private static final int MAX_BATCH = 500;

        /** Drain up to {@code limit} unpublished rows in id order (clamped to [1, 500]). */
        public List<Row> fetchUnpublished(SqlExecutor db, int limit) {
            int n = Math.max(1, Math.min(limit, MAX_BATCH));
            List<Map<String, Object>> rows = db.execute(FETCH_SQL, n);
            List<Row> out = new ArrayList<>(rows.size());
            for (Map<String, Object> r : rows) {
                out.add(new Row(
                    ((Number) r.get("id")).longValue(),
                    (String) r.get("event_id"),
                    (String) r.get("topic"),
                    (String) r.get("key"),
                    String.valueOf(r.get("payload")),
                    ((Number) r.get("occurred_at_ms")).longValue()));
            }
            return out;
        }

        /** Mark rows published after the broker ack (one UPDATE per id — driver-agnostic). */
        public void markPublished(SqlExecutor db, List<Long> ids) {
            for (Long id : ids) {
                db.execute(MARK_SQL, id);
            }
        }

        /**
         * Spine headers the relay injects on publish: {@code event_id} + {@code producer_context}
         * always, plus a W3C {@code traceparent} when the caller has a context in scope (PL-05).
         * The string is parsed through {@link Trace}, so a malformed/blank/null value is OMITTED
         * rather than propagated (stub-safe: no fabricated or corrupt trace on the wire).
         */
        public Map<String, String> headers(Row row, String traceparent) {
            return headers(row, Trace.parse(traceparent).orElse(null));
        }

        /**
         * Spine headers with a parsed {@link Trace.TraceContext} — the EF-OBS-7 outbox injection
         * point. {@code event_id} + {@code producer_context} always; {@code traceparent} injected
         * (via {@link Trace#inject}) only when {@code ctx} is non-null.
         */
        public Map<String, String> headers(Row row, Trace.TraceContext ctx) {
            Map<String, String> h = new LinkedHashMap<>();
            h.put("event_id", row.eventId());
            h.put("producer_context", producerContext);
            if (ctx != null) {
                Trace.inject(h, ctx);
            }
            return h;
        }
    }
}
