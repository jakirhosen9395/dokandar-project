package com.dokandar.b2b.app;

import com.dokandar.b2b.clients.FleetClients;
import com.dokandar.b2b.config.B2bProps;
import com.dokandar.b2b.domain.Margin;
import com.dokandar.b2b.domain.TradeIds;
import com.dokandar.b2b.domain.TradeRules;
import com.dokandar.b2b.domain.TradeStatus;
import com.dokandar.b2b.store.EligibilityStore;
import com.dokandar.b2b.store.TradeStore;
import com.dokandar.platform.Errors;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * TradeOrder commands (Domain-Model ctx #7). KYC gates: seller BUSINESS, buyer FULL or
 * BUSINESS (DM aggregate table), enforced against the local eligibility projection (R7
 * conformist). Margin is computed synchronously by the margin domain service. Outbound
 * HTTP (inventory reserve, custody verification) happens ONLY in prepare phases — never
 * inside a transaction. Finance is reached exclusively via events (R2/ADR-004).
 */
@Service
public class TradeService {
    private static final Logger log = LoggerFactory.getLogger(TradeService.class);
    private static final Set<String> SELLER_TIERS = Set.of("BUSINESS");
    private static final Set<String> BUYER_TIERS = Set.of("FULL", "BUSINESS");

    public record PreparedCreate(String trd, String sellerDid, String buyerDid,
                                 List<Map<String, Object>> items, TradeRules.Terms terms,
                                 long totalPoisha, long marginRequirementPoisha, long createdAt) {}

    private final TradeStore trades;
    private final EligibilityStore eligibility;
    private final EventFactory events;
    private final FleetClients clients;
    private final B2bProps props;
    private final ObjectMapper mapper;

    public TradeService(TradeStore trades, EligibilityStore eligibility, EventFactory events,
                        FleetClients clients, B2bProps props, ObjectMapper mapper) {
        this.trades = trades;
        this.eligibility = eligibility;
        this.events = events;
        this.clients = clients;
        this.props = props;
        this.mapper = mapper;
    }

    /** CreateTradeOrder phase 1 (no tx): validation, KYC gates, margin, strong-local reserves. */
    public PreparedCreate prepareCreate(JsonNode body, String idemKey) {
        long now = System.currentTimeMillis();
        String sellerDid = text(body, "sellerDid");
        String buyerDid = text(body, "buyerDid");
        if (!TradeIds.isDid(sellerDid) || !TradeIds.isDid(buyerDid))
            throw new Errors.ValidationException(Errors.errorCode("b2b", "validation", "did"),
                "sellerDid and buyerDid must be did:dokandar DIDs");
        if (sellerDid.equals(buyerDid))
            throw new Errors.ValidationException(Errors.errorCode("b2b", "validation", "parties"),
                "buyer and seller must differ");
        requireEligible(sellerDid, "seller", SELLER_TIERS);
        requireEligible(buyerDid, "buyer", BUYER_TIERS);
        List<TradeRules.Item> items = TradeRules.parseItems(body.get("items"));
        TradeRules.Terms terms = TradeRules.parseTerms(body.get("contractTerms"), now);
        long total = TradeRules.totalPoisha(items);
        long margin = Margin.requirementPoisha(total, props.marginRateBps());
        List<Map<String, Object>> withReservations = reserveAll(items, sellerDid, idemKey);
        return new PreparedCreate(TradeIds.newTrd(), sellerDid, buyerDid, withReservations,
            terms, total, margin, now);
    }

    /** CreateTradeOrder phase 2 (tx-only): NEW -> MARGIN_PENDING + TradeOrderCreated.v1. */
    public Views.TradeView commitCreate(PreparedCreate p) {
        JsonNode itemsJson = mapper.valueToTree(p.items());
        JsonNode termsJson = mapper.valueToTree(p.terms());
        try {
            trades.insert(p.trd(), p.sellerDid(), p.buyerDid(), toJson(itemsJson),
                toJson(termsJson), p.totalPoisha(), p.marginRequirementPoisha(),
                p.createdAt());
            events.tradeOrderCreated(p.trd(), p.sellerDid(), p.buyerDid(), stripReservations(itemsJson),
                termsJson, p.totalPoisha(), p.marginRequirementPoisha(), p.createdAt());
        } catch (RuntimeException e) {
            releaseReservations(p.items());
            throw e;
        }
        return get(p.trd());
    }

    /** PostMargin: MARGIN_PENDING -> MARGIN_POSTED (amount >= requirement) + MarginPosted.v1. */
    @Transactional
    public Views.TradeView postMargin(String trd, long amountPoisha) {
        long now = System.currentTimeMillis();
        TradeStore.TradeRow row = lock(trd);
        requireStatus(row, TradeStatus.MARGIN_PENDING, "post-margin");
        if (amountPoisha < row.marginRequirementPoisha())
            throw new Errors.BusinessException(Errors.errorCode("b2b", "trade", "margin_insufficient"),
                "posted margin " + amountPoisha + " is below the requirement "
                    + row.marginRequirementPoisha());
        mustTransition(trades.transition(trd, "MARGIN_PENDING", "MARGIN_POSTED",
            amountPoisha, null, null, now), trd, "MARGIN_POSTED");
        events.marginPosted(trd, amountPoisha, now);
        return get(trd);
    }

    /**
     * ActivateTrade: MARGIN_POSTED -> ACTIVE. The DM specifies it is "called by the B2B
     * domain service after PostMargin processed" — the controller invokes it right after the
     * margin transaction commits. Idempotent: an already-ACTIVE trade is returned as-is
     * (recovery calls replay safely). The registry gives b2b no finance EscrowCreated
     * subscription, so activation cannot be escrow-gated (recorded NEEDS-INFO).
     */
    @Transactional
    public Views.TradeView activate(String trd) {
        long now = System.currentTimeMillis();
        TradeStore.TradeRow row = lock(trd);
        if (TradeStatus.valueOf(row.status()) == TradeStatus.ACTIVE) return get(trd);
        requireStatus(row, TradeStatus.MARGIN_POSTED, "activate");
        mustTransition(trades.transition(trd, "MARGIN_POSTED", "ACTIVE", null, null, null, now),
            trd, "ACTIVE");
        events.tradeActivated(trd, now);
        return get(trd);
    }

    /** InitiateSettlement phase 1 (no tx): custody-verify every ppid (transferred to buyer). */
    public List<String> prepareSettlement(String trd, JsonNode rawPpids) {
        if (rawPpids == null || !rawPpids.isArray() || rawPpids.isEmpty())
            throw new Errors.ValidationException(Errors.errorCode("b2b", "validation", "ppids"),
                "ppids[] is required — settlement is initiated for custody-transferred lots");
        TradeStore.TradeRow row = trades.find(trd).orElseThrow(this::notFound);
        requireStatus(row, TradeStatus.ACTIVE, "initiate-settlement");
        Set<String> tradeGpids = new HashSet<>();
        for (JsonNode it : parse(row.itemsJson())) tradeGpids.add(it.path("gpid").asText());
        List<String> ppids = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        for (JsonNode n : rawPpids) {
            String ppid = n.isTextual() ? n.asText() : null;
            if (!TradeIds.isPpid(ppid) || !seen.add(ppid))
                throw new Errors.ValidationException(Errors.errorCode("b2b", "validation", "ppids"),
                    "ppids must be unique PP- prefixed ids");
            if (clients.custodyEnabled()) {
                FleetClients.Passport pass = clients.passport(ppid);
                if (!row.buyerDid().equals(pass.currentHolder()))
                    throw new Errors.BusinessException(
                        Errors.errorCode("b2b", "trade", "custody_not_transferred"),
                        ppid + " is not held by the buyer — custody transfer is the settlement precondition");
                if (pass.gpid() != null && !tradeGpids.contains(pass.gpid()))
                    throw new Errors.BusinessException(
                        Errors.errorCode("b2b", "trade", "ppid_gpid_mismatch"),
                        ppid + " references a GPID outside this trade");
            }
            ppids.add(ppid);
        }
        return List.copyOf(ppids);
    }

    /** InitiateSettlement phase 2 (tx-only): ACTIVE -> SETTLEMENT_PENDING + SettlementInitiated.v1. */
    public Views.TradeView commitSettlement(String trd, List<String> ppids) {
        long now = System.currentTimeMillis();
        TradeStore.TradeRow row = lock(trd);
        requireStatus(row, TradeStatus.ACTIVE, "initiate-settlement");
        mustTransition(trades.transition(trd, "ACTIVE", "SETTLEMENT_PENDING", null, null,
            toJson(ppids), now), trd, "SETTLEMENT_PENDING");
        events.settlementInitiated(trd, ppids, now);
        return get(trd);
    }

    /**
     * CompleteTrade (Saga 4 step 3): precondition EscrowReleased.v1 with referenceType==TRADE
     * and referenceId==trd — the listener filters straight off the payload (M-NEW-3).
     * Idempotent: SETTLED is a no-op so escrow-release replays ack cleanly.
     */
    @Transactional
    public void completeTrade(String trd, String evidence) {
        long now = System.currentTimeMillis();
        TradeStore.TradeRow row = lock(trd);
        if (TradeStatus.valueOf(row.status()) == TradeStatus.SETTLED) return;
        requireStatus(row, TradeStatus.SETTLEMENT_PENDING, "complete");
        mustTransition(trades.transition(trd, "SETTLEMENT_PENDING", "SETTLED", null, evidence, null, now),
            trd, "SETTLED");
        events.tradeSettled(trd, now);
    }

    /** DisputeTrade: ACTIVE|SETTLEMENT_PENDING -> DISPUTED (no auto-exit — future ADR). */
    @Transactional
    public Views.TradeView dispute(String trd, String reason, String disputedBy) {
        long now = System.currentTimeMillis();
        TradeStore.TradeRow row = lock(trd);
        TradeStatus cur = TradeStatus.valueOf(row.status());
        if (cur == TradeStatus.DISPUTED) return get(trd); // idempotent for directive replays
        if (!cur.canTransition(TradeStatus.DISPUTED))
            throw new Errors.BusinessException(Errors.errorCode("b2b", "trade", "not_disputable"),
                "trade is " + cur + " — disputes require ACTIVE or SETTLEMENT_PENDING");
        mustTransition(trades.transition(trd, cur.name(), "DISPUTED", null,
            reason == null || reason.isBlank() ? "UNSPECIFIED" : reason, null, now), trd, "DISPUTED");
        events.tradeDisputed(trd, reason, disputedBy, now);
        return get(trd);
    }

    /** CancelTrade: DRAFT|MARGIN_PENDING -> CANCELLED (margin escrow never exists yet). */
    @Transactional
    public Views.TradeView cancel(String trd, String reason) {
        long now = System.currentTimeMillis();
        TradeStore.TradeRow row = lock(trd);
        TradeStatus cur = TradeStatus.valueOf(row.status());
        if (!cur.canTransition(TradeStatus.CANCELLED))
            throw new Errors.BusinessException(Errors.errorCode("b2b", "trade", "not_cancellable"),
                "trade is " + cur + " — cancellation is only allowed before margin posting");
        mustTransition(trades.transition(trd, cur.name(), "CANCELLED", null,
            reason == null || reason.isBlank() ? "UNSPECIFIED" : reason, null, now), trd, "CANCELLED");
        events.tradeCancelled(trd, reason, now);
        return get(trd);
    }

    /**
     * Post-commit reservation settlement: "release" compensates a cancel; "confirm" consumes
     * the holds after settlement (the stock itself moves via the custody event — the
     * reservation is bookkeeping, same split as b2c's post-delivery settleReservations).
     * Runs OUTSIDE any transaction; the inventory side is idempotent.
     */
    public void settleTradeReservations(String trd, boolean confirm) {
        TradeStore.TradeRow row = trades.find(trd).orElse(null);
        if (row == null || !clients.inventoryEnabled()) return;
        for (JsonNode it : parse(row.itemsJson())) {
            String resId = it.path("reservationId").asText(null);
            if (resId == null || resId.isBlank()) continue;
            if (confirm) clients.confirm(resId);
            else clients.release(resId);
        }
    }

    @Transactional(readOnly = true)
    public Views.TradeView get(String trd) {
        return Views.trade(trades.find(trd).orElseThrow(this::notFound), mapper);
    }

    private void requireEligible(String did, String role, Set<String> tiers) {
        EligibilityStore.Eligibility e = eligibility.find(did).orElse(null);
        if (e == null || !tiers.contains(e.kycTier()))
            throw new Errors.BusinessException(Errors.errorCode("b2b", "trade", role + "_kyc"),
                role + " KYC tier must be one of " + tiers + " (FR gate, DM ctx #7)");
        if (e.suspended() || e.held())
            throw new Errors.BusinessException(Errors.errorCode("b2b", "trade", role + "_blocked"),
                role + " is suspended or under an enforcement hold");
    }

    private List<Map<String, Object>> reserveAll(List<TradeRules.Item> items, String sellerDid,
                                                 String idemKey) {
        List<Map<String, Object>> out = new ArrayList<>();
        try {
            for (TradeRules.Item it : items) {
                Map<String, Object> m = new LinkedHashMap<>();
                m.put("lineId", it.lineId());
                m.put("gpid", it.gpid());
                m.put("ppids", it.ppids());
                m.put("quantity", it.quantity());
                m.put("unit", it.unit());
                m.put("agreedUnitPricePoisha", it.agreedUnitPricePoisha());
                if (clients.inventoryEnabled())
                    m.put("reservationId", clients.reserve(idemKey + ":" + it.lineId(),
                        it.gpid(), sellerDid, it.quantity()));
                out.add(m);
            }
        } catch (RuntimeException e) {
            releaseReservations(out);
            throw e;
        }
        return out;
    }

    private void releaseReservations(List<Map<String, Object>> items) {
        for (Map<String, Object> m : items) {
            Object resId = m.get("reservationId");
            if (resId instanceof String s && !s.isBlank()) clients.release(s);
        }
    }

    /** The Published-Language TradeOrderCreated payload carries DM fields only. */
    private JsonNode stripReservations(JsonNode items) {
        var copy = items.deepCopy();
        for (JsonNode it : copy)
            if (it.isObject()) ((com.fasterxml.jackson.databind.node.ObjectNode) it).remove("reservationId");
        return copy;
    }

    private TradeStore.TradeRow lock(String trd) {
        return trades.lock(trd).orElseThrow(this::notFound);
    }

    private void requireStatus(TradeStore.TradeRow row, TradeStatus expected, String action) {
        if (TradeStatus.valueOf(row.status()) != expected)
            throw new Errors.BusinessException(Errors.errorCode("b2b", "trade", "bad_state"),
                action + " requires " + expected + " but trade is " + row.status());
    }

    private void mustTransition(boolean ok, String trd, String to) {
        if (!ok)
            throw new Errors.BusinessException(Errors.errorCode("b2b", "trade", "conflict"),
                "concurrent update lost the " + to + " transition for " + trd);
    }

    private Errors.DokandarException notFound() {
        return new Errors.DokandarException(Errors.errorCode("b2b", "trade", "not_found"),
            "no such trade order", 404, null);
    }

    private JsonNode parse(String json) {
        try {
            return mapper.readTree(json == null ? "[]" : json);
        } catch (Exception e) {
            log.error("stored items JSON unreadable", e);
            return mapper.createArrayNode();
        }
    }

    private String toJson(Object o) {
        try {
            return mapper.writeValueAsString(o);
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    private static String text(JsonNode n, String field) {
        JsonNode v = n == null ? null : n.get(field);
        return v != null && v.isTextual() && !v.asText().isBlank() ? v.asText() : null;
    }
}
