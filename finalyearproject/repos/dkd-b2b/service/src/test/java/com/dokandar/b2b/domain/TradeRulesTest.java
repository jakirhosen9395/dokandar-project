package com.dokandar.b2b.domain;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import com.dokandar.platform.Errors;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.List;
import org.junit.jupiter.api.Test;

/** TradeItem/ContractTerms invariants — DM ctx #7 value-object rules, verbatim. */
class TradeRulesTest {
    private static final ObjectMapper M = new ObjectMapper();
    private static final long NOW = 1_783_000_000_000L;

    private static JsonNode json(String s) {
        try {
            return M.readTree(s);
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    @Test
    void parsesValidItemsAndComputesTotal() {
        // Arrange
        JsonNode items = json("""
            [{"gpid":"GP-rice-1","quantity":50,"unit":"kg","agreedUnitPricePoisha":2000},
             {"gpid":"GP-rice-1","quantity":3,"unit":"mt","agreedUnitPricePoisha":900000,
              "ppids":["PP-a","PP-b"]}]""");
        // Act
        List<TradeRules.Item> parsed = TradeRules.parseItems(items);
        long total = TradeRules.totalPoisha(parsed);
        // Assert
        assertEquals(2, parsed.size());
        assertEquals(50L * 2000 + 3L * 900000, total);
        assertEquals(List.of("PP-a", "PP-b"), parsed.get(1).ppids());
    }

    @Test
    void rejectsEmptyItemsAndBadUnits() {
        assertThrows(Errors.ValidationException.class, () -> TradeRules.parseItems(json("[]")));
        assertThrows(Errors.ValidationException.class, () -> TradeRules.parseItems(json(
            "[{\"gpid\":\"GP-x\",\"quantity\":1,\"unit\":\"maund\",\"agreedUnitPricePoisha\":10}]")),
            "maund is a DISPLAY unit, not a DM Unit value");
    }

    @Test
    void rejectsFloatQuantityAndPrice() {
        assertThrows(Errors.ValidationException.class, () -> TradeRules.parseItems(json(
            "[{\"gpid\":\"GP-x\",\"quantity\":1.5,\"unit\":\"kg\",\"agreedUnitPricePoisha\":10}]")));
        assertThrows(Errors.ValidationException.class, () -> TradeRules.parseItems(json(
            "[{\"gpid\":\"GP-x\",\"quantity\":1,\"unit\":\"kg\",\"agreedUnitPricePoisha\":10.5}]")));
    }

    @Test
    void rejectsDuplicateLineIdsAndPpids() {
        assertThrows(Errors.ValidationException.class, () -> TradeRules.parseItems(json("""
            [{"lineId":"L1","gpid":"GP-x","quantity":1,"unit":"kg","agreedUnitPricePoisha":10},
             {"lineId":"L1","gpid":"GP-y","quantity":1,"unit":"kg","agreedUnitPricePoisha":10}]""")));
        assertThrows(Errors.ValidationException.class, () -> TradeRules.parseItems(json("""
            [{"gpid":"GP-x","quantity":1,"unit":"kg","agreedUnitPricePoisha":10,
              "ppids":["PP-a","PP-a"]}]""")));
    }

    @Test
    void totalOverflowIsRejected() {
        JsonNode items = json("""
            [{"gpid":"GP-x","quantity":9223372036854775807,"unit":"kg","agreedUnitPricePoisha":2}]""");
        assertThrows(Errors.ValidationException.class,
            () -> TradeRules.totalPoisha(TradeRules.parseItems(items)));
    }

    @Test
    void parsesValidTerms() {
        TradeRules.Terms t = TradeRules.parseTerms(json("""
            {"paymentTermDays":30,"deliveryDeadlineAt":%d,"deliveryDistrict":"Dhaka",
             "penaltyRatePoisha":100}""".formatted(NOW + 172_800_000L)), NOW);
        assertEquals(30, t.paymentTermDays());
        assertEquals("Dhaka", t.deliveryDistrict());
        assertEquals(100, t.penaltyRatePoisha());
    }

    @Test
    void rejectsBadPaymentTermAndShortDeadline() {
        assertThrows(Errors.ValidationException.class, () -> TradeRules.parseTerms(json("""
            {"paymentTermDays":15,"deliveryDeadlineAt":%d,"deliveryDistrict":"Dhaka"}"""
            .formatted(NOW + 172_800_000L)), NOW), "15 is not a canon payment term");
        assertThrows(Errors.ValidationException.class, () -> TradeRules.parseTerms(json("""
            {"paymentTermDays":30,"deliveryDeadlineAt":%d,"deliveryDistrict":"Dhaka"}"""
            .formatted(NOW + 3_600_000L)), NOW), "deadline must be > createdAt + 24h");
        assertThrows(Errors.ValidationException.class, () -> TradeRules.parseTerms(json("""
            {"paymentTermDays":30,"deliveryDeadlineAt":%d}""".formatted(NOW + 172_800_000L)), NOW),
            "deliveryDistrict is required");
    }
}
