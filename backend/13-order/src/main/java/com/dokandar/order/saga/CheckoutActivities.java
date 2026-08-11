package com.dokandar.order.saga;

import io.temporal.activity.ActivityInterface;
import io.temporal.activity.ActivityMethod;

import java.util.List;

/**
 * Saga side-effects — the only place real I/O (gRPC peers, internal REST, Postgres)
 * happens; the workflow body stays deterministic and calls these via an activity stub.
 * Implemented by the Spring-managed {@link CheckoutActivitiesImpl} (registered as an
 * INSTANCE on the worker, so DI supplies the gRPC clients + repositories).
 *
 * <p>Every method is idempotent: the forward legs key off {@code input.idempotencyKey}
 * (a workflow-stable value that survives activity retries), the compensations use a
 * DISTINCT key so a refund is never deduped against its debit. The forward/compensation
 * pairs are: {@code reserveAll}/{@code releaseAll} and {@code debit}/{@code credit}.
 */
@ActivityInterface
public interface CheckoutActivities {

    /**
     * Reserve stock for every line (fail-closed). Per-line idem key
     * {@code idempotencyKey + ":reserve:" + i}. On any line failure, releases the lines
     * already reserved in THIS call, then throws an {@link io.temporal.failure.ApplicationFailure}
     * with type {@code "stock_changed"} (non-retryable for a genuine stock rejection).
     * Returns the reservation ids in line order (for {@code releaseAll} compensation).
     */
    @ActivityMethod
    List<String> reserveAll(PlaceOrderInput input);

    /** Compensation: release every reservation id (best-effort, retried by the activity stub). */
    @ActivityMethod
    void releaseAll(List<String> reservationIds);

    /** Coupon discount in paisa (fail-open: any error → 0). */
    @ActivityMethod
    long applyCoupon(PlaceOrderInput input);

    /**
     * Debit the customer's wallet for {@code totalMinor} (fail-closed). idem key
     * {@code idempotencyKey + ":debit"}. Skips the RPC and returns {@code ""} when
     * {@code totalMinor <= 0}. Returns the ledger entry id.
     */
    @ActivityMethod
    String debit(PlaceOrderInput input, long totalMinor);

    /** Compensation: credit {@code amountMinor} back. DISTINCT idem key {@code idempotencyKey + ":credit-comp"}. */
    @ActivityMethod
    void credit(PlaceOrderInput input, long amountMinor);

    /**
     * Create one COD payment intent per sub-order (keyed by shop) via internal REST to
     * 09-payment (fail-closed). {@code perShopMinor} maps shopId → that shop's total in
     * paisa. Returns the aggregate intent state ({@code "pending"} for COD).
     */
    @ActivityMethod
    String createPayment(PlaceOrderInput input, java.util.Map<String, Long> perShopMinor);

    /**
     * Persist the whole order graph in ONE transaction: the {@code orders} row (with the
     * UNIQUE {@code idempotency_key}), one {@code sub_orders} row per distinct shop, the
     * {@code order_lines}, the initial {@code order_status_history} rows, and the
     * {@code order.placed} outbox event. Returns the result with the Hibernate-generated
     * order/sub-order ids. Idempotent: a duplicate idempotency_key returns the existing order.
     */
    @ActivityMethod
    PlaceOrderResult persistOrder(PlaceOrderInput input, long discountMinor,
                                  List<String> reservationIds, String paymentState);
}
