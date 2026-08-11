package com.dokandar.finance.domain;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

class EscrowStatusTest {

    @Test
    void activeCanReleaseReverseOrExpire() {
        assertTrue(EscrowStatus.ACTIVE.canTransitionTo(EscrowStatus.SETTLEMENT_HELD));
        assertTrue(EscrowStatus.ACTIVE.canTransitionTo(EscrowStatus.REVERSED));
        assertTrue(EscrowStatus.ACTIVE.canTransitionTo(EscrowStatus.EXPIRED));
        assertFalse(EscrowStatus.ACTIVE.canTransitionTo(EscrowStatus.RELEASED));
        assertFalse(EscrowStatus.ACTIVE.canTransitionTo(EscrowStatus.CLAWED_BACK));
    }

    @Test
    void settlementHeldCanReleaseOrClawBack() {
        assertTrue(EscrowStatus.SETTLEMENT_HELD.canTransitionTo(EscrowStatus.RELEASED));
        assertTrue(EscrowStatus.SETTLEMENT_HELD.canTransitionTo(EscrowStatus.CLAWED_BACK));
        assertFalse(EscrowStatus.SETTLEMENT_HELD.canTransitionTo(EscrowStatus.REVERSED));
        assertFalse(EscrowStatus.SETTLEMENT_HELD.canTransitionTo(EscrowStatus.EXPIRED));
        assertFalse(EscrowStatus.SETTLEMENT_HELD.canTransitionTo(EscrowStatus.ACTIVE));
    }

    @Test
    void terminalStatesAllowNothing() {
        for (EscrowStatus terminal : new EscrowStatus[]{EscrowStatus.RELEASED, EscrowStatus.REVERSED,
                EscrowStatus.CLAWED_BACK, EscrowStatus.EXPIRED}) {
            assertTrue(terminal.isTerminal());
            for (EscrowStatus to : EscrowStatus.values())
                assertFalse(terminal.canTransitionTo(to), terminal + " -> " + to + " must be illegal");
        }
    }

    @Test
    void nonTerminalStatesAreNotTerminal() {
        assertFalse(EscrowStatus.ACTIVE.isTerminal());
        assertFalse(EscrowStatus.SETTLEMENT_HELD.isTerminal());
    }
}
