package com.dokandar.b2b.domain;

import com.dokandar.platform.Errors;
import com.fasterxml.jackson.databind.JsonNode;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * TradeOrder invariants, verbatim from Domain-Model ctx #7:
 * - TradeItem: lineId unique; gpid; ppids optional (empty = spot; non-empty must not repeat);
 *   quantity int64 > 0; unit in the DM shared Unit enum; agreedUnitPricePoisha int64 > 0.
 * - ContractTerms: paymentTermDays in {0,7,14,30,60,90}; deliveryDeadlineAt > createdAt + 24h;
 *   deliveryDistrict required; qualityGrade <= 50; penaltyRatePoisha >= 0 per day;
 *   arbitrationClause <= 200.
 * - totalAmountPoisha = sum(agreedUnitPricePoisha * quantity), integer poisha, overflow-checked.
 */
public final class TradeRules {
    /** DM shared type Unit — seer/maund/bosta are DISPLAY units (stored as grams), never DM values. */
    public static final Set<String> UNITS = Set.of("g", "ml", "pcs", "kg", "L", "mt");
    public static final Set<Integer> PAYMENT_TERM_DAYS = Set.of(0, 7, 14, 30, 60, 90);
    public static final long MIN_DEADLINE_LEAD_MS = 86_400_000L;

    public record Item(String lineId, String gpid, List<String> ppids, long quantity,
                       String unit, long agreedUnitPricePoisha) {}

    public record Terms(int paymentTermDays, long deliveryDeadlineAt, String deliveryDistrict,
                        String qualityGrade, long penaltyRatePoisha, String arbitrationClause) {}

    private TradeRules() {}

    public static List<Item> parseItems(JsonNode raw) {
        if (raw == null || !raw.isArray() || raw.isEmpty())
            throw bad("items", "at least one TradeItem is required");
        List<Item> out = new ArrayList<>();
        Set<String> lineIds = new HashSet<>();
        for (JsonNode n : raw) {
            String lineId = text(n, "lineId");
            if (lineId == null) lineId = UUID.randomUUID().toString();
            if (!lineIds.add(lineId)) throw bad("items", "lineId must be unique within the TradeOrder");
            String gpid = text(n, "gpid");
            if (!TradeIds.isGpid(gpid)) throw bad("items", "gpid must be a GP- prefixed id");
            long qty = requirePositiveLong(n, "quantity");
            String unit = text(n, "unit");
            if (unit == null || !UNITS.contains(unit))
                throw bad("items", "unit must be one of the DM Unit values " + UNITS);
            long price = requirePositiveLong(n, "agreedUnitPricePoisha");
            List<String> ppids = new ArrayList<>();
            JsonNode pn = n.get("ppids");
            if (pn != null && pn.isArray()) {
                Set<String> seen = new HashSet<>();
                for (JsonNode p : pn) {
                    String ppid = p.isTextual() ? p.asText() : null;
                    if (!TradeIds.isPpid(ppid)) throw bad("items", "ppids must be PP- prefixed ids");
                    if (!seen.add(ppid)) throw bad("items", "duplicate ppid in a TradeItem");
                    ppids.add(ppid);
                }
            }
            out.add(new Item(lineId, gpid, List.copyOf(ppids), qty, unit, price));
        }
        return List.copyOf(out);
    }

    public static Terms parseTerms(JsonNode n, long createdAt) {
        if (n == null || !n.isObject()) throw bad("contractTerms", "contractTerms object is required");
        JsonNode ptd = n.get("paymentTermDays");
        if (ptd == null || !ptd.canConvertToInt() || ptd.isFloatingPointNumber()
                || !PAYMENT_TERM_DAYS.contains(ptd.asInt()))
            throw bad("contractTerms", "paymentTermDays must be one of " + PAYMENT_TERM_DAYS);
        JsonNode ddl = n.get("deliveryDeadlineAt");
        if (ddl == null || !ddl.canConvertToLong() || ddl.isFloatingPointNumber()
                || ddl.asLong() <= createdAt + MIN_DEADLINE_LEAD_MS)
            throw bad("contractTerms", "deliveryDeadlineAt must be > createdAt + 24h (unix ms)");
        String district = text(n, "deliveryDistrict");
        if (district == null) throw bad("contractTerms", "deliveryDistrict is required");
        String grade = text(n, "qualityGrade");
        if (grade != null && grade.length() > 50) throw bad("contractTerms", "qualityGrade <= 50 chars");
        long penalty = 0;
        JsonNode pen = n.get("penaltyRatePoisha");
        if (pen != null) {
            if (!pen.canConvertToLong() || pen.isFloatingPointNumber() || pen.asLong() < 0)
                throw bad("contractTerms", "penaltyRatePoisha must be an integer >= 0");
            penalty = pen.asLong();
        }
        String arb = text(n, "arbitrationClause");
        if (arb != null && arb.length() > 200) throw bad("contractTerms", "arbitrationClause <= 200 chars");
        return new Terms(ptd.asInt(), ddl.asLong(), district, grade, penalty, arb);
    }

    /** Integer poisha, overflow-checked — a total that cannot fit in int64 is a validation error. */
    public static long totalPoisha(List<Item> items) {
        long total = 0;
        try {
            for (Item it : items)
                total = Math.addExact(total, Math.multiplyExact(it.agreedUnitPricePoisha(), it.quantity()));
        } catch (ArithmeticException e) {
            throw bad("items", "totalAmountPoisha overflows int64");
        }
        if (total <= 0) throw bad("items", "totalAmountPoisha must be > 0");
        return total;
    }

    private static long requirePositiveLong(JsonNode n, String field) {
        JsonNode v = n.get(field);
        if (v == null || !v.canConvertToLong() || v.isFloatingPointNumber() || v.asLong() <= 0)
            throw bad("items", field + " must be an integer > 0");
        return v.asLong();
    }

    private static String text(JsonNode n, String field) {
        JsonNode v = n.get(field);
        return v != null && v.isTextual() && !v.asText().isBlank() ? v.asText() : null;
    }

    private static Errors.ValidationException bad(String field, String msg) {
        // taxonomy reasons are snake_case ([a-z0-9_]+) — camelCase field names are converted
        String reason = field.replaceAll("([A-Z])", "_$1").toLowerCase();
        return new Errors.ValidationException(Errors.errorCode("b2b", "validation", reason), msg);
    }
}
