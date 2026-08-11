package com.dokandar.finance.domain;

import java.security.SecureRandom;

/** UUID v7 (RFC 9562): 48-bit unix-ms timestamp + version/variant bits + 74 random bits. */
public final class Uuid7 {
    private static final SecureRandom RANDOM = new SecureRandom();
    private static final char[] HEX = "0123456789abcdef".toCharArray();

    private Uuid7() {}

    public static String generate() {
        return generate(System.currentTimeMillis());
    }

    static String generate(long unixMs) {
        byte[] b = new byte[16];
        RANDOM.nextBytes(b);
        b[0] = (byte) (unixMs >>> 40);
        b[1] = (byte) (unixMs >>> 32);
        b[2] = (byte) (unixMs >>> 24);
        b[3] = (byte) (unixMs >>> 16);
        b[4] = (byte) (unixMs >>> 8);
        b[5] = (byte) unixMs;
        b[6] = (byte) ((b[6] & 0x0f) | 0x70); // version 7
        b[8] = (byte) ((b[8] & 0x3f) | 0x80); // variant 10
        StringBuilder sb = new StringBuilder(36);
        for (int i = 0; i < 16; i++) {
            if (i == 4 || i == 6 || i == 8 || i == 10) sb.append('-');
            sb.append(HEX[(b[i] >> 4) & 0xf]).append(HEX[b[i] & 0xf]);
        }
        return sb.toString();
    }
}
