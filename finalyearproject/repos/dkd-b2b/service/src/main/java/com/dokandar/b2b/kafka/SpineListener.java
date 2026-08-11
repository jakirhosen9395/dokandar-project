package com.dokandar.b2b.kafka;

import com.dokandar.b2b.app.TradeService;
import com.dokandar.b2b.store.EligibilityStore;
import com.dokandar.b2b.store.InboxStore;
import com.dokandar.b2b.store.TradeStore;
import com.dokandar.platform.Errors;
import com.dokandar.platform.Topics;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.micrometer.core.instrument.MeterRegistry;
import java.nio.charset.StandardCharsets;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.common.header.Header;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * B2B's consumer over the registry topics with consumer=7. Eligibility projections are
 * event-time guarded (cross-topic replay order is arbitrary). Saga 4: EscrowReleased with
 * referenceType==TRADE completes the trade straight off the payload (M-NEW-3 — no local
 * escrow projection). Inbox dedup happens in the SAME transaction as the state change.
 * Business-final rejections ack+skip; infrastructure errors propagate and park (KafkaConfig).
 */
@Component
public class SpineListener {
    private static final Logger log = LoggerFactory.getLogger(SpineListener.class);

    private final InboxStore inbox;
    private final TradeService tradeService;
    private final EligibilityStore eligibility;
    private final TradeStore trades;
    private final TransactionTemplate tx;
    private final ObjectMapper mapper;
    private final MeterRegistry metrics;

    public SpineListener(InboxStore inbox, TradeService tradeService, EligibilityStore eligibility,
                         TradeStore trades, TransactionTemplate tx, ObjectMapper mapper,
                         MeterRegistry metrics) {
        this.inbox = inbox;
        this.tradeService = tradeService;
        this.eligibility = eligibility;
        this.trades = trades;
        this.tx = tx;
        this.mapper = mapper;
        this.metrics = metrics;
    }

    @KafkaListener(topics = {
        Topics.IDENTITY_PARTY_KYCAPPROVED_V1,
        Topics.IDENTITY_PARTY_KYCTIER_CHANGED_V1,
        Topics.IDENTITY_PARTY_PARTY_SUSPENDED_V1,
        Topics.IDENTITY_PARTY_PARTY_REACTIVATED_V1,
        Topics.FRAUD_ENFORCEMENT_ACCOUNT_HELD_V1,
        Topics.FRAUD_ENFORCEMENT_ACCOUNT_HOLD_RELEASED_V1,
        Topics.CATALOG_PRODUCT_PRODUCT_DEPRECATED_V1,
        Topics.CUSTODY_PASSPORT_PRODUCT_RECALLED_V1,
        Topics.FINANCE_ESCROW_ESCROW_RELEASED_V1,
        Topics.GOVERNMENT_OVERSIGHT_TRADE_FREEZE_DIRECTIVE_V1})
    public void onRecord(ConsumerRecord<String, String> rec) {
        String eventId = eventId(rec);
        JsonNode payload = parse(rec.value());
        java.util.concurrent.atomic.AtomicBoolean fresh = new java.util.concurrent.atomic.AtomicBoolean(false);
        try {
            tx.executeWithoutResult(status -> {
                if (!inbox.tryMark(eventId, rec.topic(), System.currentTimeMillis())) return; // duplicate
                fresh.set(true);
                dispatch(rec.topic(), payload, eventId);
            });
            metrics.counter("b2b_spine_processed_total", "topic", rec.topic()).increment();
            // Post-commit, outside any tx, FIRST delivery only (reviewer M-1): a settled trade
            // consumes its inventory holds (stock moved via the custody event; bookkeeping).
            if (fresh.get() && Topics.FINANCE_ESCROW_ESCROW_RELEASED_V1.equals(rec.topic())
                    && "TRADE".equals(text(payload, "referenceType"))) {
                String trd = text(payload, "referenceId");
                if (trd != null) tradeService.settleTradeReservations(trd, true);
            }
        } catch (Errors.DokandarException businessFinal) {
            // Retrying cannot change a business verdict; ack and record the skip.
            log.warn("business-final skip on {} event {}: {}", rec.topic(), eventId, businessFinal.getMessage());
            metrics.counter("b2b_spine_skipped_total", "topic", rec.topic()).increment();
        }
    }

    private void dispatch(String topic, JsonNode p, String eventId) {
        long occurredAt = occurredAt(p);
        switch (topic) {
            case Topics.IDENTITY_PARTY_KYCAPPROVED_V1, Topics.IDENTITY_PARTY_KYCTIER_CHANGED_V1 -> {
                String did = text(p, "did", "Did", "partyDid");
                String tier = text(p, "newTier", "NewTier", "tier", "Tier");
                if (did == null || tier == null) { skip(topic, "no did/tier"); return; }
                eligibility.upsertTier(did, tier, occurredAt);
            }
            case Topics.IDENTITY_PARTY_PARTY_SUSPENDED_V1 -> {
                String did = text(p, "did", "Did", "partyDid");
                if (did == null) { skip(topic, "no did"); return; }
                eligibility.upsertSuspended(did, true, occurredAt);
            }
            case Topics.IDENTITY_PARTY_PARTY_REACTIVATED_V1 -> {
                String did = text(p, "did", "Did", "partyDid");
                if (did == null) { skip(topic, "no did"); return; }
                eligibility.upsertSuspended(did, false, occurredAt);
            }
            case Topics.FRAUD_ENFORCEMENT_ACCOUNT_HELD_V1 -> {
                String did = text(p, "subjectDid", "did", "targetDid"); // registry payload = subjectDid
                if (did == null) { skip(topic, "no did"); return; }
                eligibility.upsertHeld(did, true, occurredAt);
            }
            case Topics.FRAUD_ENFORCEMENT_ACCOUNT_HOLD_RELEASED_V1 -> {
                String did = text(p, "subjectDid", "did", "targetDid"); // registry payload = subjectDid
                if (did == null) { skip(topic, "no did"); return; }
                eligibility.upsertHeld(did, false, occurredAt);
            }
            case Topics.CATALOG_PRODUCT_PRODUCT_DEPRECATED_V1,
                 Topics.CUSTODY_PASSPORT_PRODUCT_RECALLED_V1 -> {
                // BR-017: a recall freezes affected open positions — the exact #7 action is
                // NEEDS-INFO, so the advisory recall_flag is raised, never a state transition.
                String gpid = text(p, "gpid", "GPID");
                if (gpid == null) { skip(topic, "no gpid"); return; }
                int flagged = trades.flagRecallByGpid(gpid, System.currentTimeMillis());
                if (flagged > 0) log.warn("recall/deprecation of {} flagged {} open trades", gpid, flagged);
            }
            case Topics.FINANCE_ESCROW_ESCROW_RELEASED_V1 -> {
                // Saga 4 step 3: only TRADE escrows complete a trade; ORDER escrows are b2c's.
                String refType = text(p, "referenceType");
                String trd = text(p, "referenceId");
                if (!"TRADE".equals(refType) || trd == null) return;
                tradeService.completeTrade(trd, "finance:EscrowReleased:" + eventId);
            }
            case Topics.GOVERNMENT_OVERSIGHT_TRADE_FREEZE_DIRECTIVE_V1 -> {
                // DM: "#7 freezes or disputes trade". No FROZEN status exists in the enum, so
                // the directive maps to DisputeTrade (no-auto-exit) — decision in BUILD-LOG.
                String trd = text(p, "trd");
                String directiveId = text(p, "directiveId");
                if (trd == null) { skip(topic, "no trd"); return; }
                tradeService.dispute(trd,
                    "GOV_FREEZE:" + (directiveId != null ? directiveId : eventId),
                    text(p, "issuedBy", "authority"));
            }
            default -> skip(topic, "mapping NEEDS-INFO");
        }
    }

    private void skip(String topic, String why) {
        log.info("spine skip {}: {}", topic, why);
        metrics.counter("b2b_spine_unmapped_total", "topic", topic).increment();
    }

    private String eventId(ConsumerRecord<String, String> rec) {
        Header h = rec.headers().lastHeader("event_id");
        if (h != null) return new String(h.value(), StandardCharsets.UTF_8);
        JsonNode p = parse(rec.value());
        String fromPayload = text(p, "eventId", "event_id");
        if (fromPayload != null) return fromPayload;
        return rec.topic() + "/" + rec.partition() + "/" + rec.offset();
    }

    private JsonNode parse(String value) {
        try {
            return mapper.readTree(value == null ? "{}" : value);
        } catch (Exception e) {
            return mapper.createObjectNode();
        }
    }

    private long occurredAt(JsonNode p) {
        for (String n : new String[]{"occurredAt", "OccurredAt", "changedAt", "ChangedAt",
                "approvedAt", "ApprovedAt", "heldAt", "releasedAt"}) {
            JsonNode v = p.get(n);
            if (v != null && v.canConvertToLong() && !v.isFloatingPointNumber()) return v.asLong();
        }
        return System.currentTimeMillis();
    }

    private static String text(JsonNode p, String... names) {
        for (String n : names) {
            JsonNode v = p.get(n);
            if (v != null && v.isTextual() && !v.asText().isBlank()) return v.asText();
        }
        return null;
    }
}
