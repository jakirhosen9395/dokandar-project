package com.dokandar.finance.domain;

import java.util.Map;
import java.util.Set;

/**
 * Escrow state machine (Domain-Model canon; the Service-Architecture variant is errata).
 * ACTIVE -> SETTLEMENT_HELD (release w/ POD) -> RELEASED (cooling-off elapsed)
 * ACTIVE -> REVERSED | EXPIRED; SETTLEMENT_HELD -> CLAWED_BACK.
 * RELEASED / REVERSED / CLAWED_BACK / EXPIRED are terminal. History is never deleted:
 * every transition that moves money does so via compensating balanced entries (R3).
 */
public enum EscrowStatus {
    ACTIVE, SETTLEMENT_HELD, RELEASED, REVERSED, CLAWED_BACK, EXPIRED;

    private static final Map<EscrowStatus, Set<EscrowStatus>> LEGAL = Map.of(
        ACTIVE, Set.of(SETTLEMENT_HELD, REVERSED, EXPIRED),
        SETTLEMENT_HELD, Set.of(RELEASED, CLAWED_BACK),
        RELEASED, Set.of(),
        REVERSED, Set.of(),
        CLAWED_BACK, Set.of(),
        EXPIRED, Set.of());

    public boolean canTransitionTo(EscrowStatus next) {
        return LEGAL.get(this).contains(next);
    }

    public boolean isTerminal() {
        return LEGAL.get(this).isEmpty();
    }
}
