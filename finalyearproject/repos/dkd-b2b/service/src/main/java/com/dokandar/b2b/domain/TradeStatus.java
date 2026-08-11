package com.dokandar.b2b.domain;

import java.util.Map;
import java.util.Set;

/**
 * TradeOrderStatus state machine (Domain-Model ctx #7, verbatim):
 * NEW -> MARGIN_PENDING -> MARGIN_POSTED -> ACTIVE -> SETTLEMENT_PENDING -> SETTLED.
 * CANCELLED only from DRAFT|MARGIN_PENDING; DISPUTED from ACTIVE|SETTLEMENT_PENDING and
 * has NO auto-exit (exits deferred to a future ADR). DRAFT exists in the enum but no
 * canon transition creates it (NEEDS-INFO, recorded in BUILD-LOG).
 */
public enum TradeStatus {
    DRAFT, MARGIN_PENDING, MARGIN_POSTED, ACTIVE, SETTLEMENT_PENDING, SETTLED, DISPUTED, CANCELLED;

    private static final Map<TradeStatus, Set<TradeStatus>> ALLOWED = Map.of(
        DRAFT, Set.of(CANCELLED),
        MARGIN_PENDING, Set.of(MARGIN_POSTED, CANCELLED),
        MARGIN_POSTED, Set.of(ACTIVE),
        ACTIVE, Set.of(SETTLEMENT_PENDING, DISPUTED),
        SETTLEMENT_PENDING, Set.of(SETTLED, DISPUTED),
        SETTLED, Set.of(),
        DISPUTED, Set.of(),
        CANCELLED, Set.of());

    public boolean canTransition(TradeStatus to) {
        return ALLOWED.get(this).contains(to);
    }

    public boolean isTerminal() {
        return ALLOWED.get(this).isEmpty();
    }
}
