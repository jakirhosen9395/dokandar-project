package com.dokandar.b2b.domain;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import org.junit.jupiter.api.Test;

/** Margin domain service — integer poisha, overflow-safe, floor semantics. */
class MarginTest {

    @Test
    void tenPercentOfRoundTotal() {
        assertEquals(400, Margin.requirementPoisha(4_000, 1_000));
    }

    @Test
    void floorsFractionalPoisha() {
        // 999 * 10% = 99.9 -> 99 (never round a requirement up past the rate)
        assertEquals(99, Margin.requirementPoisha(999, 1_000));
    }

    @Test
    void zeroRateMeansZeroRequirement() {
        assertEquals(0, Margin.requirementPoisha(1_000_000, 0));
    }

    @Test
    void fullRateEqualsTotal() {
        assertEquals(123_456_789L, Margin.requirementPoisha(123_456_789L, 10_000));
    }

    @Test
    void overflowSafeNearLongMax() {
        // quotient/remainder split: (Long.MAX_VALUE / 10000) * 1000 + rem * 1000 / 10000
        long total = Long.MAX_VALUE - 7; // divisible-ish large value
        long expected = (total / 10_000) * 1_000 + (total % 10_000) * 1_000 / 10_000;
        assertEquals(expected, Margin.requirementPoisha(total, 1_000));
    }

    @Test
    void rejectsNonPositiveTotalAndBadRate() {
        assertThrows(IllegalArgumentException.class, () -> Margin.requirementPoisha(0, 1_000));
        assertThrows(IllegalArgumentException.class, () -> Margin.requirementPoisha(-5, 1_000));
        assertThrows(IllegalArgumentException.class, () -> Margin.requirementPoisha(100, -1));
        assertThrows(IllegalArgumentException.class, () -> Margin.requirementPoisha(100, 10_001));
    }
}
