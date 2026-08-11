package com.dokandar.order.saga;

import io.temporal.workflow.WorkflowInterface;
import io.temporal.workflow.WorkflowMethod;

/**
 * The checkout placement saga — the orchestration seam of the whole money/stock flow.
 * Temporal instantiates the {@link CheckoutWorkflowImpl} per execution; the REST
 * controller (agent C) starts it via a typed stub:
 *
 * <pre>{@code
 * CheckoutWorkflow wf = workflowClient.newWorkflowStub(
 *     CheckoutWorkflow.class,
 *     WorkflowOptions.newBuilder()
 *         .setWorkflowId(input.getIdempotencyKey())          // Idempotency-Key as workflow id
 *         .setTaskQueue(props.temporal.taskQueue)            // "checkout-saga" — same value the worker polls
 *         .build());
 * PlaceOrderResult res = wf.placeOrder(input);               // blocks for the synchronous placement result
 * }</pre>
 *
 * <p>Placement-only design (spec §10-order): reserve → coupon → debit → payment intent,
 * then persist {@code status=placed} and complete. {@code placed→confirmed} is driven
 * later off the {@code payment.settled} Kafka event, NOT a workflow signal.
 */
@WorkflowInterface
public interface CheckoutWorkflow {

    @WorkflowMethod
    PlaceOrderResult placeOrder(PlaceOrderInput input);
}
