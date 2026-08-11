package com.dokandar.b2b.domain;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

/** DM ctx #7 TradeOrderStatus machine — every legal edge and the critical illegal ones. */
class TradeStatusTest {

    @Test
    void happyPathEdgesAreLegal() {
        // Arrange / Act / Assert — the canon chain MARGIN_PENDING -> ... -> SETTLED
        assertTrue(TradeStatus.MARGIN_PENDING.canTransition(TradeStatus.MARGIN_POSTED));
        assertTrue(TradeStatus.MARGIN_POSTED.canTransition(TradeStatus.ACTIVE));
        assertTrue(TradeStatus.ACTIVE.canTransition(TradeStatus.SETTLEMENT_PENDING));
        assertTrue(TradeStatus.SETTLEMENT_PENDING.canTransition(TradeStatus.SETTLED));
    }

    @Test
    void cancellationOnlyBeforeMarginPosting() {
        assertTrue(TradeStatus.DRAFT.canTransition(TradeStatus.CANCELLED));
        assertTrue(TradeStatus.MARGIN_PENDING.canTransition(TradeStatus.CANCELLED));
        assertFalse(TradeStatus.MARGIN_POSTED.canTransition(TradeStatus.CANCELLED));
        assertFalse(TradeStatus.ACTIVE.canTransition(TradeStatus.CANCELLED));
        assertFalse(TradeStatus.SETTLEMENT_PENDING.canTransition(TradeStatus.CANCELLED));
    }

    @Test
    void disputesOnlyFromActiveOrSettlementPending() {
        assertTrue(TradeStatus.ACTIVE.canTransition(TradeStatus.DISPUTED));
        assertTrue(TradeStatus.SETTLEMENT_PENDING.canTransition(TradeStatus.DISPUTED));
        assertFalse(TradeStatus.MARGIN_PENDING.canTransition(TradeStatus.DISPUTED));
        assertFalse(TradeStatus.SETTLED.canTransition(TradeStatus.DISPUTED));
    }

    @Test
    void disputedHasNoAutoExit() {
        // DM: DISPUTED is pending-resolution — exits are deferred to a future ADR.
        for (TradeStatus to : TradeStatus.values())
            assertFalse(TradeStatus.DISPUTED.canTransition(to), "DISPUTED must not exit to " + to);
        assertTrue(TradeStatus.DISPUTED.isTerminal());
    }

    @Test
    void settledAndCancelledAreTerminal() {
        assertTrue(TradeStatus.SETTLED.isTerminal());
        assertTrue(TradeStatus.CANCELLED.isTerminal());
        assertFalse(TradeStatus.ACTIVE.isTerminal());
    }

    @Test
    void noSkippingMarginPosting() {
        assertFalse(TradeStatus.MARGIN_PENDING.canTransition(TradeStatus.ACTIVE));
        assertFalse(TradeStatus.MARGIN_PENDING.canTransition(TradeStatus.SETTLEMENT_PENDING));
        assertFalse(TradeStatus.MARGIN_POSTED.canTransition(TradeStatus.SETTLEMENT_PENDING));
    }
}
