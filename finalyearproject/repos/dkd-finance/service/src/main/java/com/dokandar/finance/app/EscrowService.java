package com.dokandar.finance.app;

import com.dokandar.finance.config.FinanceProps;
import com.dokandar.finance.domain.Caps;
import com.dokandar.finance.domain.EscrowStatus;
import com.dokandar.finance.domain.FinanceIds;
import com.dokandar.finance.domain.Postings;
import com.dokandar.finance.domain.Rules;
import com.dokandar.finance.store.EscrowStore;
import com.dokandar.finance.store.LedgerStore;
import com.dokandar.finance.store.TradeRefStore;
import com.dokandar.finance.store.WalletStore;
import com.dokandar.platform.Errors;
import java.util.Optional;
import java.util.Set;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Escrow saga (R3): money moves buyer -> escrow suspense (account id = esc) -> seller.
 * Release parks the seller credit non-withdrawable behind the cooling-off window
 * (SETTLEMENT_HELD); reversal/expiry/clawback NEVER deletes history — every path is a
 * compensating balanced posting set. Ledger legs for escrow flows carry
 * referenceId = esc / referenceType = ESCROW so withdrawable math derives from escrow status.
 */
@Service
public class EscrowService {
    private static final Logger log = LoggerFactory.getLogger(EscrowService.class);
    private static final Set<String> ESCROW_REF_TYPES = Set.of("ORDER", "TRADE");

    private final EscrowStore escrows;
    private final WalletStore wallets;
    private final LedgerStore ledger;
    private final TradeRefStore tradeRefs;
    private final EventFactory events;
    private final FinanceProps props;

    public EscrowService(EscrowStore escrows, WalletStore wallets, LedgerStore ledger,
                         TradeRefStore tradeRefs, EventFactory events, FinanceProps props) {
        this.escrows = escrows;
        this.wallets = wallets;
        this.ledger = ledger;
        this.tradeRefs = tradeRefs;
        this.events = events;
        this.props = props;
    }

    @Transactional
    public Views.EscrowView create(String referenceId, String referenceType, String buyerWlt,
                                   String sellerWlt, long amountPoisha) {
        Rules.requireText(referenceId, "referenceId");
        if (referenceType == null || !ESCROW_REF_TYPES.contains(referenceType))
            throw new Errors.ValidationException(
                Errors.errorCode("finance", "escrow", "invalid_reference_type"),
                "escrow referenceType must be ORDER or TRADE");
        if (buyerWlt == null || buyerWlt.equals(sellerWlt))
            throw new Errors.ValidationException(
                Errors.errorCode("finance", "escrow", "buyer_seller_identical"),
                "buyer and seller wallets must differ");
        long now = System.currentTimeMillis();
        // Deterministic lock order across both wallets prevents deadlock between concurrent escrows.
        WalletStore.WalletRow first = lockWallet(buyerWlt.compareTo(sellerWlt) < 0 ? buyerWlt : sellerWlt);
        WalletStore.WalletRow second = lockWallet(buyerWlt.compareTo(sellerWlt) < 0 ? sellerWlt : buyerWlt);
        WalletStore.WalletRow buyer = first.wlt().equals(buyerWlt) ? first : second;
        WalletStore.WalletRow seller = first.wlt().equals(sellerWlt) ? first : second;
        if (!"ACTIVE".equals(buyer.status()))
            throw new Errors.BusinessException(
                Errors.errorCode("finance", "escrow", "buyer_not_active"), "buyer wallet is " + buyer.status());
        if ("CLOSED".equals(seller.status()))
            throw new Errors.BusinessException(
                Errors.errorCode("finance", "escrow", "seller_closed"), "seller wallet is closed");
        Caps.checkDebit(wallets.tierLimits(buyer.kycTier()), amountPoisha,
            ledger.outSince(buyerWlt, WalletService.utcMidnight()));
        long available = ledger.withdrawable(buyerWlt);
        if (available < amountPoisha)
            throw new Errors.BusinessException(
                Errors.errorCode("finance", "escrow", "insufficient_funds"),
                "buyer withdrawable " + available + " poisha < escrow amount " + amountPoisha);
        String esc = FinanceIds.newEsc();
        if (!escrows.insert(esc, referenceId, referenceType, buyerWlt, sellerWlt, amountPoisha, now)) {
            EscrowStore.EscrowRow existing = escrows.lockByReference(referenceId, referenceType).orElseThrow();
            if (existing.buyerWlt().equals(buyerWlt) && existing.sellerWlt().equals(sellerWlt)
                    && existing.amountPoisha() == amountPoisha)
                return Views.escrow(existing); // duplicate command for the same business fact
            throw new Errors.BusinessException(
                Errors.errorCode("finance", "escrow", "reference_conflict"),
                "an escrow with different terms already exists for this reference");
        }
        ledger.append(FinanceIds.newTxn(),
            Postings.transfer(buyerWlt, esc, amountPoisha, esc, "ESCROW", true), "ESC:" + esc + ":create:" + referenceId, now);
        events.escrowCreated(esc, referenceId, referenceType, buyerWlt, sellerWlt, amountPoisha, now);
        return Views.escrow(escrows.find(esc).orElseThrow());
    }

    /** POD received: ACTIVE -> SETTLEMENT_HELD; seller credited non-withdrawable behind cooling-off. */
    @Transactional
    public Views.EscrowView release(String esc, String podEvidence) {
        long now = System.currentTimeMillis();
        // Lock order everywhere: wallet rows (sorted) BEFORE the escrow row — same order as
        // create()'s duplicate path, so concurrent create/release/reverse cannot deadlock.
        EscrowStore.EscrowRow pre = findEscrow(esc);
        lockWalletsSorted(pre.buyerWlt(), pre.sellerWlt());
        EscrowStore.EscrowRow row = lockEscrow(esc);
        requireStatus(row, EscrowStatus.ACTIVE, "release");
        long coolingOff = now + props.coolingOffMs();
        escrows.transition(esc, EscrowStatus.ACTIVE, EscrowStatus.SETTLEMENT_HELD,
            podEvidence, null, now, coolingOff, null);
        ledger.append(FinanceIds.newTxn(),
            Postings.transfer(esc, row.sellerWlt(), row.amountPoisha(), esc, "ESCROW", false), "ESC:" + esc + ":release:" + row.referenceId(), now);
        events.escrowReleased(esc, row.referenceId(), row.referenceType(), coolingOff, now);
        return Views.escrow(escrows.find(esc).orElseThrow());
    }

    /**
     * Cooling-off elapsed: SETTLEMENT_HELD -> RELEASED. No ledger legs — withdrawability is
     * derived from escrow status. bypassClock=true only for the scheduler event (clock authority).
     */
    @Transactional
    public Views.EscrowView releaseHold(String esc, boolean bypassClock) {
        long now = System.currentTimeMillis();
        EscrowStore.EscrowRow row = lockEscrow(esc);
        requireStatus(row, EscrowStatus.SETTLEMENT_HELD, "release-hold");
        if (!bypassClock && (row.coolingOffExpiresAt() == null || now < row.coolingOffExpiresAt()))
            throw new Errors.BusinessException(
                Errors.errorCode("finance", "escrow", "cooling_off_active"),
                "cooling-off window has not elapsed yet");
        escrows.transition(esc, EscrowStatus.SETTLEMENT_HELD, EscrowStatus.RELEASED,
            null, null, null, null, now);
        events.settlementHoldReleased(esc, row.referenceType(), now);
        return Views.escrow(escrows.find(esc).orElseThrow());
    }

    /**
     * R3 compensating reversal. ACTIVE -> REVERSED refunds from suspense;
     * SETTLEMENT_HELD -> CLAWED_BACK claws the parked seller credit back to the buyer.
     */
    @Transactional
    public Views.EscrowView reverse(String esc, String reason) {
        long now = System.currentTimeMillis();
        // Wallet locks first (reviewer HIGH: clawback debits the seller — without the seller
        // row lock a concurrent debit races the compensating entries), then the escrow row.
        EscrowStore.EscrowRow pre = findEscrow(esc);
        lockWalletsSorted(pre.buyerWlt(), pre.sellerWlt());
        EscrowStore.EscrowRow row = lockEscrow(esc);
        switch (row.status()) {
            case ACTIVE -> {
                escrows.transition(esc, EscrowStatus.ACTIVE, EscrowStatus.REVERSED, null, reason, null, null, now);
                ledger.append(FinanceIds.newTxn(),
                    Postings.transfer(esc, row.buyerWlt(), row.amountPoisha(), esc, "ESCROW", true), "ESC:" + esc + ":reverse:" + row.referenceId(), now);
            }
            case SETTLEMENT_HELD -> {
                escrows.transition(esc, EscrowStatus.SETTLEMENT_HELD, EscrowStatus.CLAWED_BACK,
                    null, reason, null, null, now);
                ledger.append(FinanceIds.newTxn(),
                    Postings.transfer(row.sellerWlt(), row.buyerWlt(), row.amountPoisha(), esc, "ESCROW", true),
                    "ESC:" + esc + ":clawback:" + row.referenceId(), now);
            }
            default -> throw new Errors.BusinessException(
                Errors.errorCode("finance", "escrow", "not_reversible"),
                "escrow is " + row.status() + " — terminal states cannot be reversed");
        }
        events.escrowReversed(esc, row.referenceId(), row.referenceType(), reason, now);
        return Views.escrow(escrows.find(esc).orElseThrow());
    }

    /**
     * Scheduler EscrowExpired (7d TTL): ACTIVE -> EXPIRED + refund. The registry owns no
     * finance-produced "expired" topic, so the money fact goes out as EscrowReversed with
     * reason EXPIRED (documented decision).
     */
    @Transactional
    public void expire(String esc) {
        long now = System.currentTimeMillis();
        Optional<EscrowStore.EscrowRow> pre = escrows.find(esc);
        if (pre.isEmpty()) {
            log.info("EscrowExpired for {} skipped (missing)", esc);
            return;
        }
        lockWalletsSorted(pre.get().buyerWlt(), pre.get().sellerWlt());
        Optional<EscrowStore.EscrowRow> found = escrows.lock(esc);
        if (found.isEmpty() || found.get().status() != EscrowStatus.ACTIVE) {
            log.info("EscrowExpired for {} skipped (missing or not ACTIVE)", esc);
            return;
        }
        EscrowStore.EscrowRow row = found.get();
        escrows.transition(esc, EscrowStatus.ACTIVE, EscrowStatus.EXPIRED, null, "EXPIRED", null, null, now);
        ledger.append(FinanceIds.newTxn(),
            Postings.transfer(esc, row.buyerWlt(), row.amountPoisha(), esc, "ESCROW", true), "ESC:" + esc + ":expire:" + row.referenceId(), now);
        events.escrowReversed(esc, row.referenceId(), row.referenceType(), "EXPIRED", now);
    }

    @Transactional(readOnly = true)
    public Views.EscrowView get(String esc) {
        return Views.escrow(escrows.find(esc).orElseThrow(() -> new Errors.ValidationException(
            Errors.errorCode("finance", "escrow", "not_found"), "escrow not found")));
    }

    // ---- event-driven (spine) paths; DID -> WLT resolution inside finance (R2) ----

    @Transactional
    public void onOrderPlaced(String orderId, String buyerDid, String sellerDid, long amountPoisha) {
        // Cross-TOPIC delivery order is undefined: OrderPlaced (b2c.order) and PartyRegistered
        // (identity.party) are different topics/partitions, so an OrderPlaced can arrive before the
        // buyer/seller wallet is provisioned. A missing wallet here is TRANSIENT — fail as INFRA
        // (retry/park), NEVER ack+skip, or the escrow (and the whole B2C saga) is silently lost.
        // Mirrors onMarginPosted's retryable dependency handling (F-2, reviewer H-2).
        String buyerWlt = wltForDidOrRetry(buyerDid, "buyer");
        String sellerWlt = wltForDidOrRetry(sellerDid, "seller");
        try {
            create(orderId, "ORDER", buyerWlt, sellerWlt, amountPoisha);
        } catch (Errors.BusinessException e) {
            throw retryableIfDepositLag(e, orderId);
        }
        log.info("escrow created from OrderPlaced {}", orderId);
    }

    /**
     * F-2b — the deposit-lag twin: on the EVENT path the buyer's {@code WalletCredited} may not be
     * consumed yet, so {@code insufficient_funds} is TRANSIENT → return an INFRA/retryable
     * {@link IllegalStateException} (bounded retry → per-key DLQ on exhaustion, {@code KafkaConfig}),
     * NEVER a silent ack+skip. Every other business error (buyer_not_active, seller_closed,
     * reference_conflict) stays business-final (returned unchanged → ack+skip).
     */
    static RuntimeException retryableIfDepositLag(Errors.BusinessException e, String orderId) {
        if (e.code != null && e.code.endsWith("insufficient_funds")) {
            return new IllegalStateException("OrderPlaced escrow for " + orderId
                + " — buyer funds not yet available (deposit lag), retrying: " + e.getMessage());
        }
        return e;
    }

    @Transactional
    public void onOrderDelivered(String orderId, String podEvidence) {
        EscrowStore.EscrowRow row = requireByReference(orderId, "ORDER");
        if (row.status() != EscrowStatus.ACTIVE) {
            log.info("delivery for order {} skipped — escrow already {}", orderId, row.status());
            return;
        }
        release(row.esc(), podEvidence);
    }

    @Transactional
    public void onOrderCancelled(String orderId, String reason) {
        EscrowStore.EscrowRow row = requireByReference(orderId, "ORDER");
        if (row.status().isTerminal()) {
            log.info("cancellation for order {} skipped — escrow already {}", orderId, row.status());
            return;
        }
        reverse(row.esc(), reason == null ? "ORDER_CANCELLED" : reason);
    }

    // ---- Saga 4 (B2B settlement): margin escrow lifecycle keyed referenceType=TRADE ----

    /** TradeOrderCreated only projects the parties; money moves when the margin is posted. */
    @Transactional
    public void onTradeOrderCreated(String trd, String buyerDid, String sellerDid) {
        tradeRefs.upsert(trd, buyerDid, sellerDid, System.currentTimeMillis());
    }

    /** MarginPosted {trd, amountPoisha}: buyer margin -> escrow suspense (BR-031/FR-MKT-052). */
    @Transactional
    public void onMarginPosted(String trd, long amountPoisha) {
        // Cross-TOPIC delivery order is undefined even with the same TRD key (reviewer H-2):
        // a missing trade_ref is transient, so fail as INFRA (retry/park), never ack+skip.
        TradeRefStore.TradeRef ref = tradeRefs.find(trd).orElseThrow(() ->
            new IllegalStateException(
                "MarginPosted for " + trd + " arrived before TradeOrderCreated — retrying"));
        create(trd, "TRADE", wltForDid(ref.buyerDid(), "buyer"), wltForDid(ref.sellerDid(), "seller"),
            amountPoisha);
        log.info("margin escrow created from MarginPosted {}", trd);
    }

    /**
     * SettlementInitiated: custody transfer was verified by B2B before emitting, so the
     * escrow releases (ACTIVE -> SETTLEMENT_HELD + EscrowReleased.v1, which B2B consumes
     * to CompleteTrade). Idempotent: a non-ACTIVE escrow is a replay, not an error.
     */
    @Transactional
    public void onSettlementInitiated(String trd, String evidence) {
        EscrowStore.EscrowRow row = requireByReference(trd, "TRADE");
        if (row.status() != EscrowStatus.ACTIVE) {
            log.info("settlement for trade {} skipped — escrow already {}", trd, row.status());
            return;
        }
        release(row.esc(), evidence);
    }

    /** Non-locking pre-read (reviewer H-1): the follow-up release()/reverse() takes
     *  wallets-sorted THEN escrow — pre-locking the escrow here would invert that order
     *  against concurrent REST commands and deadlock. */
    private EscrowStore.EscrowRow requireByReference(String referenceId, String referenceType) {
        return escrows.findByReference(referenceId, referenceType)
            .orElseThrow(() -> new Errors.BusinessException(
                Errors.errorCode("finance", "escrow", "not_found"),
                "no escrow for " + referenceType + " " + referenceId));
    }

    // Synchronous/command path: a missing wallet is a genuine business error (400/409, ack-final).
    private String wltForDid(String did, String role) {
        Rules.requireDid(did);
        return wallets.findByDid(did)
            .orElseThrow(() -> new Errors.BusinessException(
                Errors.errorCode("finance", "escrow", role + "_wallet_missing"),
                "no wallet for " + role + " DID"))
            .wlt();
    }

    // Event-consumer path: a missing wallet is a TRANSIENT cross-topic race (the party's
    // WalletCreated has not been consumed yet), so it must PARK/RETRY (IllegalStateException
    // propagates past SpineListener's business-final catch), never ack+skip. (F-2)
    private String wltForDidOrRetry(String did, String role) {
        Rules.requireDid(did);
        return wallets.findByDid(did)
            .orElseThrow(() -> new IllegalStateException(
                "OrderPlaced escrow for " + role + " DID arrived before its wallet was provisioned — retrying"))
            .wlt();
    }

    private WalletStore.WalletRow lockWallet(String wlt) {
        return wallets.lock(wlt).orElseThrow(() -> new Errors.ValidationException(
            Errors.errorCode("finance", "wallet", "not_found"), "wallet not found: " + wlt));
    }

    /** Deterministic wallet lock order — the single global order all escrow paths follow. */
    private void lockWalletsSorted(String a, String b) {
        lockWallet(a.compareTo(b) < 0 ? a : b);
        lockWallet(a.compareTo(b) < 0 ? b : a);
    }

    private EscrowStore.EscrowRow findEscrow(String esc) {
        return escrows.find(esc).orElseThrow(() -> new Errors.ValidationException(
            Errors.errorCode("finance", "escrow", "not_found"), "escrow not found"));
    }

    private EscrowStore.EscrowRow lockEscrow(String esc) {
        return escrows.lock(esc).orElseThrow(() -> new Errors.ValidationException(
            Errors.errorCode("finance", "escrow", "not_found"), "escrow not found"));
    }

    private void requireStatus(EscrowStore.EscrowRow row, EscrowStatus expected, String action) {
        if (row.status() != expected)
            throw new Errors.BusinessException(
                Errors.errorCode("finance", "escrow", "illegal_transition"),
                action + " requires " + expected + " but escrow is " + row.status());
    }
}
