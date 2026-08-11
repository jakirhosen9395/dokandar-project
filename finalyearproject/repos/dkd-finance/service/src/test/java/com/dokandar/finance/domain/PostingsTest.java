package com.dokandar.finance.domain;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.util.List;
import org.junit.jupiter.api.Test;

class PostingsTest {

    private static Postings.Posting leg(String account, String type, long amount) {
        return new Postings.Posting(account, type, amount, "other", "REF-1", "ESCROW", true);
    }

    @Test
    void acceptsBalancedTwoLegSet() {
        Postings p = Postings.balanced(List.of(
            leg("WLT-a", Postings.DEBIT, 4000), leg("WLT-b", Postings.CREDIT, 4000)));
        assertEquals(2, p.legs().size());
    }

    @Test
    void acceptsBalancedMultiLegSet() {
        Postings p = Postings.balanced(List.of(
            leg("WLT-a", Postings.DEBIT, 4000),
            leg("WLT-b", Postings.CREDIT, 2500),
            leg("WLT-c", Postings.CREDIT, 1500)));
        assertEquals(3, p.legs().size());
    }

    @Test
    void rejectsUnbalancedSet() {
        assertThrows(IllegalArgumentException.class, () -> Postings.balanced(List.of(
            leg("WLT-a", Postings.DEBIT, 4000), leg("WLT-b", Postings.CREDIT, 3999))));
    }

    @Test
    void rejectsSingleLeg() {
        assertThrows(IllegalArgumentException.class,
            () -> Postings.balanced(List.of(leg("WLT-a", Postings.DEBIT, 100))));
    }

    @Test
    void rejectsZeroAndNegativeAmounts() {
        assertThrows(IllegalArgumentException.class, () -> Postings.balanced(List.of(
            leg("WLT-a", Postings.DEBIT, 0), leg("WLT-b", Postings.CREDIT, 0))));
        assertThrows(IllegalArgumentException.class, () -> Postings.balanced(List.of(
            leg("WLT-a", Postings.DEBIT, -5), leg("WLT-b", Postings.CREDIT, -5))));
    }

    @Test
    void rejectsUnknownEntryType() {
        assertThrows(IllegalArgumentException.class, () -> Postings.balanced(List.of(
            leg("WLT-a", "TRANSFER", 100), leg("WLT-b", Postings.CREDIT, 100))));
    }

    @Test
    void transferBuildsDebitCreditPair() {
        Postings p = Postings.transfer("WLT-buyer", "ESC-1", 40000, "ESC-1", "ESCROW", false);
        assertEquals(Postings.DEBIT, p.legs().get(0).entryType());
        assertEquals("WLT-buyer", p.legs().get(0).account());
        assertEquals(Postings.CREDIT, p.legs().get(1).entryType());
        assertEquals("ESC-1", p.legs().get(1).account());
        assertEquals(false, p.legs().get(1).isWithdrawable());
    }

    @Test
    void overflowIsRejectedNotWrapped() {
        assertThrows(ArithmeticException.class, () -> Postings.balanced(List.of(
            leg("WLT-a", Postings.DEBIT, Long.MAX_VALUE), leg("WLT-b", Postings.DEBIT, 1),
            leg("WLT-c", Postings.CREDIT, 10))));
    }
}
