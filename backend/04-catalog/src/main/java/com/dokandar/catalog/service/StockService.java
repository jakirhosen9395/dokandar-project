package com.dokandar.catalog.service;

import com.dokandar.catalog.api.ApiException;
import com.dokandar.catalog.observability.CatalogMetrics;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.dao.EmptyResultDataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Multi-level stock + idempotent reservations (architecture.md §3.3 / §7.3).
 * Concurrency is Postgres {@code SELECT … FOR UPDATE} row locks (NOT Redis
 * Redlock); idempotency is the {@code UNIQUE(idempotency_key)} fence + a
 * pre-lock read-back and a post-lock re-check (the 23505 fallback covers the
 * no-stock-row backorder race). Uses raw SQL for exact COALESCE-sentinel /
 * ON CONFLICT / FOR UPDATE semantics inside an explicit transaction.
 */
@Service
public class StockService {

    private static final Logger LOG = LoggerFactory.getLogger(StockService.class);
    private static final String NIL = "00000000-0000-0000-0000-000000000000";
    static final int MAX_MINOR = 2147483647;

    private final JdbcTemplate jdbc;
    private final TransactionTemplate tx;
    private final CatalogMetrics metrics;
    private final ObjectMapper json = new ObjectMapper();
    private final String topicStockLow;

    public StockService(JdbcTemplate jdbc, PlatformTransactionManager txm, CatalogMetrics metrics,
                        @Value("${dokandar.topic.stock-low:dokandar.stock.low}") String topicStockLow) {
        this.jdbc = jdbc;
        this.tx = new TransactionTemplate(txm);
        this.metrics = metrics;
        this.topicStockLow = topicStockLow;
    }

    public record StockInfo(boolean sufficient, boolean backorderable, int available) {}
    public record ReserveResult(boolean ok, String errorCode, String reservationId, boolean backordered) {}
    private record Sharing(String model, boolean backorderable) {}

    // ---- CheckStock (non-locking read) ------------------------------------

    public StockInfo checkStock(String variantId, String shopId, int qty) {
        Sharing s = sharingOrThrow(variantId);
        String shop = "shared".equals(s.model) ? null : emptyToNull(shopId);
        Integer[] oh = stockCounts(variantId, shop);
        int available = oh == null ? 0 : (oh[0] - oh[1]);
        return new StockInfo(available >= qty, s.backorderable, available);
    }

    // ---- ReserveStock (idempotent, FOR-UPDATE serialized) -----------------

    public ReserveResult reserve(String idemKey, String orderId, String variantId, String shopId, int qty) {
        String[] replay = findReservation(idemKey);
        if (replay != null) return new ReserveResult(true, "", replay[0], "t".equals(replay[1]));
        try {
            return tx.execute(st -> doReserveLocked(idemKey, orderId, variantId, shopId, qty));
        } catch (DataIntegrityViolationException dup) {
            String[] r = findReservation(idemKey);
            if (r != null) return new ReserveResult(true, "", r[0], "t".equals(r[1]));
            throw dup;
        }
    }

    private ReserveResult doReserveLocked(String idemKey, String orderId, String variantId, String shopId, int qty) {
        Sharing s = sharingOrThrow(variantId);
        String shop = "shared".equals(s.model) ? null : emptyToNull(shopId);

        // lock the stock row (may be absent for a not-yet-created shared pool / backorder)
        Map<String, Object> row = queryStockForUpdate(variantId, shop);

        // post-lock idempotency re-check (a concurrent winner holding the lock has
        // since committed its reservation) — return the replay before any decrement
        String[] again = findReservation(idemKey);
        if (again != null) return new ReserveResult(true, "", again[0], "t".equals(again[1]));

        boolean backordered = false;
        if (row == null) {
            if (!s.backorderable) return new ReserveResult(false, "insufficient_stock", "", false);
            backordered = true;
        } else {
            int onHand = ((Number) row.get("on_hand")).intValue();
            int reserved = ((Number) row.get("reserved")).intValue();
            int threshold = ((Number) row.get("low_threshold")).intValue();
            if (onHand - reserved >= qty) {
                jdbc.update("UPDATE stock SET reserved = reserved + ?, updated_at = now() WHERE id = ?::uuid",
                        qty, row.get("id"));
                // emit stock.low only when availability CROSSES the threshold (§10), not on every at/below reserve
                if ((onHand - reserved) > threshold && (onHand - reserved - qty) <= threshold)
                    emitStockLow(variantId, shop, onHand - reserved - qty, threshold);
            } else if (s.backorderable) {
                backordered = true;
            } else {
                return new ReserveResult(false, "insufficient_stock", "", false);
            }
        }

        String resId = jdbc.queryForObject(
            "INSERT INTO stock_reservations (idempotency_key, order_id, variant_id, shop_id, quantity, backordered) " +
            "VALUES (?, ?::uuid, ?::uuid, ?::uuid, ?, ?) RETURNING id::text",
            String.class, idemKey, orderId, variantId, shop, qty, backordered);
        return new ReserveResult(true, "", resId, backordered);
    }

    // ---- ReleaseStock (idempotent) ----------------------------------------

    public boolean release(String reservationId) {
        Boolean ok = tx.execute(st -> releaseOne("id = ?::uuid", reservationId));
        return Boolean.TRUE.equals(ok);
    }

    private boolean releaseOne(String whereClause, Object arg) {
        List<Map<String, Object>> rows = jdbc.queryForList(
            "SELECT id::text AS id, variant_id::text AS variant_id, shop_id::text AS shop_id, quantity, backordered " +
            "FROM stock_reservations WHERE " + whereClause + " AND state = 'reserved' FOR UPDATE", arg);
        if (rows.isEmpty()) return true;   // already released/committed/unknown — idempotent no-op
        Map<String, Object> r = rows.get(0);
        boolean backordered = Boolean.TRUE.equals(r.get("backordered"));
        if (!backordered) {
            String variant = (String) r.get("variant_id");
            String shop = (String) r.get("shop_id");
            int qty = ((Number) r.get("quantity")).intValue();
            jdbc.update("UPDATE stock SET reserved = GREATEST(reserved - ?, 0), updated_at = now() " +
                    "WHERE variant_id = ?::uuid AND COALESCE(shop_id, ?::uuid) = COALESCE(?::uuid, ?::uuid)",
                    qty, variant, NIL, shop, NIL);
        }
        jdbc.update("UPDATE stock_reservations SET state = 'released' WHERE id = ?::uuid", r.get("id"));
        return true;
    }

    /** Sweeper — releases reserved rows past their 15-min expiry. Returns the count. */
    public long gcExpired() {
        List<String> ids = jdbc.queryForList(
            "SELECT id::text FROM stock_reservations WHERE state = 'reserved' AND expires_at < now() LIMIT 500", String.class);
        long n = 0;
        for (String id : ids) {
            Boolean ok = tx.execute(st -> releaseOne("id = ?::uuid", id));
            if (Boolean.TRUE.equals(ok)) n++;
        }
        return n;
    }

    // ---- SetStock (REST PUT /stock/{variant_id}) --------------------------

    public Map<String, Object> setStock(String variantId, UUID sub, String role,
                                        String shopId, Integer onHand, Integer lowThreshold) {
        UUID vid;
        try { vid = UUID.fromString(variantId); } catch (Exception e) { throw ApiException.badUuid(); }
        List<Map<String, Object>> owner = jdbc.queryForList(
            "SELECT p.id::text AS pid, p.owner_id::text AS owner, p.sharing_model AS sharing " +
            "FROM products p JOIN product_variants v ON v.product_id = p.id WHERE v.id = ?::uuid", vid.toString());
        if (owner.isEmpty()) throw ApiException.notFound("No such variant");
        Map<String, Object> o = owner.get(0);
        if (!o.get("owner").equals(sub.toString()) && !"admin".equals(role))
            throw ApiException.forbidden("forbidden", "You do not own this product.");
        if (onHand == null || onHand < 0 || onHand > MAX_MINOR)
            throw ApiException.validation("on_hand required (0..2147483647)");
        boolean shared = "shared".equals(o.get("sharing"));
        if (shared) {
            if (shopId != null && !shopId.isBlank())
                throw new ApiException(422, "invalid_scope", "shared-model product uses the shared stock pool; omit shop_id");
        } else if (shopId == null || shopId.isBlank() || !isUuid(shopId)) {
            // per_shop_copy must NOT silently coerce a blank/invalid shop_id into the shared NULL pool (mis-scoped, lost stock)
            throw new ApiException(422, "invalid_scope", "per_shop_copy product requires a valid shop_id");
        }
        String shop = shared ? null : shopId;
        int threshold = lowThreshold == null ? 5 : lowThreshold;

        jdbc.update(
            "INSERT INTO stock (variant_id, shop_id, on_hand, low_threshold, updated_at) " +
            "VALUES (?::uuid, ?::uuid, ?, ?, now()) " +
            "ON CONFLICT (variant_id, COALESCE(shop_id, '" + NIL + "'::uuid)) " +
            "DO UPDATE SET on_hand = EXCLUDED.on_hand, low_threshold = EXCLUDED.low_threshold, updated_at = now()",
            vid.toString(), shop, onHand, threshold);
        metrics.stockUpdates.increment();
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("status", "ok"); out.put("variant_id", variantId); out.put("on_hand", onHand);
        return out;
    }

    // ---- helpers -----------------------------------------------------------

    private Sharing sharingOrThrow(String variantId) {
        try {
            return jdbc.queryForObject(
                "SELECT p.sharing_model, p.backorderable FROM products p " +
                "JOIN product_variants v ON v.product_id = p.id WHERE v.id = ?::uuid",
                (rs, i) -> new Sharing(rs.getString(1), rs.getBoolean(2)), variantId);
        } catch (EmptyResultDataAccessException e) {
            throw ApiException.notFound("variant not found");
        }
    }

    private Integer[] stockCounts(String variantId, String shop) {
        List<Map<String, Object>> rows = jdbc.queryForList(
            "SELECT on_hand, reserved FROM stock WHERE variant_id = ?::uuid " +
            "AND COALESCE(shop_id, ?::uuid) = COALESCE(?::uuid, ?::uuid)", variantId, NIL, shop, NIL);
        if (rows.isEmpty()) return null;
        Map<String, Object> r = rows.get(0);
        return new Integer[]{ ((Number) r.get("on_hand")).intValue(), ((Number) r.get("reserved")).intValue() };
    }

    private Map<String, Object> queryStockForUpdate(String variantId, String shop) {
        List<Map<String, Object>> rows = jdbc.queryForList(
            "SELECT id::text AS id, on_hand, reserved, low_threshold FROM stock WHERE variant_id = ?::uuid " +
            "AND COALESCE(shop_id, ?::uuid) = COALESCE(?::uuid, ?::uuid) FOR UPDATE", variantId, NIL, shop, NIL);
        return rows.isEmpty() ? null : rows.get(0);
    }

    /** Returns {reservation_id, 't'|'f' backordered} or null. */
    private String[] findReservation(String idemKey) {
        List<Map<String, Object>> rows = jdbc.queryForList(
            "SELECT id::text AS id, backordered FROM stock_reservations WHERE idempotency_key = ?", idemKey);
        if (rows.isEmpty()) return null;
        Map<String, Object> r = rows.get(0);
        return new String[]{ (String) r.get("id"), Boolean.TRUE.equals(r.get("backordered")) ? "t" : "f" };
    }

    private void emitStockLow(String variantId, String shop, int available, int threshold) {
        Map<String, Object> e = new LinkedHashMap<>();
        e.put("event", "StockLow");
        e.put("variant_id", variantId);
        e.put("shop_id", shop);
        e.put("available", available);
        e.put("low_threshold", threshold);
        e.put("at", OffsetDateTime.now(ZoneOffset.UTC).toString());
        try {
            jdbc.update("INSERT INTO outbox (topic, key, payload) VALUES (?, ?, ?::jsonb)",
                    topicStockLow, variantId, json.writeValueAsString(e));
        } catch (Exception ex) { LOG.warn("stock.low emit failed: {}", ex.getMessage()); }
    }

    /** Blank/empty → null, so a bound {@code ?::uuid} becomes SQL NULL (the shared-pool sentinel), never the 22P02-throwing empty string. */
    private static String emptyToNull(String s) { return (s == null || s.isBlank()) ? null : s; }
    private static boolean isUuid(String s) { try { UUID.fromString(s); return true; } catch (Exception e) { return false; } }
}
