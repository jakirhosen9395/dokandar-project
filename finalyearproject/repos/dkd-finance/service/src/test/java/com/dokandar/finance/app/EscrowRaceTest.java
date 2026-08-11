package com.dokandar.finance.app;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import com.dokandar.finance.store.WalletStore;
import com.dokandar.platform.Errors;
import java.util.Optional;
import org.junit.jupiter.api.Test;

/**
 * F-2 regression guard. When a buyer/seller wallet is missing on the EVENT (spine) path,
 * {@code onOrderPlaced} MUST throw a RETRYABLE exception (an {@link IllegalStateException}, i.e. an
 * infrastructure error) — NOT a {@link Errors.DokandarException}. SpineListener catches
 * DokandarException as "business-final" and ack+skips it; a retryable throw instead propagates so the
 * money-context error handler parks/retries. If a future refactor makes onOrderPlaced throw a
 * DokandarException on a missing wallet again, the Saga-1 escrow is silently dropped on a cross-topic
 * race — exactly the F-2 bug — and this test fails.
 */
class EscrowRaceTest {

    private static final String BUYER = "did:dokandar:018f0000-0000-7000-8000-000000000001";
    private static final String SELLER = "did:dokandar:018f0000-0000-7000-8000-000000000002";

    /** onOrderPlaced touches only `wallets` before it throws, so the other deps can be null. */
    private EscrowService serviceWithNoWallets() {
        WalletStore wallets = mock(WalletStore.class);
        when(wallets.findByDid(anyString())).thenReturn(Optional.empty());
        return new EscrowService(null, wallets, null, null, null, null);
    }

    @Test
    void onOrderPlaced_missingWallet_isRetryableNotBusinessFinal() {
        EscrowService svc = serviceWithNoWallets();
        Throwable thrown = assertThrows(
            IllegalStateException.class,
            () -> svc.onOrderPlaced("ORD-F2-REGRESSION", BUYER, SELLER, 5000L));
        assertFalse(
            thrown instanceof Errors.DokandarException,
            "wallet-missing on the OrderPlaced event path must be a RETRYABLE infra error (park/retry), "
                + "never a business-final DokandarException (ack+skip → silent escrow drop, F-2)");
    }

    // ---- F-2b: deposit-lag insufficient_funds on the event path must be retryable, not ack+skip ----

    @Test
    void depositLag_insufficientFunds_translatesToRetryable() {
        Errors.BusinessException insufficient = new Errors.BusinessException(
            "dokandar.finance.escrow.insufficient_funds", "buyer withdrawable 0 < 5000");
        RuntimeException out = EscrowService.retryableIfDepositLag(insufficient, "ORD-1");
        org.junit.jupiter.api.Assertions.assertTrue(out instanceof IllegalStateException,
            "insufficient_funds on the event path is a transient deposit-lag → retryable (bounded retry → DLQ)");
        assertFalse(out instanceof Errors.DokandarException, "must NOT stay business-final (F-2b silent drop)");
    }

    @Test
    void otherBusinessErrors_stayBusinessFinal() {
        Errors.BusinessException notActive = new Errors.BusinessException(
            "dokandar.finance.escrow.buyer_not_active", "buyer wallet is FROZEN");
        RuntimeException out = EscrowService.retryableIfDepositLag(notActive, "ORD-2");
        org.junit.jupiter.api.Assertions.assertSame(notActive, out,
            "a genuine business rejection (not insufficient_funds) must stay business-final (ack+skip), not retry");
    }
}
