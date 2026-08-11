package com.dokandar.b2b.app;

import com.dokandar.b2b.store.TradeStore;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

/** REST projections of store rows — envelope-ready, integer poisha, ms timestamps. */
public final class Views {

    public record TradeView(String trd, String sellerDid, String buyerDid, JsonNode items,
                            JsonNode contractTerms, long totalAmountPoisha,
                            long marginRequirementPoisha, Long marginPostedPoisha, String status,
                            boolean recallFlag, String reason, JsonNode settlementPpids,
                            long createdAt, long updatedAt) {}

    private Views() {}

    public static TradeView trade(TradeStore.TradeRow r, ObjectMapper mapper) {
        return new TradeView(r.trd(), r.sellerDid(), r.buyerDid(),
            parse(mapper, r.itemsJson()), parse(mapper, r.termsJson()),
            r.totalAmountPoisha(), r.marginRequirementPoisha(), r.marginPostedPoisha(),
            r.status(), r.recallFlag(), r.reason(), parse(mapper, r.settlementPpidsJson()),
            r.createdAt(), r.updatedAt());
    }

    private static JsonNode parse(ObjectMapper mapper, String json) {
        if (json == null) return null;
        try {
            return mapper.readTree(json);
        } catch (Exception e) {
            throw new IllegalStateException("stored JSON column is unreadable", e);
        }
    }
}
