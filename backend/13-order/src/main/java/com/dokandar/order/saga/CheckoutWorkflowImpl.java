package com.dokandar.order.saga;

import io.temporal.activity.ActivityOptions;
import io.temporal.common.RetryOptions;
import io.temporal.workflow.Saga;
import io.temporal.workflow.Workflow;

import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Placement saga implementation. Temporal news this per execution — it is NOT a Spring
 * bean; all I/O lives in {@link CheckoutActivities} (the workflow body is deterministic:
 * no clocks, no randomness, no gRPC/DB calls — every downstream call is an activity).
 *
 * <p>Flow (spec §10-order / checkout saga):
 * reserveAll (+ releaseAll compensation) → applyCoupon → compute totals →
 * debit (+ credit compensation) → createPayment → persistOrder. On any activity failure
 * {@code saga.compensate()} unwinds in reverse, then the failure is rethrown so the REST
 * handler sees a clean WorkflowFailedException (no money or stock left dangling).
 */
public class CheckoutWorkflowImpl implements CheckoutWorkflow {

    // Activities get a bounded deadline + bounded retries. Genuine business rejections
    // (e.g. stock_changed) are thrown as NON-retryable ApplicationFailures by the impl,
    // so those abort immediately; only transport blips consume the retries.
    private final CheckoutActivities act = Workflow.newActivityStub(
            CheckoutActivities.class,
            ActivityOptions.newBuilder()
                    .setStartToCloseTimeout(Duration.ofSeconds(30))
                    .setRetryOptions(RetryOptions.newBuilder()
                            .setInitialInterval(Duration.ofMillis(200))
                            .setMaximumAttempts(3)
                            .build())
                    .build());

    @Override
    public PlaceOrderResult placeOrder(PlaceOrderInput input) {
        Saga saga = new Saga(new Saga.Options.Builder()
                .setParallelCompensation(false)
                .build());
        try {
            // 1. Reserve stock for every line (fail-closed). reserveAll self-releases any
            //    partial reservation before throwing, so this compensation covers the
            //    full-success case where a later step fails.
            List<String> reservationIds = act.reserveAll(input);
            saga.addCompensation(() -> act.releaseAll(reservationIds));

            // 2. Coupon (fail-open) — no reverse leg (coupon has no compensation RPC).
            long discountMinor = act.applyCoupon(input);

            // 3. Totals: per-shop and grand, in paisa. Discount applied to the grand total.
            Map<String, Long> perShopMinor = perShopTotals(input);
            long subtotalMinor = 0L;
            for (long v : perShopMinor.values()) subtotalMinor += v;
            long payableMinor = Math.max(0L, subtotalMinor - discountMinor);

            // 4. Debit wallet (fail-closed) ONLY for wallet-paid orders. COD / online-provider
            //    orders settle via createPayment (step 5), so the wallet is never debited up-front.
            if (payableMinor > 0L && "wallet".equalsIgnoreCase(input.getPaymentMethod())) {
                act.debit(input, payableMinor);
                saga.addCompensation(() -> act.credit(input, payableMinor));
            }

            // 5. Payment intent(s) per sub-order (internal REST, fail-closed).
            String paymentState = act.createPayment(input, perShopMinor);

            // 6. Persist the order graph + order.placed outbox in one tx; returns generated ids.
            return act.persistOrder(input, discountMinor, reservationIds, paymentState);
        } catch (Exception e) {
            saga.compensate();   // releaseAll / credit, in reverse registration order
            throw e;             // surfaces as WorkflowFailedException to the controller
        }
    }

    /** Sum line totals per distinct shop (insertion-ordered), in paisa. */
    private static Map<String, Long> perShopTotals(PlaceOrderInput input) {
        Map<String, Long> perShop = new LinkedHashMap<>();
        for (PlaceOrderInput.Item it : input.getItems()) {
            long lineTotal = it.getUnitPriceMinor() * (long) it.getQuantity();
            perShop.merge(it.getShopId(), lineTotal, Long::sum);
        }
        return perShop;
    }
}
