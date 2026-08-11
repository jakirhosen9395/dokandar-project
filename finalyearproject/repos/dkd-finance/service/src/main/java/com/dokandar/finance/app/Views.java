package com.dokandar.finance.app;

import com.dokandar.finance.store.EscrowStore;
import com.dokandar.finance.store.LedgerStore;
import com.dokandar.finance.store.WalletStore;
import java.util.List;

/** Read models returned by the API. Balances are always derived from the ledger (BR-028). */
public final class Views {
    private Views() {}

    public record WalletView(String wlt, String ownerDid, String status, String kycTier,
                             long balancePoisha, long withdrawablePoisha, long createdAt) {}

    public record MfsView(String id, String wlt, String provider, String mobileMasked,
                          String accountName, boolean isPrimary, String status) {}

    public record TxnView(String txnId, String wlt, long amountPoisha, String referenceId,
                          String referenceType, long balancePoisha, long withdrawablePoisha) {}

    public record EscrowView(String esc, String referenceId, String referenceType, String buyerWlt,
                             String sellerWlt, long amountPoisha, String status, String podEvidence,
                             String reason, long createdAt, Long releasedAt, Long coolingOffExpiresAt,
                             Long closedAt) {}

    public record LedgerEntryView(long id, String txnId, String entryType, long amountPoisha,
                                  String counterpartAccount, String referenceId, String referenceType,
                                  boolean isWithdrawable, long createdAt) {}

    public record IntegrityView(long txnCount, List<String> unbalancedTxns, boolean balanced) {}

    public static WalletView wallet(WalletStore.WalletRow row, LedgerStore ledger) {
        return new WalletView(row.wlt(), row.ownerDid(), row.status(), row.kycTier(),
            ledger.balance(row.wlt()), ledger.withdrawable(row.wlt()), row.createdAt());
    }

    public static MfsView mfs(WalletStore.MfsRow row) {
        return new MfsView(row.id(), row.wlt(), row.provider(), mask(row.mobile()),
            row.accountName(), row.isPrimary(), row.status());
    }

    public static EscrowView escrow(EscrowStore.EscrowRow r) {
        return new EscrowView(r.esc(), r.referenceId(), r.referenceType(), r.buyerWlt(), r.sellerWlt(),
            r.amountPoisha(), r.status().name(), r.podEvidence(), r.reason(), r.createdAt(),
            r.releasedAt(), r.coolingOffExpiresAt(), r.closedAt());
    }

    public static LedgerEntryView entry(LedgerStore.EntryRow r) {
        return new LedgerEntryView(r.id(), r.txnId(), r.entryType(), r.amountPoisha(),
            r.counterpartAccount(), r.referenceId(), r.referenceType(), r.isWithdrawable(), r.createdAt());
    }

    /** Mobile numbers never leave the service unmasked (PII). */
    static String mask(String mobile) {
        if (mobile == null || mobile.length() < 7) return "***";
        return mobile.substring(0, 4) + "*****" + mobile.substring(mobile.length() - 3);
    }
}
