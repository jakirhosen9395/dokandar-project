package com.dokandar.b2b.app;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.dokandar.b2b.store.OutboxStore;
import com.dokandar.platform.Topics;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.Mockito;

/** R6 conformance: producer-7 guard, TRD partition keys, ID-only payloads with envelope. */
class EventFactoryTest {
    private final ObjectMapper mapper = new ObjectMapper();

    private record Emitted(String topic, String key, JsonNode payload) {}

    private List<Emitted> capture(java.util.function.Consumer<EventFactory> fn) {
        OutboxStore outbox = Mockito.mock(OutboxStore.class);
        EventFactory factory = new EventFactory(outbox, mapper);
        fn.accept(factory);
        ArgumentCaptor<String> topic = ArgumentCaptor.forClass(String.class);
        ArgumentCaptor<String> key = ArgumentCaptor.forClass(String.class);
        ArgumentCaptor<String> payload = ArgumentCaptor.forClass(String.class);
        Mockito.verify(outbox, Mockito.atLeastOnce()).insert(
            Mockito.anyString(), topic.capture(), key.capture(), payload.capture(), Mockito.anyLong());
        List<Emitted> out = new ArrayList<>();
        for (int i = 0; i < topic.getAllValues().size(); i++) {
            try {
                out.add(new Emitted(topic.getAllValues().get(i), key.getAllValues().get(i),
                    mapper.readTree(payload.getAllValues().get(i))));
            } catch (Exception e) {
                throw new IllegalStateException(e);
            }
        }
        return out;
    }

    @Test
    void marginPostedCarriesCanonFieldsAndTrdKey() {
        List<Emitted> events = capture(f -> f.marginPosted("TRD-1", 400, 1000));
        Emitted e = events.get(0);
        assertEquals(Topics.B2B_TRADEORDER_MARGIN_POSTED_V1, e.topic());
        assertEquals("TRD-1", e.key());
        assertEquals(400, e.payload().get("amountPoisha").asLong());
        assertEquals(1000, e.payload().get("postedAt").asLong());
        assertNotNull(e.payload().get("eventId"));
        assertEquals(1000, e.payload().get("occurredAt").asLong());
    }

    @Test
    void settlementInitiatedCarriesPpids() {
        List<Emitted> events = capture(f ->
            f.settlementInitiated("TRD-2", List.of("PP-a", "PP-b"), 2000));
        Emitted e = events.get(0);
        assertEquals(Topics.B2B_TRADEORDER_SETTLEMENT_INITIATED_V1, e.topic());
        assertEquals("TRD-2", e.key());
        assertEquals(2, e.payload().get("ppids").size());
    }

    @Test
    void tradeOrderCreatedCarriesMarginRequirement() {
        JsonNode items = mapper.createArrayNode();
        JsonNode terms = mapper.createObjectNode();
        List<Emitted> events = capture(f -> f.tradeOrderCreated(
            "TRD-3", "did:dokandar:s", "did:dokandar:b", items, terms, 4000, 400, 3000));
        Emitted e = events.get(0);
        assertEquals(Topics.B2B_TRADEORDER_TRADE_ORDER_CREATED_V1, e.topic());
        assertEquals(4000, e.payload().get("totalAmountPoisha").asLong());
        assertEquals(400, e.payload().get("marginRequirementPoisha").asLong());
        assertTrue(e.payload().get("items").isArray());
    }

    @Test
    void allSevenTopicsAreProducerSeven() {
        for (String t : new String[]{
                Topics.B2B_TRADEORDER_TRADE_ORDER_CREATED_V1, Topics.B2B_TRADEORDER_MARGIN_POSTED_V1,
                Topics.B2B_TRADEORDER_TRADE_ACTIVATED_V1, Topics.B2B_TRADEORDER_SETTLEMENT_INITIATED_V1,
                Topics.B2B_TRADEORDER_TRADE_SETTLED_V1, Topics.B2B_TRADEORDER_TRADE_DISPUTED_V1,
                Topics.B2B_TRADEORDER_TRADE_CANCELLED_V1})
            assertEquals(7, Topics.topicMeta(t).producer(), t);
    }
}
