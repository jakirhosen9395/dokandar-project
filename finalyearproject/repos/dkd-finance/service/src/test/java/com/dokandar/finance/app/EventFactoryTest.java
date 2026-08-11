package com.dokandar.finance.app;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;

import com.dokandar.finance.store.OutboxStore;
import com.dokandar.platform.Topics;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

class EventFactoryTest {

    private OutboxStore outbox;
    private EventFactory events;

    @BeforeEach
    void setUp() {
        outbox = mock(OutboxStore.class);
        events = new EventFactory(outbox, new ObjectMapper());
    }

    @Test
    void walletEventsUseRegisteredTopicKeyedByWlt() {
        events.walletCredited("WLT-1", "TXN-1", 40000, "REF", "DEPOSIT", 123L);
        var topic = ArgumentCaptor.forClass(String.class);
        var key = ArgumentCaptor.forClass(String.class);
        var payload = ArgumentCaptor.forClass(String.class);
        verify(outbox).insert(anyString(), topic.capture(), key.capture(), payload.capture(), anyLong());
        assertEquals(Topics.FINANCE_WALLET_WALLET_CREDITED_V1, topic.getValue());
        assertEquals(8, Topics.topicMeta(topic.getValue()).producer());
        assertEquals("WLT-1", key.getValue());
        assertTrue(payload.getValue().contains("\"amountPoisha\":40000"));
        assertTrue(payload.getValue().contains("\"eventId\""));
        assertTrue(payload.getValue().contains("\"occurredAt\":123"));
    }

    @Test
    void escrowEventsAreKeyedByEsc() {
        events.escrowReversed("ESC-9", "ORD-1", "ORDER", "ORDER_CANCELLED", 5L);
        var topic = ArgumentCaptor.forClass(String.class);
        var key = ArgumentCaptor.forClass(String.class);
        verify(outbox).insert(anyString(), topic.capture(), key.capture(), anyString(), anyLong());
        assertEquals(Topics.FINANCE_ESCROW_ESCROW_REVERSED_V1, topic.getValue());
        assertEquals("ESC-9", key.getValue());
    }

    @Test
    void mfsRegistrationPayloadCarriesNoMobileNumber() {
        events.mfsAccountRegistered("WLT-1", "MFS-1", "bkash", 1L);
        var payload = ArgumentCaptor.forClass(String.class);
        verify(outbox).insert(anyString(), anyString(), anyString(), payload.capture(), anyLong());
        assertFalse(payload.getValue().contains("+880"), "PII must never enter a spine payload");
        assertFalse(payload.getValue().toLowerCase().contains("mobile"));
        assertTrue(payload.getValue().contains("\"mfsId\":\"MFS-1\""));
    }
}
