package com.dokandar.b2b.app;

import com.dokandar.b2b.domain.TradeIds;
import com.dokandar.b2b.store.OutboxStore;
import com.dokandar.platform.Topics;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.springframework.stereotype.Component;

/**
 * Builds the seven b2b.tradeorder.* Published-Language events into the transactional
 * outbox. Every topic is checked against the frozen registry (producer must be context 7 —
 * R6); payloads carry canonical IDs only, never PII. Partition key is always the TRD
 * (per-aggregate ordering, DM event catalog).
 */
@Component
public class EventFactory {
    private static final int B2B_CONTEXT = 7;

    private final OutboxStore outbox;
    private final ObjectMapper mapper;

    public EventFactory(OutboxStore outbox, ObjectMapper mapper) {
        this.outbox = outbox;
        this.mapper = mapper;
    }

    public void tradeOrderCreated(String trd, String sellerDid, String buyerDid, JsonNode items,
                                  JsonNode contractTerms, long totalAmountPoisha,
                                  long marginRequirementPoisha, long now) {
        Map<String, Object> p = new LinkedHashMap<>();
        p.put("trd", trd);
        p.put("sellerDid", sellerDid);
        p.put("buyerDid", buyerDid);
        p.put("items", items);
        p.put("contractTerms", contractTerms);
        p.put("totalAmountPoisha", totalAmountPoisha);
        p.put("marginRequirementPoisha", marginRequirementPoisha);
        emit(Topics.B2B_TRADEORDER_TRADE_ORDER_CREATED_V1, trd, p, now);
    }

    public void marginPosted(String trd, long amountPoisha, long now) {
        emit(Topics.B2B_TRADEORDER_MARGIN_POSTED_V1, trd,
            Map.of("trd", trd, "amountPoisha", amountPoisha, "postedAt", now), now);
    }

    public void tradeActivated(String trd, long now) {
        emit(Topics.B2B_TRADEORDER_TRADE_ACTIVATED_V1, trd,
            Map.of("trd", trd, "activatedAt", now), now);
    }

    public void settlementInitiated(String trd, List<String> ppids, long now) {
        emit(Topics.B2B_TRADEORDER_SETTLEMENT_INITIATED_V1, trd,
            Map.of("trd", trd, "ppids", ppids, "initiatedAt", now), now);
    }

    public void tradeSettled(String trd, long now) {
        emit(Topics.B2B_TRADEORDER_TRADE_SETTLED_V1, trd,
            Map.of("trd", trd, "settledAt", now), now);
    }

    public void tradeDisputed(String trd, String reason, String disputedBy, long now) {
        emit(Topics.B2B_TRADEORDER_TRADE_DISPUTED_V1, trd, Map.of(
            "trd", trd, "reason", reason == null ? "UNSPECIFIED" : reason,
            "disputedBy", disputedBy == null ? "UNSPECIFIED" : disputedBy, "disputedAt", now), now);
    }

    public void tradeCancelled(String trd, String reason, long now) {
        emit(Topics.B2B_TRADEORDER_TRADE_CANCELLED_V1, trd, Map.of(
            "trd", trd, "reason", reason == null ? "UNSPECIFIED" : reason, "cancelledAt", now), now);
    }

    private void emit(String topic, String partitionKey, Map<String, Object> fields, long now) {
        Topics.TopicMeta meta = Topics.topicMeta(topic);
        if (meta.producer() != B2B_CONTEXT)
            throw new IllegalArgumentException("R6 violation: b2b may not produce " + topic);
        String eventId = TradeIds.newEventId();
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("eventId", eventId);
        payload.put("occurredAt", now);
        payload.putAll(fields);
        try {
            outbox.insert(eventId, topic, partitionKey, mapper.writeValueAsString(payload), now);
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("event payload serialization failed for " + topic, e);
        }
    }
}
