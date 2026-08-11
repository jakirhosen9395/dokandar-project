package com.dokandar.finance.domain;

import java.util.List;

/**
 * A balanced double-entry posting set: >= 2 legs, every amount > 0 poisha,
 * sum(DEBIT) == sum(CREDIT). Ledger convention: wallet/suspense accounts are
 * liability-style — CREDIT increases the account balance, DEBIT decreases it.
 * The only way to construct one is {@link #balanced}, so an unbalanced set can
 * never reach the ledger store.
 */
public final class Postings {
    public static final String DEBIT = "DEBIT";
    public static final String CREDIT = "CREDIT";

    /** One ledger leg. account = WLT-*, ESC-* (escrow suspense) or SYS-* (external suspense). */
    public record Posting(String account, String entryType, long amountPoisha, String counterpartAccount,
                          String referenceId, String referenceType, boolean isWithdrawable) {}

    private final List<Posting> legs;

    private Postings(List<Posting> legs) { this.legs = List.copyOf(legs); }

    public static Postings balanced(List<Posting> legs) {
        if (legs == null || legs.size() < 2)
            throw new IllegalArgumentException("a posting set needs at least two legs");
        long debits = 0, credits = 0;
        for (Posting p : legs) {
            if (p.amountPoisha() <= 0)
                throw new IllegalArgumentException("posting amount must be > 0 poisha");
            if (p.account() == null || p.account().isBlank())
                throw new IllegalArgumentException("posting account is required");
            if (p.referenceId() == null || p.referenceType() == null)
                throw new IllegalArgumentException("posting reference is required");
            switch (p.entryType()) {
                case DEBIT -> debits = Math.addExact(debits, p.amountPoisha());
                case CREDIT -> credits = Math.addExact(credits, p.amountPoisha());
                default -> throw new IllegalArgumentException("entryType must be DEBIT or CREDIT: " + p.entryType());
            }
        }
        if (debits != credits)
            throw new IllegalArgumentException("unbalanced posting set: debits=" + debits + " credits=" + credits);
        return new Postings(legs);
    }

    /** The common two-leg transfer: amount moves from one account to another. */
    public static Postings transfer(String fromAccount, String toAccount, long amountPoisha,
                                    String referenceId, String referenceType, boolean creditWithdrawable) {
        return balanced(List.of(
            new Posting(fromAccount, DEBIT, amountPoisha, toAccount, referenceId, referenceType, true),
            new Posting(toAccount, CREDIT, amountPoisha, fromAccount, referenceId, referenceType, creditWithdrawable)));
    }

    public List<Posting> legs() { return legs; }
}
