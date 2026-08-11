package com.dokandar.finance.app;

import com.dokandar.finance.domain.FinanceIds;
import com.dokandar.finance.store.OutboxStore;
import com.dokandar.platform.Topics;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.LinkedHashMap;
import java.util.Map;
import org.springframework.stereotype.Component;

/**
 * Builds finance Published-Language events into the transactional outbox.
 * Every topic is checked against the frozen registry (producer must be context 8 — R6);
 * payloads carry canonical IDs only, never PII (no mobile numbers, no names).
 */
@Component
public class EventFactory {
    private static final int FINANCE_CONTEXT = 8;

    private final OutboxStore outbox;
    private final ObjectMapper mapper;

    public EventFactory(OutboxStore outbox, ObjectMapper mapper) {
        this.outbox = outbox;
        this.mapper = mapper;
    }

    public void walletCreated(String wlt, String ownerDid, long now) {
        emit(Topics.FINANCE_WALLET_WALLET_CREATED_V1, wlt, Map.of("wlt", wlt, "ownerDid", ownerDid), now);
    }

    public void walletCredited(String wlt, String txnId, long amountPoisha, String referenceId,
                               String referenceType, long now) {
        emit(Topics.FINANCE_WALLET_WALLET_CREDITED_V1, wlt, Map.of(
            "wlt", wlt, "txnId", txnId, "amountPoisha", amountPoisha,
            "referenceId", referenceId, "referenceType", referenceType), now);
    }

    public void walletDebited(String wlt, String txnId, long amountPoisha, String referenceId,
                              String referenceType, long now) {
        emit(Topics.FINANCE_WALLET_WALLET_DEBITED_V1, wlt, Map.of(
            "wlt", wlt, "txnId", txnId, "amountPoisha", amountPoisha,
            "referenceId", referenceId, "referenceType", referenceType), now);
    }

    public void walletFrozen(String wlt, String reason, String freezeRef, long now) {
        Map<String, Object> p = new LinkedHashMap<>();
        p.put("wlt", wlt);
        p.put("reason", reason == null ? "UNSPECIFIED" : reason);
        if (freezeRef != null) p.put("freezeRef", freezeRef);
        emit(Topics.FINANCE_WALLET_WALLET_FROZEN_V1, wlt, p, now);
    }

    /** No mobile number in the payload — E.164 phones are PII; consumers resolve via Identity OHS. */
    public void mfsAccountRegistered(String wlt, String mfsId, String provider, long now) {
        emit(Topics.FINANCE_WALLET_MFSACCOUNT_REGISTERED_V1, wlt,
            Map.of("wlt", wlt, "mfsId", mfsId, "provider", provider), now);
    }

    public void mfsAccountVerified(String wlt, String mfsId, long now) {
        emit(Topics.FINANCE_WALLET_MFSACCOUNT_VERIFIED_V1, wlt, Map.of("wlt", wlt, "mfsId", mfsId), now);
    }

    public void escrowCreated(String esc, String referenceId, String referenceType, String buyerWlt,
                              String sellerWlt, long amountPoisha, long now) {
        emit(Topics.FINANCE_ESCROW_ESCROW_CREATED_V1, esc, Map.of(
            "esc", esc, "referenceId", referenceId, "referenceType", referenceType,
            "buyerWlt", buyerWlt, "sellerWlt", sellerWlt, "amountPoisha", amountPoisha), now);
    }

    public void escrowReleased(String esc, String referenceId, String referenceType,
                               long coolingOffExpiresAt, long now) {
        emit(Topics.FINANCE_ESCROW_ESCROW_RELEASED_V1, esc, Map.of(
            "esc", esc, "referenceId", referenceId, "referenceType", referenceType,
            "coolingOffExpiresAt", coolingOffExpiresAt), now);
    }

    public void settlementHoldReleased(String esc, String referenceType, long now) {
        emit(Topics.FINANCE_ESCROW_SETTLEMENT_HOLD_RELEASED_V1, esc,
            Map.of("esc", esc, "referenceType", referenceType), now);
    }

    public void escrowReversed(String esc, String referenceId, String referenceType, String reason, long now) {
        emit(Topics.FINANCE_ESCROW_ESCROW_REVERSED_V1, esc, Map.of(
            "esc", esc, "referenceId", referenceId, "referenceType", referenceType,
            "reason", reason == null ? "UNSPECIFIED" : reason), now);
    }

    private void emit(String topic, String partitionKey, Map<String, Object> fields, long now) {
        Topics.TopicMeta meta = Topics.topicMeta(topic);
        if (meta.producer() != FINANCE_CONTEXT)
            throw new IllegalArgumentException("R6 violation: finance may not produce " + topic);
        String eventId = FinanceIds.newEventId();
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
