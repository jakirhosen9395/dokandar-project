package com.dokandar.order.grpc.clients;

import dokandar.coupon.v1.ValidateCouponReply;
import dokandar.coupon.v1.ValidateCouponRequest;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

/**
 * Coupon validation client — place-time discount check. FAIL-OPEN: any error
 * (transport, UNAUTHENTICATED, or peer down) is swallowed and a no-discount result
 * returned, so a flaky coupon service never blocks a checkout (spec §checkout-saga).
 */
@Component
public class CouponClient {

    private static final Logger log = LoggerFactory.getLogger(CouponClient.class);

    private final GrpcClients clients;

    public CouponClient(GrpcClients clients) {
        this.clients = clients;
    }

    /**
     * Validate {@code code} for {@code userId} against {@code subtotalMinor}. Returns a
     * {@link CouponResult}; on ANY failure (including StatusRuntimeException) returns
     * {@link CouponResult#none()} — fail-open, zero discount.
     */
    public CouponResult validateCoupon(String code, String userId, String shopId,
                                       long subtotalMinor, String paymentMethod) {
        if (code == null || code.isBlank()) {
            return CouponResult.none();
        }
        ValidateCouponRequest req = ValidateCouponRequest.newBuilder()
                .setCode(code)
                .setUserId(userId == null ? "" : userId)
                .setShopId(shopId == null ? "" : shopId)
                .setSubtotalMinor(subtotalMinor)
                .setPaymentMethod(paymentMethod == null ? "" : paymentMethod)
                .build();
        try {
            ValidateCouponReply reply = clients.coupon().validateCoupon(req);
            if (!reply.getValid()) {
                return CouponResult.none();
            }
            return new CouponResult(true, reply.getDiscountMinor(), reply.getCouponId(),
                    reply.getFundedBy(), reply.getStacksWithSale(), reply.getReason());
        } catch (Throwable t) {  // fail-open: catch-all incl. StatusRuntimeException
            log.warn("ValidateCoupon failed (fail-open, no discount) code={}", code, t);
            return CouponResult.none();
        }
    }

    /** Validation outcome. valid=false / discountMinor=0 is the fail-open default. */
    public record CouponResult(boolean valid, long discountMinor, String couponId,
                               String fundedBy, boolean stacksWithSale, String reason) {
        public static CouponResult none() {
            return new CouponResult(false, 0L, "", "", false, "no_coupon");
        }
    }
}
