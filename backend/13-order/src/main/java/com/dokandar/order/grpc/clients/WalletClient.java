package com.dokandar.order.grpc.clients;

import dokandar.wallet.v1.BalanceResponse;
import dokandar.wallet.v1.CreditRequest;
import dokandar.wallet.v1.DebitRequest;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

/**
 * Wallet ledger client — DebitWallet on placement, CreditWallet for compensation.
 * The compensation MUST use a DISTINCT idempotency key from the debit so the refund
 * is never deduped against the original debit (no double-spend / no lost refund).
 * FAIL-CLOSED: transport/peer errors throw {@link WalletException}; the saga aborts
 * (debit) or retries the compensation (credit).
 */
@Component
public class WalletClient {

    private static final Logger log = LoggerFactory.getLogger(WalletClient.class);

    private final GrpcClients clients;

    public WalletClient(GrpcClients clients) {
        this.clients = clients;
    }

    /**
     * Debit {@code amountMinor} from {@code userId}'s wallet. idempotencyKey gives
     * effectively-once. kind defaults to order_payment server-side when blank.
     */
    public WalletResult debitWallet(String userId, long amountMinor, String idempotencyKey,
                                    String orderId, String kind) {
        DebitRequest req = DebitRequest.newBuilder()
                .setUserId(userId)
                .setAmountMinor(amountMinor)
                .setIdempotencyKey(idempotencyKey)
                .setOrderId(orderId == null ? "" : orderId)
                .setKind(kind == null ? "" : kind)
                .build();
        try {
            BalanceResponse resp = clients.wallet().debitWallet(req);
            return toResult(resp);
        } catch (RuntimeException e) {
            log.warn("DebitWallet failed user={} order={}", userId, orderId, e);
            throw new WalletException("wallet_debit_failed", "DebitWallet call failed", e);
        }
    }

    /**
     * Credit (compensation/refund). idempotencyKey MUST differ from the matching debit.
     * kind is e.g. refund_to_wallet | cashback.
     */
    public WalletResult creditWallet(String userId, long amountMinor, String idempotencyKey,
                                     String orderId, String kind) {
        CreditRequest req = CreditRequest.newBuilder()
                .setUserId(userId)
                .setAmountMinor(amountMinor)
                .setIdempotencyKey(idempotencyKey)
                .setOrderId(orderId == null ? "" : orderId)
                .setKind(kind == null ? "" : kind)
                .build();
        try {
            BalanceResponse resp = clients.wallet().creditWallet(req);
            return toResult(resp);
        } catch (RuntimeException e) {
            log.warn("CreditWallet failed user={} order={}", userId, orderId, e);
            throw new WalletException("wallet_credit_failed", "CreditWallet call failed", e);
        }
    }

    private WalletResult toResult(BalanceResponse r) {
        return new WalletResult(r.getBalanceMinor(), r.getAvailableMinor(), r.getCurrency(),
                r.getStatus(), r.getEntryId());
    }

    /** Ledger outcome. entryId is the ledger entry id set on debit/credit. */
    public record WalletResult(long balanceMinor, long availableMinor, String currency,
                               String status, String entryId) {}

    /** Thrown on any wallet RPC failure (fail-closed). */
    public static class WalletException extends RuntimeException {
        private final String code;
        public WalletException(String code, String message, Throwable cause) {
            super(message, cause);
            this.code = code;
        }
        public String getCode() { return code; }
    }
}
