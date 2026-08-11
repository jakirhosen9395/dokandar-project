package com.dokandar.b2b.domain;

/** Canonical prefixed IDs minted or validated by B2B (Domain-Model ID conventions, UUID v7 bodies). */
public final class TradeIds {
    public static final String DID_PREFIX = "did:dokandar:";

    private TradeIds() {}

    public static String newTrd() { return "TRD-" + Uuid7.generate(); }
    public static String newEventId() { return Uuid7.generate(); }

    public static boolean isDid(String s) { return s != null && s.startsWith(DID_PREFIX) && s.length() > DID_PREFIX.length(); }
    public static boolean isTrd(String s) { return s != null && s.startsWith("TRD-") && s.length() > 4; }
    public static boolean isGpid(String s) { return s != null && s.startsWith("GP") && s.length() > 3; }
    public static boolean isPpid(String s) { return s != null && s.startsWith("PP-") && s.length() > 3; }
}
