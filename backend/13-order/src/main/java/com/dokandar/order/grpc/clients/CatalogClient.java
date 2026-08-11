package com.dokandar.order.grpc.clients;

import com.dokandar.catalog.grpc.proto.ReleaseStockAnswer;
import com.dokandar.catalog.grpc.proto.ReleaseStockRequest;
import com.dokandar.catalog.grpc.proto.ReserveStockAnswer;
import com.dokandar.catalog.grpc.proto.ReserveStockRequest;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

/**
 * Catalog stock client — the forward (ReserveStock) + compensation (ReleaseStock)
 * legs of the checkout saga. FAIL-CLOSED: an insufficient-stock answer or a transport
 * error throws {@link CatalogStockException}, which the saga maps to a checkout abort.
 */
@Component
public class CatalogClient {

    private static final Logger log = LoggerFactory.getLogger(CatalogClient.class);

    private final GrpcClients clients;

    public CatalogClient(GrpcClients clients) {
        this.clients = clients;
    }

    /**
     * Reserve {@code quantity} of {@code variantId} for {@code orderId}. idempotencyKey
     * is REQUIRED (effectively-once). Throws {@link CatalogStockException} when the
     * catalog answers ok=false (carrying error_code, e.g. 'insufficient_stock') or on
     * any transport error — fail-closed.
     */
    public ReserveResult reserveStock(String idempotencyKey, String orderId, String variantId,
                                      String shopId, int quantity) {
        ReserveStockRequest req = ReserveStockRequest.newBuilder()
                .setIdempotencyKey(idempotencyKey)
                .setOrderId(orderId)
                .setVariantId(variantId)
                .setShopId(shopId == null ? "" : shopId)
                .setQuantity(quantity)
                .build();
        ReserveStockAnswer ans;
        try {
            ans = clients.catalog().reserveStock(req);
        } catch (RuntimeException e) {
            log.warn("ReserveStock transport error variant={} order={}", variantId, orderId, e);
            throw new CatalogStockException("catalog_unavailable", "ReserveStock call failed", e);
        }
        if (!ans.getOk()) {
            String code = ans.getErrorCode().isEmpty() ? "reserve_failed" : ans.getErrorCode();
            throw new CatalogStockException(code, "ReserveStock rejected: " + code, null);
        }
        return new ReserveResult(ans.getReservationId(), ans.getBackordered());
    }

    /**
     * Compensation: release a prior reservation. Returns the ok flag; transport errors
     * throw so the saga can retry the compensation (releasing stock must not silently
     * leak inventory).
     */
    public boolean releaseStock(String reservationId) {
        ReleaseStockRequest req = ReleaseStockRequest.newBuilder()
                .setReservationId(reservationId)
                .build();
        try {
            ReleaseStockAnswer ans = clients.catalog().releaseStock(req);
            return ans.getOk();
        } catch (RuntimeException e) {
            log.warn("ReleaseStock transport error reservation={}", reservationId, e);
            throw new CatalogStockException("catalog_unavailable", "ReleaseStock call failed", e);
        }
    }

    /** Successful reservation outcome. */
    public record ReserveResult(String reservationId, boolean backordered) {}

    /** Thrown on a rejected reservation (carries error_code) or a transport failure. */
    public static class CatalogStockException extends RuntimeException {
        private final String code;
        public CatalogStockException(String code, String message, Throwable cause) {
            super(message, cause);
            this.code = code;
        }
        public String getCode() { return code; }
    }
}
