// HAND-AUTHORED test (NOT dkdgen-generated).
// PL-03 conformance: the three EF-API-6 branches against an in-memory fake Store —
// missing key -> 400; same key + same payload -> replay; same key + different payload -> 409.
package com.dokandar.platform;

import java.util.HashMap;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicInteger;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class IdempotencyTest {

    /** In-memory first-writer-wins {@link Idempotency.Store} — no DB, just enough to prove the branches. */
    static final class FakeStore implements Idempotency.Store {
        final Map<String, Idempotency.Entry> map = new HashMap<>();

        @Override
        public Optional<Idempotency.Entry> find(String key) {
            return Optional.ofNullable(map.get(key));
        }

        @Override
        public Idempotency.Entry putIfAbsent(String key, Idempotency.Entry entry) {
            return map.putIfAbsent(key, entry) == null ? entry : map.get(key);
        }
    }

    private static Idempotency.CachedResponse created() {
        return new Idempotency.CachedResponse(201, "{\"id\":\"ORD-1\"}", Map.of("Location", "/v1/orders/ORD-1"));
    }

    @Test
    void missingKeyIsRejectedWith400() {
        FakeStore store = new FakeStore();
        var ex = assertThrows(Idempotency.MissingKeyException.class,
            () -> Idempotency.enforce(store, null, "{\"a\":1}", IdempotencyTest::created));
        assertEquals(400, ex.httpStatus);
        assertThrows(Idempotency.MissingKeyException.class,
            () -> Idempotency.enforce(store, "  ", "{\"a\":1}", IdempotencyTest::created));
    }

    @Test
    void firstUseRunsHandlerThenSameKeySamePayloadReplaysWithoutRerunning() {
        FakeStore store = new FakeStore();
        AtomicInteger runs = new AtomicInteger();

        Idempotency.CachedResponse first = Idempotency.enforce(store, "key-1", "{\"a\":1}", () -> {
            runs.incrementAndGet();
            return created();
        });
        assertEquals(201, first.status());
        assertEquals(1, runs.get());

        // exact repeat: original response replayed, handler NOT re-run.
        Idempotency.CachedResponse replay = Idempotency.enforce(store, "key-1", "{\"a\":1}", () -> {
            runs.incrementAndGet();
            return new Idempotency.CachedResponse(500, "should-not-happen", Map.of());
        });
        assertEquals(201, replay.status());
        assertEquals("{\"id\":\"ORD-1\"}", replay.body());
        assertEquals(1, runs.get(), "handler ran exactly once across the two identical requests");
    }

    @Test
    void sameKeyDifferentPayloadIsRejectedWith409() {
        FakeStore store = new FakeStore();
        Idempotency.enforce(store, "key-1", "{\"a\":1}", IdempotencyTest::created);

        var ex = assertThrows(Idempotency.KeyConflictException.class,
            () -> Idempotency.enforce(store, "key-1", "{\"a\":2}", IdempotencyTest::created));
        assertEquals(409, ex.httpStatus);
    }

    @Test
    void fingerprintIsStableSha256Hex() {
        String fp = Idempotency.fingerprint("{\"a\":1}");
        assertEquals(64, fp.length());
        assertTrue(fp.matches("^[0-9a-f]{64}$"));
        assertEquals(fp, Idempotency.fingerprint("{\"a\":1}"));
        assertNotEquals(fp, Idempotency.fingerprint("{\"a\":2}"));
    }
}
