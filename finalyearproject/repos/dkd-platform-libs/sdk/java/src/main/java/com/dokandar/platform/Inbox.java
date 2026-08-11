// HAND-AUTHORED platform primitive (NOT dkdgen-generated).
// PL-02 — consumer inbox dedup on (consumer, event_id) for effectively-once delivery
// (EF §21.1 / EF-EVT-6 / SA-CONV-QUARTET). Matches the per-service references
// (Java dkd-finance/.../store/InboxStore.java; Go/Python/TS/C# equivalents).
package com.dokandar.platform;

import java.util.List;
import java.util.Map;

/**
 * Consumer inbox: dedup a delivered event in the SAME transaction as its side effect. Call
 * {@link #alreadyProcessed} and, when false, do the side effect + {@link #markProcessed} atomically
 * on the caller-supplied {@link SqlExecutor}. Keyed by {@code (consumer, event_id)} so the same fact
 * fanned out to N consumers is deduped independently per consumer.
 */
public final class Inbox {

    private Inbox() {
    }

    /** Canonical inbox DDL — the SDK standard every consuming context provisions. */
    public static final String DDL = """
        CREATE TABLE IF NOT EXISTS inbox (
          consumer     TEXT        NOT NULL,
          event_id     TEXT        NOT NULL,
          processed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
          PRIMARY KEY (consumer, event_id)
        );""";

    private static final String SELECT_SQL =
        "SELECT 1 FROM inbox WHERE consumer = ? AND event_id = ?";

    private static final String INSERT_SQL =
        "INSERT INTO inbox (consumer, event_id, processed_at) VALUES (?, ?, now()) "
        + "ON CONFLICT (consumer, event_id) DO NOTHING";

    /** True when {@code (consumer, eventId)} has already been processed (skip the side effect). */
    public static boolean alreadyProcessed(SqlExecutor tx, String consumer, String eventId) {
        require(consumer, eventId);
        List<Map<String, Object>> rows = tx.execute(SELECT_SQL, consumer, eventId);
        return !rows.isEmpty();
    }

    /**
     * Record {@code (consumer, eventId)} as processed in the caller's tx. Idempotent via
     * {@code ON CONFLICT DO NOTHING}, so a redelivery racing the same key is harmless.
     */
    public static void markProcessed(SqlExecutor tx, String consumer, String eventId) {
        require(consumer, eventId);
        tx.execute(INSERT_SQL, consumer, eventId);
    }

    private static void require(String consumer, String eventId) {
        if (consumer == null || consumer.isBlank()) {
            throw new IllegalArgumentException("inbox: consumer must be non-blank");
        }
        if (eventId == null || eventId.isBlank()) {
            throw new IllegalArgumentException("inbox: eventId must be non-blank");
        }
    }
}
