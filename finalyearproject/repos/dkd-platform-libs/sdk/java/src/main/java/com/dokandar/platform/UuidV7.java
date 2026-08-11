// HAND-AUTHORED platform primitive (NOT dkdgen-generated).
// PL-04 — UUID v7 generator + strict validation. DM-TYPE-003: IDs are time-ordered UUID v7
// (NOT v4); contracts/ids.yaml GPID body = {categoryCode}-{uuid7}. The generated
// Ids.PrefixedId helpers validate prefix + non-empty body ONLY; this primitive adds the
// missing v7 GENERATOR and the version/variant-nibble CHECK, plus prefixed-ID helpers that
// validate the embedded body is a well-formed UUID v7 (so a v4 / garbage body is rejected).
package com.dokandar.platform;

import java.security.SecureRandom;
import java.util.regex.Pattern;

/**
 * Time-ordered UUID v7 (RFC-9562): a 48-bit big-endian unix-millisecond timestamp in the high
 * bits, version nibble {@code 7}, and the RFC-4122 {@code 10xx} variant. Provides a generator
 * and a strict validator, plus prefixed-ID helpers ({@code did:dokandar:}, {@code PP-}, {@code
 * ORD-}, …) that enforce the embedded body is a valid v7 — and a dedicated GPID helper for the
 * {@code {categoryCode}-{uuid7}} body shape.
 */
public final class UuidV7 {

    private UuidV7() {
    }

    private static final SecureRandom RNG = new SecureRandom();
    private static final char[] HEX = "0123456789abcdef".toCharArray();

    // 8-4-4-4-12 canonical lowercase hex; version nibble MUST be 7; variant MUST be RFC-4122 (8..b).
    private static final Pattern V7 = Pattern.compile(
        "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$");

    /** Generate a new UUID v7 stamped with the current wall-clock unix-ms. */
    public static String generate() {
        return generateAt(System.currentTimeMillis());
    }

    /** Generate a UUID v7 whose high 48 bits carry {@code unixMs}; the remaining bits are random. */
    public static String generateAt(long unixMs) {
        if (unixMs < 0) {
            throw new IllegalArgumentException("unixMs must be non-negative");
        }
        byte[] b = new byte[16];
        RNG.nextBytes(b);
        // 48-bit big-endian millisecond timestamp (bytes 0..5).
        b[0] = (byte) (unixMs >>> 40);
        b[1] = (byte) (unixMs >>> 32);
        b[2] = (byte) (unixMs >>> 24);
        b[3] = (byte) (unixMs >>> 16);
        b[4] = (byte) (unixMs >>> 8);
        b[5] = (byte) unixMs;
        b[6] = (byte) ((b[6] & 0x0f) | 0x70); // version 7 in the high nibble of byte 6
        b[8] = (byte) ((b[8] & 0x3f) | 0x80); // variant 10xx in the two high bits of byte 8
        return format(b);
    }

    /**
     * True when {@code s} is a canonical lowercase-hex UUID whose version nibble is 7 and whose
     * variant is RFC-4122. A v4 UUID, an upper-case body, or any non-UUID string returns false.
     */
    public static boolean isValidV7(String s) {
        return s != null && V7.matcher(s).matches();
    }

    /** Extract the 48-bit unix-ms timestamp encoded in a v7 UUID (throws if {@code v7} is not valid). */
    public static long timestampMs(String v7) {
        if (!isValidV7(v7)) {
            throw new IllegalArgumentException("not a UUID v7: " + v7);
        }
        // first 12 hex chars (skip the dash at index 8) = the 48-bit timestamp.
        String hex = v7.substring(0, 8) + v7.substring(9, 13);
        return Long.parseLong(hex, 16);
    }

    // ---- prefixed-ID helpers (did:/PP-/ORD-/WLT-/…): body is exactly one UUID v7 -------------

    /** Generate a prefixed ID whose body is a fresh UUID v7 (e.g. {@code newPrefixed("PP-")}). */
    public static String newPrefixed(String prefix) {
        requirePrefix(prefix);
        return prefix + generate();
    }

    /** True when {@code value} starts with {@code prefix} and the remaining body is a valid UUID v7. */
    public static boolean isValidPrefixed(String value, String prefix) {
        requirePrefix(prefix);
        if (value == null || !value.startsWith(prefix)) {
            return false;
        }
        return isValidV7(value.substring(prefix.length()));
    }

    /** Validate {@code value} is {@code prefix} + a UUID v7 body; returns it, else throws. */
    public static String validatePrefixed(String value, String prefix) {
        if (!isValidPrefixed(value, prefix)) {
            throw new IllegalArgumentException("id must be '" + prefix + "' followed by a UUID v7 body: " + value);
        }
        return value;
    }

    // ---- GPID helper: body is {categoryCode}-{uuid7} (contracts/ids.yaml) ----------------------

    /** {@code categoryCode} in a GPID body: lowercase alphanumerics (e.g. {@code rice}, {@code steel}). */
    private static final Pattern GPID_CATEGORY = Pattern.compile("^[a-z0-9]+$");
    private static final String GPID_PREFIX = "GP-";

    /** Generate a GPID {@code GP-{categoryCode}-{uuid7}} for a lowercase-alphanumeric category. */
    public static String newGpid(String categoryCode) {
        if (categoryCode == null || !GPID_CATEGORY.matcher(categoryCode).matches()) {
            throw new IllegalArgumentException("GPID categoryCode must be lowercase alphanumeric: " + categoryCode);
        }
        return GPID_PREFIX + categoryCode + "-" + generate();
    }

    /** Length of a canonical UUID string ({@code 8-4-4-4-12}). */
    private static final int UUID_LEN = 36;

    /** True when {@code value} is {@code GP-{categoryCode}-{uuid7}} with a valid category + v7 suffix. */
    public static boolean isValidGpid(String value) {
        if (value == null || !value.startsWith(GPID_PREFIX)) {
            return false;
        }
        String body = value.substring(GPID_PREFIX.length());
        // the UUID (which itself contains dashes) is always the trailing 36 chars, preceded by '-'.
        int cut = body.length() - UUID_LEN - 1;
        if (cut <= 0 || body.charAt(cut) != '-') {
            return false;
        }
        String category = body.substring(0, cut);
        String uuid = body.substring(cut + 1);
        return GPID_CATEGORY.matcher(category).matches() && isValidV7(uuid);
    }

    private static void requirePrefix(String prefix) {
        if (prefix == null || prefix.isEmpty()) {
            throw new IllegalArgumentException("prefix must be non-empty");
        }
    }

    private static String format(byte[] b) {
        StringBuilder sb = new StringBuilder(36);
        for (int i = 0; i < 16; i++) {
            if (i == 4 || i == 6 || i == 8 || i == 10) {
                sb.append('-');
            }
            int v = b[i] & 0xff;
            sb.append(HEX[v >>> 4]).append(HEX[v & 0x0f]);
        }
        return sb.toString();
    }
}
