// HAND-AUTHORED platform primitive (NOT dkdgen-generated).
// PL-03 — Idempotency-Key enforcement for unsafe/money/custody writes (EF-API-6 / DM-TYPE-022).
// Enforces the canon: MISSING key -> 400; SAME key + SAME payload -> replay the original
// response; SAME key + DIFFERENT payload -> 409. Backed by a pluggable Store (the PL-02 inbox
// or a dedicated idempotency table) — deliberately NOT hard-wired to any database.
package com.dokandar.platform;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Map;
import java.util.Optional;
import java.util.function.Supplier;

/**
 * Idempotency-Key HTTP helper. {@link #enforce} runs one unsafe/money/custody write exactly once
 * per key: it fingerprints the request body, replays the stored response on an exact-key+payload
 * repeat, rejects a key reused with a different body (409), and rejects a missing key (400). The
 * backing {@link Store} is caller-supplied so the same logic works over the PL-02 inbox, a
 * dedicated table, or an in-memory fake in tests.
 */
public final class Idempotency {

    private Idempotency() {
    }

    /** A captured HTTP response held for replay under an idempotency key. */
    public record CachedResponse(int status, String body, Map<String, String> headers) {
        public CachedResponse {
            headers = headers == null ? Map.of() : Map.copyOf(headers);
        }
    }

    /** A stored entry: the request fingerprint that created it + the response to replay. */
    public record Entry(String requestFingerprint, CachedResponse response) {
        public Entry {
            if (requestFingerprint == null || requestFingerprint.isBlank()) {
                throw new IllegalArgumentException("requestFingerprint must be non-blank");
            }
            if (response == null) {
                throw new IllegalArgumentException("response must be non-null");
            }
        }
    }

    /**
     * Pluggable key store. Implementations back this with the PL-02 inbox or an idempotency table;
     * {@link #putIfAbsent} is first-writer-wins so a concurrent duplicate cannot overwrite.
     */
    public interface Store {
        /** The entry previously stored under {@code key}, if any. */
        Optional<Entry> find(String key);

        /**
         * Persist {@code entry} under {@code key} only if absent; returns the entry now stored
         * (the caller's on a win, or the pre-existing one on a race).
         */
        Entry putIfAbsent(String key, Entry entry);
    }

    /**
     * Enforce EF-API-6 for a single write.
     *
     * @param store   the backing key store (never null)
     * @param key     the {@code Idempotency-Key} header value — null/blank yields 400
     * @param body    the raw request body, fingerprinted for same-key/same-payload detection
     * @param handler computes the response the first time a key is seen
     * @return the fresh response (first use) or the replayed original (exact repeat)
     * @throws MissingKeyException  (400) when {@code key} is null/blank
     * @throws KeyConflictException (409) when {@code key} was used with a different body
     */
    public static CachedResponse enforce(Store store, String key, String body, Supplier<CachedResponse> handler) {
        if (store == null) {
            throw new IllegalArgumentException("store must be non-null");
        }
        if (handler == null) {
            throw new IllegalArgumentException("handler must be non-null");
        }
        if (key == null || key.isBlank()) {
            throw new MissingKeyException();
        }
        String fingerprint = fingerprint(body);

        Optional<Entry> existing = store.find(key);
        if (existing.isPresent()) {
            return replayOrConflict(key, fingerprint, existing.get());
        }

        CachedResponse response = handler.get();
        // First-writer-wins: a racing duplicate that landed first is honoured (replay/conflict).
        Entry stored = store.putIfAbsent(key, new Entry(fingerprint, response));
        return replayOrConflict(key, fingerprint, stored);
    }

    private static CachedResponse replayOrConflict(String key, String fingerprint, Entry stored) {
        if (!stored.requestFingerprint().equals(fingerprint)) {
            throw new KeyConflictException(key);
        }
        return stored.response();
    }

    /** Lowercase-hex SHA-256 of the exact request body (null body treated as empty). */
    public static String fingerprint(String body) {
        byte[] bytes = (body == null ? "" : body).getBytes(StandardCharsets.UTF_8);
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(bytes);
            StringBuilder sb = new StringBuilder(64);
            for (byte b : digest) {
                sb.append(Character.forDigit((b >> 4) & 0xf, 16)).append(Character.forDigit(b & 0xf, 16));
            }
            return sb.toString();
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 unavailable", e); // JRE guarantees SHA-256
        }
    }

    /** 400 — an unsafe/money/custody write arrived with no {@code Idempotency-Key} header. */
    public static final class MissingKeyException extends Errors.DokandarException {
        public MissingKeyException() {
            super("dokandar.platform.idempotency.key_required",
                "Idempotency-Key header is required on unsafe/money/custody writes", 400, null);
        }
    }

    /** 409 — the same {@code Idempotency-Key} was replayed with a different request body. */
    public static final class KeyConflictException extends Errors.DokandarException {
        public KeyConflictException(String key) {
            super("dokandar.platform.idempotency.key_reused",
                "Idempotency-Key '" + key + "' was already used with a different request payload", 409, null);
        }
    }
}
