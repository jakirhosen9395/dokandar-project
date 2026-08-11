package com.dokandar.finance.domain;

import com.dokandar.platform.Errors;

/**
 * BR-035 per-KYC-tier limit enforcement: max balance (inbound), single-txn cap, daily-out cap.
 * V0 is receive-only — no spend/withdraw at all, regardless of amounts (canon).
 * NUMERIC cap values are policy-as-data in the wallet_limits table (synthetic dev seed;
 * real Bangladesh Bank figures are NEEDS-INFO in the frozen contracts). NULL = unbounded.
 */
public final class Caps {

    /** A tier's limits row. Null Long = unbounded on that axis. */
    public record TierLimits(String tier, Long singleTxnMaxPoisha, Long dailyOutMaxPoisha, Long maxBalancePoisha) {}

    private Caps() {}

    public static void checkCredit(TierLimits limits, long amountPoisha, long currentBalancePoisha) {
        requirePositive(amountPoisha);
        if (limits.singleTxnMaxPoisha() != null && amountPoisha > limits.singleTxnMaxPoisha())
            throw new Errors.BusinessException(
                Errors.errorCode("finance", "wallet", "single_txn_cap_exceeded"),
                "amount " + amountPoisha + " poisha exceeds tier " + limits.tier() + " single-txn cap");
        if (limits.maxBalancePoisha() != null
                && Math.addExact(currentBalancePoisha, amountPoisha) > limits.maxBalancePoisha())
            throw new Errors.BusinessException(
                Errors.errorCode("finance", "wallet", "max_balance_exceeded"),
                "credit would exceed tier " + limits.tier() + " max balance");
    }

    public static void checkDebit(TierLimits limits, long amountPoisha, long dailyOutSoFarPoisha) {
        requirePositive(amountPoisha);
        if ("V0".equals(limits.tier()))
            throw new Errors.BusinessException(
                Errors.errorCode("finance", "wallet", "tier_receive_only"),
                "tier V0 wallets are receive-only (BR-035): no spend or withdraw");
        if (limits.singleTxnMaxPoisha() != null && amountPoisha > limits.singleTxnMaxPoisha())
            throw new Errors.BusinessException(
                Errors.errorCode("finance", "wallet", "single_txn_cap_exceeded"),
                "amount " + amountPoisha + " poisha exceeds tier " + limits.tier() + " single-txn cap");
        if (limits.dailyOutMaxPoisha() != null
                && Math.addExact(dailyOutSoFarPoisha, amountPoisha) > limits.dailyOutMaxPoisha())
            throw new Errors.BusinessException(
                Errors.errorCode("finance", "wallet", "daily_out_cap_exceeded"),
                "debit would exceed tier " + limits.tier() + " daily-out cap");
    }

    private static void requirePositive(long amountPoisha) {
        if (amountPoisha <= 0)
            throw new Errors.ValidationException(
                Errors.errorCode("finance", "wallet", "amount_not_positive"),
                "amountPoisha must be > 0");
    }
}
