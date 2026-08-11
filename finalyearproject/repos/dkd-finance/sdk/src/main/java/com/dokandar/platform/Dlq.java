// HAND-AUTHORED platform primitive (NOT dkdgen-generated).
// PL-02 — dead-letter quarantine with per-aggregate-key "park-and-freeze" (SA-MSG-09/10).
// A poison money/custody/inventory event parks ONLY its own aggregate key: that key freezes
// while every other key on the topic keeps progressing. Poison events are never silently dropped.
package com.dokandar.platform;

import java.util.List;
import java.util.Map;

/**
 * Dead-letter queue + park-and-freeze gate. When an event repeatedly fails, {@link #park} records it
 * (never drops it) and freezes its {@code aggregateKey}; the consumer calls {@link #isKeyParked}
 * before processing so it skips any further event on a frozen key while other keys flow (SA-MSG-10).
 * Replay/unpark is an operational four-eyes action outside this helper.
 */
public final class Dlq {

    private Dlq() {
    }

    /** Canonical DLQ DDL — the SDK standard for the quarantine sink. */
    public static final String DDL = """
        CREATE TABLE IF NOT EXISTS dlq (
          id            BIGSERIAL PRIMARY KEY,
          event_id      TEXT        NOT NULL,
          topic         TEXT        NOT NULL,
          key           TEXT        NOT NULL,
          payload       JSONB       NOT NULL,
          error         TEXT        NOT NULL,
          aggregate_key TEXT        NOT NULL,
          parked_at     TIMESTAMPTZ NOT NULL DEFAULT now()
        );
        CREATE INDEX IF NOT EXISTS dlq_aggregate_key_idx ON dlq (aggregate_key);""";

    private static final String INSERT_SQL =
        "INSERT INTO dlq (event_id, topic, key, payload, error, aggregate_key, parked_at) "
        + "VALUES (?, ?, ?, ?::jsonb, ?, ?, now())";

    private static final String IS_PARKED_SQL =
        "SELECT 1 FROM dlq WHERE aggregate_key = ? LIMIT 1";

    /** A poison event being quarantined (freezes {@code aggregateKey}). */
    public record Record(String eventId, String topic, String key, String payload,
                         String error, String aggregateKey) {
        public Record {
            req(eventId, "eventId");
            req(topic, "topic");
            req(key, "key");
            req(payload, "payload");
            req(aggregateKey, "aggregateKey");
        }
    }

    /** Quarantine {@code rec} and freeze its aggregate key. Idempotent replay is safe (append-only). */
    public static void park(SqlExecutor db, Record rec) {
        db.execute(INSERT_SQL, rec.eventId(), rec.topic(), rec.key(),
            rec.payload(), rec.error(), rec.aggregateKey());
    }

    /** True when {@code aggregateKey} has a parked poison event (skip further events on that key). */
    public static boolean isKeyParked(SqlExecutor db, String aggregateKey) {
        req(aggregateKey, "aggregateKey");
        List<Map<String, Object>> rows = db.execute(IS_PARKED_SQL, aggregateKey);
        return !rows.isEmpty();
    }

    private static void req(String v, String field) {
        if (v == null || v.isBlank()) {
            throw new IllegalArgumentException("dlq: " + field + " must be non-blank");
        }
    }
}
