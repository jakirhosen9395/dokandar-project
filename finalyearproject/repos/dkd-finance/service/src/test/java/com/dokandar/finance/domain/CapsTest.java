package com.dokandar.finance.domain;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.dokandar.platform.Errors;
import org.junit.jupiter.api.Test;

class CapsTest {

    private static final Caps.TierLimits V0 = new Caps.TierLimits("V0", null, 0L, 500_000L);
    private static final Caps.TierLimits V1 = new Caps.TierLimits("V1", 2_500_000L, 5_000_000L, 50_000_000L);
    private static final Caps.TierLimits V3 = new Caps.TierLimits("V3", null, null, null);

    @Test
    void v0IsReceiveOnly_debitAlwaysRejected() {
        var e = assertThrows(Errors.BusinessException.class, () -> Caps.checkDebit(V0, 1, 0));
        assertTrue(e.code.contains("tier_receive_only"));
    }

    @Test
    void v0CanStillReceiveWithinMaxBalance() {
        assertDoesNotThrow(() -> Caps.checkCredit(V0, 400_000, 0));
        var e = assertThrows(Errors.BusinessException.class, () -> Caps.checkCredit(V0, 400_000, 200_000));
        assertTrue(e.code.contains("max_balance_exceeded"));
    }

    @Test
    void singleTxnCapAppliesToBothDirections() {
        assertThrows(Errors.BusinessException.class, () -> Caps.checkCredit(V1, 2_500_001, 0));
        assertThrows(Errors.BusinessException.class, () -> Caps.checkDebit(V1, 2_500_001, 0));
        assertDoesNotThrow(() -> Caps.checkCredit(V1, 2_500_000, 0));
        assertDoesNotThrow(() -> Caps.checkDebit(V1, 2_500_000, 0));
    }

    @Test
    void dailyOutCapCountsPriorSpend() {
        assertDoesNotThrow(() -> Caps.checkDebit(V1, 1_000_000, 4_000_000));
        var e = assertThrows(Errors.BusinessException.class, () -> Caps.checkDebit(V1, 1_000_001, 4_000_000));
        assertTrue(e.code.contains("daily_out_cap_exceeded"));
    }

    @Test
    void v3IsUnbounded() {
        assertDoesNotThrow(() -> Caps.checkCredit(V3, Long.MAX_VALUE / 2, 0));
        assertDoesNotThrow(() -> Caps.checkDebit(V3, Long.MAX_VALUE / 2, 0));
    }

    @Test
    void nonPositiveAmountsAreValidationErrors() {
        assertThrows(Errors.ValidationException.class, () -> Caps.checkCredit(V1, 0, 0));
        assertThrows(Errors.ValidationException.class, () -> Caps.checkDebit(V1, -100, 0));
    }
}
