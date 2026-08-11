// HAND-AUTHORED test (NOT dkdgen-generated).
// PL-02 conformance: proves the outbox/inbox/DLQ helpers against an IN-MEMORY fake SqlExecutor
// (no live DB) — the same behavioural contract every runtime must satisfy.
package com.dokandar.platform;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class OutboxInboxDlqTest {

    /**
     * In-memory {@link SqlExecutor} that (a) records every SQL + params issued and (b) models just
     * enough table semantics — UNIQUE / PK ON CONFLICT DO NOTHING, published_at, aggregate_key — to
     * prove effectively-once behaviour without a real database.
     */
    static final class FakeDb implements SqlExecutor {
        final List<String> sqlLog = new ArrayList<>();
        final List<Object[]> paramLog = new ArrayList<>();

        // outbox rows keyed by generated id; event_id is UNIQUE.
        final Map<Long, Map<String, Object>> outbox = new LinkedHashMap<>();
        final List<String> outboxEventIds = new ArrayList<>();
        long seq = 0;

        // inbox PK (consumer|event_id).
        final java.util.Set<String> inbox = new java.util.HashSet<>();

        // dlq rows, plus the set of frozen aggregate keys.
        final List<Map<String, Object>> dlq = new ArrayList<>();

        @Override
        public List<Map<String, Object>> execute(String sql, Object... params) {
            sqlLog.add(sql);
            paramLog.add(params);
            String s = sql.trim();

            if (s.startsWith("INSERT INTO outbox")) {
                String eventId = (String) params[0];
                if (!outboxEventIds.contains(eventId)) { // ON CONFLICT (event_id) DO NOTHING
                    long id = ++seq;
                    Map<String, Object> row = new LinkedHashMap<>();
                    row.put("id", id);
                    row.put("event_id", eventId);
                    row.put("topic", params[1]);
                    row.put("key", params[2]);
                    row.put("payload", params[3]);
                    row.put("occurred_at_ms", params[4]);
                    row.put("published_at", null);
                    outbox.put(id, row);
                    outboxEventIds.add(eventId);
                }
                return List.of();
            }
            if (s.startsWith("SELECT id, event_id, topic, key, payload, occurred_at_ms")) {
                List<Map<String, Object>> out = new ArrayList<>();
                for (Map<String, Object> row : outbox.values()) {
                    if (row.get("published_at") == null) {
                        out.add(row);
                    }
                }
                return out;
            }
            if (s.startsWith("UPDATE outbox SET published_at")) {
                Long id = ((Number) params[0]).longValue();
                Map<String, Object> row = outbox.get(id);
                if (row != null) {
                    row.put("published_at", "now");
                }
                return List.of();
            }
            if (s.startsWith("INSERT INTO inbox")) {
                inbox.add(params[0] + "|" + params[1]); // set add == ON CONFLICT DO NOTHING
                return List.of();
            }
            if (s.startsWith("SELECT 1 FROM inbox")) {
                return inbox.contains(params[0] + "|" + params[1]) ? oneRow() : List.of();
            }
            if (s.startsWith("INSERT INTO dlq")) {
                Map<String, Object> row = new LinkedHashMap<>();
                row.put("event_id", params[0]);
                row.put("aggregate_key", params[5]);
                dlq.add(row);
                return List.of();
            }
            if (s.startsWith("SELECT 1 FROM dlq")) {
                for (Map<String, Object> row : dlq) {
                    if (row.get("aggregate_key").equals(params[0])) {
                        return oneRow();
                    }
                }
                return List.of();
            }
            throw new IllegalStateException("unexpected sql: " + s);
        }

        private static List<Map<String, Object>> oneRow() {
            return List.of(Map.of("?column?", 1));
        }
    }

    private static Object[] lastParams(FakeDb db) {
        return db.paramLog.get(db.paramLog.size() - 1);
    }

    @Test
    void enqueueIssuesOneInsertWithOnConflictAndCorrectColumns() {
        FakeDb db = new FakeDb();
        Outbox.enqueue(db, new Outbox.Record("evt-1", "custody.passport.CustodyInitialized.v1",
            "PPID-1", "{\"a\":1}", 1719792000000L));

        assertEquals(1, db.sqlLog.size(), "exactly one statement");
        String sql = db.sqlLog.get(0);
        assertTrue(sql.startsWith("INSERT INTO outbox"), sql);
        assertTrue(sql.contains("(event_id, topic, key, payload, occurred_at_ms)"), sql);
        assertTrue(sql.contains("?::jsonb"), "payload cast to jsonb: " + sql);
        assertTrue(sql.contains("ON CONFLICT (event_id) DO NOTHING"), sql);

        Object[] p = lastParams(db);
        assertArrayEquals(
            new Object[]{"evt-1", "custody.passport.CustodyInitialized.v1", "PPID-1", "{\"a\":1}", 1719792000000L},
            p);
        assertEquals(1, db.outbox.size());
    }

    @Test
    void duplicateEventIdIsANoOp() {
        FakeDb db = new FakeDb();
        Outbox.Record rec = new Outbox.Record("evt-dup", "b2c.order.OrderPlaced.v1", "ORD-9", "{}", 1L);
        Outbox.enqueue(db, rec);
        Outbox.enqueue(db, rec); // same event_id

        assertEquals(2, db.sqlLog.size(), "both inserts are issued (DB enforces idempotency)");
        assertEquals(1, db.outbox.size(), "ON CONFLICT keeps a single row");
    }

    @Test
    void relayFetchesUnpublishedMarksPublishedAndInjectsHeaders() {
        FakeDb db = new FakeDb();
        Outbox.enqueue(db, new Outbox.Record("evt-a", "t.x.E.v1", "K1", "{}", 10L));
        Outbox.enqueue(db, new Outbox.Record("evt-b", "t.x.E.v1", "K2", "{}", 20L));

        Outbox.OutboxRelay relay = new Outbox.OutboxRelay("finance");
        List<Outbox.Row> batch = relay.fetchUnpublished(db, 100);
        assertEquals(2, batch.size());

        // headers: event_id + producer_context always; a VALID W3C traceparent is injected (PL-05).
        String tp = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";
        Map<String, String> h = relay.headers(batch.get(0), tp);
        assertEquals("evt-a", h.get("event_id"));
        assertEquals("finance", h.get("producer_context"));
        assertEquals(tp, h.get("traceparent"));
        // stub-safe: no traceparent -> header omitted, never fabricated.
        assertFalse(relay.headers(batch.get(0), (String) null).containsKey("traceparent"));
        assertFalse(relay.headers(batch.get(0), "  ").containsKey("traceparent"));
        // PL-05: a MALFORMED traceparent is rejected (omitted), never propagated to the spine.
        assertFalse(relay.headers(batch.get(0), "00-trace-01").containsKey("traceparent"));
        // a parsed TraceContext overload injects the canonical form.
        Map<String, String> h2 = relay.headers(batch.get(0), Trace.parse(tp).orElseThrow());
        assertEquals(tp, h2.get("traceparent"));

        List<Long> ids = batch.stream().map(Outbox.Row::id).toList();
        relay.markPublished(db, ids);
        assertTrue(relay.fetchUnpublished(db, 100).isEmpty(), "nothing unpublished after mark");
    }

    @Test
    void inboxMarkThenAlreadyProcessedTrueAndScopedByConsumer() {
        FakeDb db = new FakeDb();
        assertFalse(Inbox.alreadyProcessed(db, "inventory", "evt-1"));

        Inbox.markProcessed(db, "inventory", "evt-1");
        assertTrue(Inbox.alreadyProcessed(db, "inventory", "evt-1"));

        // a different consumer dedups independently (same fact fanned out).
        assertFalse(Inbox.alreadyProcessed(db, "provenance", "evt-1"));

        Inbox.markProcessed(db, "inventory", "evt-1"); // redelivery: ON CONFLICT DO NOTHING
        assertTrue(Inbox.alreadyProcessed(db, "inventory", "evt-1"));
    }

    @Test
    void dlqParkRecordsAggregateKeyAndFreezesOnlyThatKey() {
        FakeDb db = new FakeDb();
        assertFalse(Dlq.isKeyParked(db, "WLT-1"));

        Dlq.park(db, new Dlq.Record("evt-poison", "finance.wallet.Debited.v1",
            "WLT-1", "{}", "boom", "WLT-1"));

        assertTrue(Dlq.isKeyParked(db, "WLT-1"), "parked key is frozen");
        assertFalse(Dlq.isKeyParked(db, "WLT-2"), "a different key keeps progressing");

        // aggregate_key was the recorded param (index 5 of the park insert).
        Object[] insertParams = db.paramLog.get(1);
        assertEquals("WLT-1", insertParams[5]);
    }

    @Test
    void recordConstructorsRejectBlankRequiredFields() {
        assertThrows(IllegalArgumentException.class,
            () -> new Outbox.Record("", "t", "k", "{}", 1L));
        assertThrows(IllegalArgumentException.class,
            () -> new Dlq.Record("e", "t", "k", "{}", "err", ""));
        assertThrows(IllegalArgumentException.class,
            () -> Inbox.markProcessed(new FakeDb(), "c", ""));
    }
}
