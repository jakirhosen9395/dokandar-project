package com.dokandar.finance.domain;

/** Canonical prefixed IDs owned or minted by Finance (Domain-Model ID conventions, UUID v7 bodies). */
public final class FinanceIds {
    public static final String DID_PREFIX = "did:dokandar:";

    private FinanceIds() {}

    public static String newWlt() { return "WLT-" + Uuid7.generate(); }
    public static String newTxn() { return "TXN-" + Uuid7.generate(); }
    public static String newEsc() { return "ESC-" + Uuid7.generate(); }
    public static String newMfs() { return "MFS-" + Uuid7.generate(); }
    public static String newEventId() { return Uuid7.generate(); }

    public static boolean isDid(String s) { return s != null && s.startsWith(DID_PREFIX) && s.length() > DID_PREFIX.length(); }
    public static boolean isWlt(String s) { return s != null && s.startsWith("WLT-") && s.length() > 4; }
    public static boolean isEsc(String s) { return s != null && s.startsWith("ESC-") && s.length() > 4; }
}
