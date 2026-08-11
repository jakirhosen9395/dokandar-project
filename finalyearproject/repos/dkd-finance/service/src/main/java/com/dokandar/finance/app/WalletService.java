package com.dokandar.finance.app;

import com.dokandar.finance.domain.Caps;
import com.dokandar.finance.domain.FinanceIds;
import com.dokandar.finance.domain.Postings;
import com.dokandar.finance.domain.Rules;
import com.dokandar.finance.config.FinanceProps;
import com.dokandar.finance.store.LedgerStore;
import com.dokandar.finance.store.WalletStore;
import com.dokandar.platform.Errors;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.List;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Wallet commands. DID -> WLT resolution happens INSIDE finance (R2).
 * Every money mutation: row-lock the wallet, enforce status + BR-035 caps + BR-030
 * withdrawable-funds rule, append balanced ledger legs, emit the event via the outbox —
 * all in one transaction.
 */
@Service
public class WalletService {
    private static final Logger log = LoggerFactory.getLogger(WalletService.class);
    /** A newly registered party is UNVERIFIED = V0 (receive-only). The tier then TRACKS the Identity
     *  KYC lifecycle: KYCApproved -> V1(BASIC), KYCTierChanged -> V2(FULL)/V3(BUSINESS). (F-1/BR-035) */
    private static final String DEFAULT_TIER = "V0";

    private final WalletStore wallets;
    private final LedgerStore ledger;
    private final EventFactory events;
    private final FinanceProps props;

    public WalletService(WalletStore wallets, LedgerStore ledger, EventFactory events, FinanceProps props) {
        this.wallets = wallets;
        this.ledger = ledger;
        this.events = events;
        this.props = props;
    }

    /**
     * Idempotent on owner_did: creating a wallet for a DID that already has one returns the
     * existing wallet instead of throwing — so a concurrent duplicate request flows through to
     * the cmd_idempotency insert and replays the winner (reviewer HIGH: throwing here escaped
     * the DuplicateKeyException replay path and produced a false 409).
     */
    @Transactional
    public Views.WalletView create(String ownerDid) {
        Rules.requireDid(ownerDid);
        long now = System.currentTimeMillis();
        String wlt = FinanceIds.newWlt();
        if (!wallets.insert(wlt, ownerDid, DEFAULT_TIER, now))
            return Views.wallet(wallets.findByDid(ownerDid).orElseThrow(), ledger);
        events.walletCreated(wlt, ownerDid, now);
        return Views.wallet(wallets.find(wlt).orElseThrow(), ledger);
    }

    @Transactional
    public Views.TxnView credit(String wlt, long amountPoisha, String referenceId, String referenceType,
                                Boolean isWithdrawable) {
        Rules.requireText(referenceId, "referenceId");
        Rules.requireReferenceType(referenceType);
        long now = System.currentTimeMillis();
        WalletStore.WalletRow row = requireActive(wallets.lock(wlt));
        Caps.checkCredit(wallets.tierLimits(row.kycTier()), amountPoisha, ledger.balance(wlt));
        String txnId = FinanceIds.newTxn();
        ledger.append(txnId, Postings.transfer(props.sysCashAccount(), wlt, amountPoisha,
            referenceId, referenceType, isWithdrawable == null || isWithdrawable), null, now);
        events.walletCredited(wlt, txnId, amountPoisha, referenceId, referenceType, now);
        return new Views.TxnView(txnId, wlt, amountPoisha, referenceId, referenceType,
            ledger.balance(wlt), ledger.withdrawable(wlt));
    }

    @Transactional
    public Views.TxnView debit(String wlt, long amountPoisha, String referenceId, String referenceType) {
        Rules.requireText(referenceId, "referenceId");
        Rules.requireReferenceType(referenceType);
        long now = System.currentTimeMillis();
        WalletStore.WalletRow row = requireActive(wallets.lock(wlt));
        Caps.checkDebit(wallets.tierLimits(row.kycTier()), amountPoisha, ledger.outSince(wlt, utcMidnight()));
        requireWithdrawable(wlt, amountPoisha);
        String txnId = FinanceIds.newTxn();
        ledger.append(txnId, Postings.transfer(wlt, props.sysCashAccount(), amountPoisha,
            referenceId, referenceType, true), null, now);
        events.walletDebited(wlt, txnId, amountPoisha, referenceId, referenceType, now);
        return new Views.TxnView(txnId, wlt, amountPoisha, referenceId, referenceType,
            ledger.balance(wlt), ledger.withdrawable(wlt));
    }

    @Transactional
    public Views.WalletView freeze(String wlt, String reason, String freezeRef) {
        long now = System.currentTimeMillis();
        WalletStore.WalletRow row = require(wallets.lock(wlt));
        if ("CLOSED".equals(row.status()))
            throw new Errors.BusinessException(
                Errors.errorCode("finance", "wallet", "closed"), "wallet is closed");
        if (!"FROZEN".equals(row.status())) {
            wallets.setStatus(wlt, "FROZEN", reason, freezeRef, now);
            events.walletFrozen(wlt, reason, freezeRef, now);
        }
        return Views.wallet(wallets.find(wlt).orElseThrow(), ledger);
    }

    @Transactional
    public Views.MfsView registerMfs(String wlt, String provider, String mobile, String accountName) {
        Rules.requireText(provider, "provider");
        Rules.requireText(accountName, "accountName");
        Rules.requireBdMobile(mobile);
        long now = System.currentTimeMillis();
        WalletStore.WalletRow row = requireActive(wallets.lock(wlt));
        if (wallets.countActiveMfs(wlt) >= Rules.MAX_MFS_ACCOUNTS)
            throw new Errors.BusinessException(
                Errors.errorCode("finance", "mfs", "account_limit_reached"),
                "a wallet holds at most " + Rules.MAX_MFS_ACCOUNTS + " MFS accounts");
        String id = FinanceIds.newMfs();
        wallets.insertMfs(id, wlt, provider, mobile, accountName, !wallets.hasPrimaryMfs(wlt), now);
        events.mfsAccountRegistered(wlt, id, provider, now);
        return Views.mfs(wallets.findMfs(id).orElseThrow());
    }

    @Transactional
    public Views.MfsView verifyMfs(String wlt, String mfsId, String otpToken) {
        Rules.requireOtpShape(otpToken);
        long now = System.currentTimeMillis();
        requireActive(wallets.lock(wlt));
        WalletStore.MfsRow mfs = wallets.findMfs(mfsId)
            .filter(m -> m.wlt().equals(wlt))
            .orElseThrow(() -> new Errors.ValidationException(
                Errors.errorCode("finance", "mfs", "not_found"), "MFS account not found on this wallet"));
        if (wallets.markMfsVerified(mfsId)) {
            events.mfsAccountVerified(wlt, mfsId, now);
        } else {
            // Re-read after the CAS lost: a concurrent verify may have flipped it to VERIFIED,
            // which is an idempotent success, not a rejection (reviewer LOW).
            String current = wallets.findMfs(mfsId).orElseThrow().status();
            if (!"VERIFIED".equals(current))
                throw new Errors.BusinessException(
                    Errors.errorCode("finance", "mfs", "not_verifiable"),
                    "MFS account is " + current + ", not PENDING");
        }
        return Views.mfs(wallets.findMfs(mfsId).orElseThrow());
    }

    @Transactional(readOnly = true)
    public Views.WalletView get(String wlt) {
        return Views.wallet(require(wallets.find(wlt)), ledger);
    }

    @Transactional(readOnly = true)
    public Views.WalletView getByDid(String did) {
        return Views.wallet(require(wallets.findByDid(did)), ledger);
    }

    @Transactional(readOnly = true)
    public List<Views.LedgerEntryView> ledgerEntries(String wlt, int limit) {
        require(wallets.find(wlt));
        return ledger.entries(wlt, limit).stream().map(Views::entry).toList();
    }

    /** F-13: opaque keyset-cursor page — nextCursor is the last entry id (null when no more). */
    public record LedgerPage(List<Views.LedgerEntryView> entries, String nextCursor, boolean hasMore, int limit) {}

    @Transactional(readOnly = true)
    public LedgerPage ledgerPage(String wlt, long afterId, int limit) {
        require(wallets.find(wlt));
        int capped = limit <= 0 || limit > 200 ? 50 : limit;
        List<LedgerStore.EntryRow> rows = ledger.entries(wlt, afterId, capped);
        boolean hasMore = rows.size() == capped;
        String nextCursor = hasMore && !rows.isEmpty() ? String.valueOf(rows.get(rows.size() - 1).id()) : null;
        return new LedgerPage(rows.stream().map(Views::entry).toList(), nextCursor, hasMore, capped);
    }

    @Transactional(readOnly = true)
    public Views.IntegrityView integrity() {
        List<String> bad = ledger.unbalancedTxns();
        return new Views.IntegrityView(ledger.txnCount(), bad, bad.isEmpty());
    }

    // ---- event-driven (spine) paths ----

    /** PartyRegistered -> wallet auto-provision (idempotent on owner_did). */
    @Transactional
    public void ensureWalletForParty(String did) {
        if (!FinanceIds.isDid(did)) {
            log.warn("PartyRegistered without a valid did — skipped");
            return;
        }
        long now = System.currentTimeMillis();
        String wlt = FinanceIds.newWlt();
        if (wallets.insert(wlt, did, DEFAULT_TIER, now)) {
            events.walletCreated(wlt, did, now);
            log.info("wallet {} auto-provisioned for registered party at tier {}", wlt, DEFAULT_TIER);
        }
    }

    /**
     * KYCApproved / KYCTierChanged -> re-tier the wallet so BR-035 per-tier caps actually bind.
     * Identity emits tier NAMES (UNVERIFIED/BASIC/FULL/BUSINESS); map to the V0-V3 policy codes.
     * Idempotent + monotonic-friendly: a re-delivered or out-of-order lower tier never downgrades.
     */
    @Transactional
    public void setTierByDid(String did, String identityTier) {
        if (!FinanceIds.isDid(did)) {
            log.warn("KYC tier event without a valid did — skipped");
            return;
        }
        String tier = mapKycTier(identityTier);
        if (tier == null) {
            log.warn("KYC tier event with unknown tier '{}' for {} — skipped", identityTier, did);
            return;
        }
        var row = wallets.lockByDid(did);
        if (row.isEmpty()) {
            // Wallet not provisioned yet (KYC event before PartyRegistered) — transient cross-topic
            // race; park/retry so the tier is applied once the wallet exists (never silently dropped).
            throw new IllegalStateException("KYC tier event for " + did + " arrived before its wallet — retrying");
        }
        if (tierRank(tier) <= tierRank(row.get().kycTier())) {
            return; // already at or above this tier — no-op (idempotent / non-downgrading)
        }
        wallets.updateTierByDid(did, tier, System.currentTimeMillis());
        log.info("wallet for {} re-tiered {} -> {} from KYC event", did, row.get().kycTier(), tier);
    }

    /** Map Identity KYC tier (UNVERIFIED/BASIC/FULL/BUSINESS) to the finance V0-V3 policy code. */
    static String mapKycTier(String t) {
        if (t == null) return null;
        return switch (t.trim().toUpperCase()) {
            case "UNVERIFIED", "V0" -> "V0";
            case "BASIC", "V1" -> "V1";
            case "FULL", "V2" -> "V2";
            case "BUSINESS", "V3" -> "V3";
            default -> null;
        };
    }

    private static int tierRank(String v) {
        return switch (v == null ? "" : v) { case "V1" -> 1; case "V2" -> 2; case "V3" -> 3; default -> 0; };
    }

    /** Fraud AccountHeld / government WalletFreezeDirective / identity PartySuspended -> freeze. */
    @Transactional
    public void freezeByDid(String did, String reason, String ref) {
        var row = wallets.lockByDid(did);
        if (row.isEmpty()) {
            log.warn("freeze directive for unknown DID — skipped (ref={})", ref);
            return;
        }
        freeze(row.get().wlt(), reason, ref);
    }

    /**
     * Fraud AccountHoldReleased / identity PartyReactivated -> unfreeze. The frozen registry
     * has no WalletUnfrozen topic, so this state change emits no event (documented gap).
     */
    @Transactional
    public void unfreezeByDid(String did, String ref) {
        var row = wallets.lockByDid(did);
        if (row.isEmpty() || !"FROZEN".equals(row.get().status())) return;
        wallets.setStatus(row.get().wlt(), "ACTIVE", null, ref, System.currentTimeMillis());
        log.info("wallet {} unfrozen (ref={})", row.get().wlt(), ref);
    }

    private WalletStore.WalletRow require(java.util.Optional<WalletStore.WalletRow> row) {
        return row.orElseThrow(() -> new Errors.ValidationException(
            Errors.errorCode("finance", "wallet", "not_found"), "wallet not found"));
    }

    private WalletStore.WalletRow requireActive(java.util.Optional<WalletStore.WalletRow> row) {
        WalletStore.WalletRow w = require(row);
        if (!"ACTIVE".equals(w.status()))
            throw new Errors.BusinessException(
                Errors.errorCode("finance", "wallet", "not_active"),
                "wallet is " + w.status());
        return w;
    }

    private void requireWithdrawable(String wlt, long amountPoisha) {
        long available = ledger.withdrawable(wlt);
        if (available < amountPoisha)
            throw new Errors.BusinessException(
                Errors.errorCode("finance", "wallet", "insufficient_withdrawable"),
                "withdrawable " + available + " poisha < requested " + amountPoisha + " (BR-030)");
    }

    static long utcMidnight() {
        return Instant.now().truncatedTo(ChronoUnit.DAYS).toEpochMilli();
    }
}
