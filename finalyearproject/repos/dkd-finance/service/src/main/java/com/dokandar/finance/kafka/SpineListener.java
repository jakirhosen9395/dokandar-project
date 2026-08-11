package com.dokandar.finance.kafka;

import com.dokandar.finance.app.EscrowService;
import com.dokandar.finance.app.WalletService;
import com.dokandar.finance.store.InboxStore;
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
 * Finance's consumer over every registry topic with consumer=8. Actionable topics get real
 * handlers; the rest are inbox-ack + skip with a metric (payload mapping NEEDS-INFO in the
 * frozen contracts — never invented, P2). Inbox dedup happens in the SAME transaction as the
 * state change. Business-final rejections ack+skip; infrastructure errors propagate and park
 * the partition (KafkaConfig).
 */
@Component
public class SpineListener {
    private static final Logger log = LoggerFactory.getLogger(SpineListener.class);

    private final InboxStore inbox;
    private final WalletService walletService;
    private final EscrowService escrowService;
    private final TransactionTemplate tx;
    private final ObjectMapper mapper;
    private final MeterRegistry metrics;
    private final DlqGate dlq;

    public SpineListener(InboxStore inbox, WalletService walletService, EscrowService escrowService,
                         TransactionTemplate tx, ObjectMapper mapper, MeterRegistry metrics, DlqGate dlq) {
        this.inbox = inbox;
        this.walletService = walletService;
        this.escrowService = escrowService;
        this.tx = tx;
        this.mapper = mapper;
        this.metrics = metrics;
        this.dlq = dlq;
    }

    @KafkaListener(topics = {
        Topics.IDENTITY_PARTY_PARTY_REGISTERED_V1,
        Topics.IDENTITY_PARTY_PARTY_SUSPENDED_V1,
        Topics.IDENTITY_PARTY_PARTY_REACTIVATED_V1,
        Topics.IDENTITY_PARTY_KYCAPPROVED_V1,
        Topics.IDENTITY_PARTY_KYCTIER_CHANGED_V1,
        Topics.CUSTODY_PASSPORT_CUSTODY_TRANSFERRED_V1,
        Topics.B2C_ORDER_ORDER_PLACED_V1,
        Topics.B2C_ORDER_ORDER_DELIVERED_V1,
        Topics.B2C_ORDER_ORDER_CANCELLED_V1,
        Topics.B2B_TRADEORDER_TRADE_ORDER_CREATED_V1,
        Topics.B2B_TRADEORDER_MARGIN_POSTED_V1,
        Topics.B2B_TRADEORDER_TRADE_ACTIVATED_V1,
        Topics.B2B_TRADEORDER_SETTLEMENT_INITIATED_V1,
        Topics.B2B_TRADEORDER_TRADE_DISPUTED_V1,
        Topics.B2B_TRADEORDER_TRADE_CANCELLED_V1,
        Topics.LOGISTICS_SHIPMENT_DELIVERY_RECORDED_V1,
        Topics.LOGISTICS_SHIPMENT_SHIPMENT_CANCELLED_V1,
        Topics.FRAUD_ENFORCEMENT_ACCOUNT_HELD_V1,
        Topics.FRAUD_ENFORCEMENT_ACCOUNT_HOLD_RELEASED_V1,
        Topics.GOVERNMENT_OVERSIGHT_WALLET_FREEZE_DIRECTIVE_V1,
        Topics.PLATFORM_SCHEDULER_COOLING_OFF_EXPIRED_V1,
        Topics.PLATFORM_SCHEDULER_ESCROW_EXPIRED_V1})
    public void onRecord(ConsumerRecord<String, String> rec) {
        String eventId = eventId(rec);
        JsonNode payload = parse(rec.value());
        // Per-key park-and-freeze (SA-MSG-10, F-2c): if this aggregate key already has a parked poison
        // event, do NOT reprocess (which would just re-fail); re-park this event so it is preserved for
        // ordered replay after the key is unfrozen, and let other keys keep flowing.
        String aggKey = rec.key();
        if (dlq.isKeyParked(aggKey)) {
            dlq.park(eventId, rec.topic(), aggKey, rec.value() == null ? "{}" : rec.value(),
                "aggregate key frozen by a prior poison event");
            log.warn("frozen-key re-park on {} key {} event {}", rec.topic(), aggKey, eventId);
            metrics.counter("finance_spine_skipped_total", "topic", rec.topic()).increment();
            return;
        }
        try {
            tx.executeWithoutResult(status -> {
                if (!inbox.tryMark(eventId, rec.topic(), System.currentTimeMillis())) return; // duplicate
                dispatch(rec.topic(), payload, eventId);
            });
            metrics.counter("finance_spine_processed_total", "topic", rec.topic()).increment();
        } catch (Errors.DokandarException businessFinal) {
            // Retrying cannot change a business verdict; ack and record the skip.
            log.warn("business-final skip on {} event {}: {}", rec.topic(), eventId, businessFinal.getMessage());
            metrics.counter("finance_spine_skipped_total", "topic", rec.topic()).increment();
        }
    }

    private void dispatch(String topic, JsonNode p, String eventId) {
        switch (topic) {
            case Topics.IDENTITY_PARTY_PARTY_REGISTERED_V1 ->
                walletService.ensureWalletForParty(text(p, "did", "partyDid", "ownerDid"));
            case Topics.IDENTITY_PARTY_PARTY_SUSPENDED_V1 ->
                walletService.freezeByDid(text(p, "did", "partyDid"), "PARTY_SUSPENDED", eventId);
            case Topics.IDENTITY_PARTY_PARTY_REACTIVATED_V1 ->
                walletService.unfreezeByDid(text(p, "did", "partyDid"), eventId);
            case Topics.IDENTITY_PARTY_KYCAPPROVED_V1, Topics.IDENTITY_PARTY_KYCTIER_CHANGED_V1 ->
                // F-1: re-tier the wallet so BR-035 per-tier caps bind (was hardcoded V1 forever).
                walletService.setTierByDid(text(p, "did", "partyDid", "ownerDid"),
                    text(p, "newTier", "NewTier", "tier", "kycTier"));
            case Topics.B2C_ORDER_ORDER_PLACED_V1 -> {
                String orderId = text(p, "orderId", "ord");
                Long amount = amount(p);
                String buyerDid = text(p, "buyerDid");
                String sellerDid = text(p, "sellerDid");
                if (orderId == null || amount == null || buyerDid == null || sellerDid == null) {
                    skip(topic, "OrderPlaced payload missing orderId/buyerDid/sellerDid/amountPoisha");
                    return;
                }
                escrowService.onOrderPlaced(orderId, buyerDid, sellerDid, amount);
            }
            case Topics.B2C_ORDER_ORDER_DELIVERED_V1 -> {
                String orderId = text(p, "orderId", "ord");
                if (orderId == null) { skip(topic, "no orderId"); return; }
                escrowService.onOrderDelivered(orderId, "b2c:OrderDelivered:" + eventId);
            }
            case Topics.B2C_ORDER_ORDER_CANCELLED_V1 -> {
                String orderId = text(p, "orderId", "ord");
                if (orderId == null) { skip(topic, "no orderId"); return; }
                escrowService.onOrderCancelled(orderId, text(p, "reason"));
            }
            case Topics.LOGISTICS_SHIPMENT_DELIVERY_RECORDED_V1 -> {
                String orderId = text(p, "orderId", "ord");
                if (orderId == null) { skip(topic, "DeliveryRecorded without orderId"); return; }
                escrowService.onOrderDelivered(orderId, "logistics:DeliveryRecorded:" + eventId);
            }
            case Topics.PLATFORM_SCHEDULER_COOLING_OFF_EXPIRED_V1 -> {
                String esc = text(p, "esc", "escrowId");
                if (esc == null) { skip(topic, "no esc"); return; }
                escrowService.releaseHold(esc, true); // the scheduler is the clock authority
            }
            case Topics.PLATFORM_SCHEDULER_ESCROW_EXPIRED_V1 -> {
                String esc = text(p, "esc", "escrowId");
                if (esc == null) { skip(topic, "no esc"); return; }
                escrowService.expire(esc);
            }
            case Topics.GOVERNMENT_OVERSIGHT_WALLET_FREEZE_DIRECTIVE_V1 -> {
                String directiveId = text(p, "directiveId");
                String did = text(p, "ownerDid", "targetDid", "did"); // registry payload = ownerDid (M-NEW-1)
                if (did == null) { skip(topic, "WalletFreezeDirective without ownerDid"); return; }
                walletService.freezeByDid(did, "GOV_WALLET_FREEZE_DIRECTIVE", directiveId != null ? directiveId : eventId);
            }
            case Topics.FRAUD_ENFORCEMENT_ACCOUNT_HELD_V1 -> {
                String did = text(p, "subjectDid", "did", "targetDid"); // registry payload = subjectDid
                if (did == null) { skip(topic, "AccountHeld without did"); return; }
                walletService.freezeByDid(did, "FRAUD_ACCOUNT_HELD", text(p, "holdId") != null ? text(p, "holdId") : eventId);
            }
            case Topics.FRAUD_ENFORCEMENT_ACCOUNT_HOLD_RELEASED_V1 -> {
                String did = text(p, "subjectDid", "did", "targetDid"); // registry payload = subjectDid
                if (did == null) { skip(topic, "AccountHoldReleased without did"); return; }
                walletService.unfreezeByDid(did, eventId);
            }
            // ---- Saga 4 (B2B settlement) ----
            case Topics.B2B_TRADEORDER_TRADE_ORDER_CREATED_V1 -> {
                String trd = text(p, "trd");
                String buyerDid = text(p, "buyerDid");
                String sellerDid = text(p, "sellerDid");
                if (trd == null || buyerDid == null || sellerDid == null) {
                    skip(topic, "TradeOrderCreated payload missing trd/buyerDid/sellerDid");
                    return;
                }
                escrowService.onTradeOrderCreated(trd, buyerDid, sellerDid);
            }
            case Topics.B2B_TRADEORDER_MARGIN_POSTED_V1 -> {
                String trd = text(p, "trd");
                Long amount = amount(p);
                if (trd == null || amount == null) { skip(topic, "MarginPosted without trd/amountPoisha"); return; }
                escrowService.onMarginPosted(trd, amount);
            }
            case Topics.B2B_TRADEORDER_SETTLEMENT_INITIATED_V1 -> {
                String trd = text(p, "trd");
                if (trd == null) { skip(topic, "SettlementInitiated without trd"); return; }
                escrowService.onSettlementInitiated(trd, "b2b:SettlementInitiated:" + eventId);
            }
            // Registered consumer-8 topics whose finance-side mapping is NEEDS-INFO in the frozen
            // contracts (TradeActivated/Disputed/Cancelled carry no finance command): ack + skip.
            default -> skip(topic, "mapping NEEDS-INFO");
        }
    }

    private void skip(String topic, String why) {
        log.info("spine skip {}: {}", topic, why);
        metrics.counter("finance_spine_unmapped_total", "topic", topic).increment();
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

    private static String text(JsonNode p, String... names) {
        for (String n : names) {
            JsonNode v = p.get(n);
            if (v != null && v.isTextual() && !v.asText().isBlank()) return v.asText();
        }
        return null;
    }

    private static Long amount(JsonNode p) {
        for (String n : new String[]{"amountPoisha", "totalPoisha", "totalAmountPoisha"}) {
            JsonNode v = p.get(n);
            if (v != null && v.canConvertToLong() && !v.isFloatingPointNumber()) return v.asLong();
        }
        return null;
    }
}
