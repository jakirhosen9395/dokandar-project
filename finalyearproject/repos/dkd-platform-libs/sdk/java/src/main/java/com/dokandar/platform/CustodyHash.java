// HAND-AUTHORED platform primitive (NOT dkdgen-generated).
// CustodyHash Specification v2 — DM §2 (RFC-8785 subset R1-R9). One of five byte-identical
// runtime implementations; the shared gate is sdk/testvectors/custodyhash_vectors.json (PL-01).
// Ported verbatim from the proven Python/Go reference serializers.
package com.dokandar.platform;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Deterministic canonical-JSON serializer + SHA-256 event-hash for the custody chain.
 *
 * <p>All five runtimes (Go/Java/C#/Python/Node-TS) MUST produce byte-identical {@link #canonical}
 * output and identical {@link #eventHash} digests for every vector in the shared test-vector
 * fixture. Money/int64 fields are {@code long}; keys are sorted by UTF-8 byte value (never
 * {@code String.compareTo}, which orders by UTF-16 code units).
 */
public final class CustodyHash {

    private CustodyHash() {
    }

    /** Serialize {@code value} per CustodyHash Spec v2 rules R1-R9 (see DM §2). */
    public static String canonical(Object value) {
        StringBuilder sb = new StringBuilder();
        write(sb, value);
        return sb.toString();
    }

    private static void write(StringBuilder sb, Object v) {
        if (v == null) {
            throw new IllegalArgumentException(
                "custody: null forbidden outside omitted object members (R2)");
        }
        // R7 booleans — checked before integers.
        if (v instanceof Boolean b) {
            sb.append(b ? "true" : "false");
            return;
        }
        if (v instanceof Map<?, ?> m) {
            // R2 omit null members; R3 sort keys ascending by UTF-8 byte value at every depth.
            List<String> keys = new ArrayList<>();
            for (Map.Entry<?, ?> e : m.entrySet()) {
                if (e.getValue() != null) {
                    keys.add((String) e.getKey());
                }
            }
            keys.sort(CustodyHash::compareUtf8);
            sb.append('{'); // R4 no whitespace
            boolean first = true;
            for (String k : keys) {
                if (!first) {
                    sb.append(',');
                }
                first = false;
                encString(sb, k);
                sb.append(':');
                write(sb, m.get(k));
            }
            sb.append('}');
            return;
        }
        if (v instanceof List<?> list) {
            sb.append('['); // R8 declaration order, never sorted
            boolean first = true;
            for (Object el : list) {
                if (!first) {
                    sb.append(',');
                }
                first = false;
                write(sb, el); // R9 recurse
            }
            sb.append(']');
            return;
        }
        if (v instanceof String s) {
            encString(sb, s);
            return;
        }
        // R6 integers as plain decimal (int64 and other integral primitives).
        if (v instanceof Long || v instanceof Integer || v instanceof Short
                || v instanceof Byte || v instanceof BigInteger) {
            sb.append(v.toString());
            return;
        }
        if (v instanceof Double || v instanceof Float || v instanceof BigDecimal) {
            // Payloads are built natively with long; floats appear only after a JSON round-trip.
            // Integral floats re-encode as R6 integers; anything else has no canonical encoding.
            double d = ((Number) v).doubleValue();
            if (!Double.isNaN(d) && !Double.isInfinite(d)
                    && d == Math.rint(d) && Math.abs(d) <= 9007199254740992.0) {
                sb.append(Long.toString((long) d));
                return;
            }
            throw new IllegalArgumentException(
                "custody: non-integral number " + v + " has no canonical encoding (R6)");
        }
        throw new IllegalArgumentException(
            "custody: type " + v.getClass().getName() + " has no canonical encoding");
    }

    /**
     * R5 — UTF-8, no HTML escaping, no {@code \\uXXXX} for code points >= U+0080; only the
     * mandatory escapes (quote, backslash, \\b \\t \\n \\f \\r, and \\u00xx for other controls).
     */
    private static void encString(StringBuilder sb, String s) {
        sb.append('"');
        int len = s.length();
        for (int i = 0; i < len; i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"' -> sb.append("\\\"");
                case '\\' -> sb.append("\\\\");
                case '\b' -> sb.append("\\b");
                case '\t' -> sb.append("\\t");
                case '\n' -> sb.append("\\n");
                case '\f' -> sb.append("\\f");
                case '\r' -> sb.append("\\r");
                default -> {
                    if (c < 0x20) {
                        sb.append(String.format("\\u%04x", (int) c));
                    } else {
                        // Literal UTF-16 unit; surrogate pairs recombine and encode correctly
                        // when the finished String is written out as UTF-8 (incl. <, >, &, Bangla,
                        // emoji). No \\uXXXX for >= U+0080.
                        sb.append(c);
                    }
                }
            }
        }
        sb.append('"');
    }

    /** Compare two keys by unsigned UTF-8 byte value (NOT String.compareTo / UTF-16). */
    private static int compareUtf8(String a, String b) {
        byte[] ab = a.getBytes(StandardCharsets.UTF_8);
        byte[] bb = b.getBytes(StandardCharsets.UTF_8);
        int n = Math.min(ab.length, bb.length);
        for (int i = 0; i < n; i++) {
            int x = ab[i] & 0xff;
            int y = bb[i] & 0xff;
            if (x != y) {
                return x - y;
            }
        }
        return ab.length - bb.length;
    }

    /**
     * lowercase-hex SHA-256 over {@code canonical(fields)} with {@code eventHash} unconditionally
     * excluded (it is the output). {@code previousHash}, when the event type carries one, must
     * already be present in {@code fields} — including the genesis empty string {@code ""}.
     */
    public static String eventHash(Map<String, ?> fields) {
        LinkedHashMap<String, Object> canon = new LinkedHashMap<>();
        for (Map.Entry<String, ?> e : fields.entrySet()) {
            if (!"eventHash".equals(e.getKey())) {
                canon.put(e.getKey(), e.getValue());
            }
        }
        byte[] bytes = canonical(canon).getBytes(StandardCharsets.UTF_8);
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(bytes);
            StringBuilder hex = new StringBuilder(64);
            for (byte b : digest) {
                hex.append(Character.forDigit((b >> 4) & 0xf, 16));
                hex.append(Character.forDigit(b & 0xf, 16));
            }
            return hex.toString();
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 unavailable", e);
        }
    }

    /** Recompute the hash of a stored payload (with eventHash present) and report a match. */
    public static boolean verifyEvent(Map<String, ?> fields) {
        Object recorded = fields.get("eventHash");
        if (!(recorded instanceof String s) || s.isEmpty()) {
            throw new IllegalArgumentException("custody: event has no recorded eventHash");
        }
        return eventHash(fields).equals(s);
    }
}
