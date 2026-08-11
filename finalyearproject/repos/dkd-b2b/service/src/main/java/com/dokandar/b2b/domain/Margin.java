package com.dokandar.b2b.domain;

/**
 * MarginDomainService (Domain-Model ctx #7): marginRequirementPoisha is computed
 * synchronously at CreateTradeOrder from local rate tables — no external calls.
 * The canon defines the STRUCTURE but no rate VALUES anywhere (NEEDS-INFO, P2);
 * the rate is therefore policy data injected via DKD_B2B_MARGIN_RATE_BPS. The dev
 * default 1000 bps (10%) is the floor of the only adjacent canon range, the
 * FR-MKT-052 forward-advance band of 10-30%. Integer poisha math only.
 */
public final class Margin {
    public static final int BPS_DENOMINATOR = 10_000;

    private Margin() {}

    /**
     * Floor division, overflow-safe: split into quotient and remainder parts so
     * totalAmountPoisha * rateBps never has to fit in a long.
     */
    public static long requirementPoisha(long totalAmountPoisha, int rateBps) {
        if (totalAmountPoisha <= 0) throw new IllegalArgumentException("totalAmountPoisha must be > 0");
        if (rateBps < 0 || rateBps > BPS_DENOMINATOR)
            throw new IllegalArgumentException("marginRateBps must be within [0, 10000]");
        return (totalAmountPoisha / BPS_DENOMINATOR) * rateBps
            + (totalAmountPoisha % BPS_DENOMINATOR) * rateBps / BPS_DENOMINATOR;
    }
}
