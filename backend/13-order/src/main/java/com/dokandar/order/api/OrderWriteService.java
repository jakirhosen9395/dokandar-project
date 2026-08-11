package com.dokandar.order.api;

import com.dokandar.order.config.OrderProperties;
import com.dokandar.order.domain.OrderStatusHistory;
import com.dokandar.order.domain.OutboxEvent;
import com.dokandar.order.domain.SubOrder;
import com.dokandar.order.observability.OrderMetrics;
import com.dokandar.order.repo.OrderStatusHistoryRepository;
import com.dokandar.order.repo.OutboxRepository;
import com.dokandar.order.repo.SubOrderRepository;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/**
 * The transactional lifecycle writes for sub-order transitions / cancels. SEPARATE from
 * {@link OrderController} so the {@code @Transactional} proxy actually applies — a controller
 * calling its own @Transactional method runs un-proxied (no tx), which would split the
 * status-history row from its outbox row. Each method writes the business mutation + the
 * append-only history + the outbox event in ONE DB transaction (the transactional-outbox
 * invariant: business row + outbox row commit together; the relay ships it afterwards).
 */
@Service
public class OrderWriteService {

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private final SubOrderRepository subOrders;
    private final OrderStatusHistoryRepository statusHistory;
    private final OutboxRepository outbox;
    private final OrderProperties props;
    private final OrderMetrics metrics;

    public OrderWriteService(SubOrderRepository subOrders, OrderStatusHistoryRepository statusHistory,
                             OutboxRepository outbox, OrderProperties props, OrderMetrics metrics) {
        this.subOrders = subOrders;
        this.statusHistory = statusHistory;
        this.outbox = outbox;
        this.props = props;
        this.metrics = metrics;
    }

    /**
     * Drive {@code placed → confirmed} off a {@code payment.settled} event (the consumer side
     * of the seam). Idempotent: only sub-orders CURRENTLY {@code placed} advance, so a
     * redelivered event is a no-op. For each advanced sub-order: set status + confirmed_at +
     * payment_state, append history, and enqueue {@code order.confirmed} + {@code order.status_changed}
     * outbox rows — all in ONE tx. The consumer commits the Kafka offset only AFTER this returns
     * (commit-after-handle). Returns the count advanced (0 → nothing to do).
     */
    @Transactional
    public int confirmFromPayment(UUID orderId) {
        OffsetDateTime now = OffsetDateTime.now();
        List<SubOrder> subs = subOrders.findByOrderId(orderId);
        int advanced = 0;
        for (SubOrder so : subs) {
            if (!"placed".equals(so.getStatus())) continue;   // idempotent: already past placed
            so.setStatus("confirmed");
            so.setPaymentState("settled");   // payment_state CHECK set: pending|settled|failed|refunded
            if (so.getConfirmedAt() == null) so.setConfirmedAt(now);
            subOrders.save(so);

            appendHistory(so.getId(), "placed", "confirmed", now);

            ObjectNode confirmed = basePayload("order.confirmed", so, now);
            write(props.topic.orderConfirmed, orderId.toString(), confirmed, now);

            ObjectNode changed = basePayload("order.status_changed", so, now);
            changed.put("from_status", "placed");
            changed.put("to_status", "confirmed");
            write(props.topic.orderStatusChanged, orderId.toString(), changed, now);

            metrics.transition("confirmed");
            advanced++;
        }
        if (advanced > 0) metrics.ordersConfirmed.increment();
        return advanced;
    }

    /**
     * Advance a sub-order to {@code toStatus}: mutate the row, append a history entry, and
     * enqueue an {@code order.status_changed} outbox event (plus an {@code order.delivered}
     * event when the new status is {@code delivered}) — all in one tx.
     */
    @Transactional
    public void applyTransition(UUID subOrderId, String fromStatus, String toStatus) {
        OffsetDateTime now = OffsetDateTime.now();
        SubOrder so = subOrders.findById(subOrderId).orElseThrow(
                () -> ApiException.notFound("sub-order not found"));

        so.setStatus(toStatus);
        if ("confirmed".equals(toStatus) && so.getConfirmedAt() == null) so.setConfirmedAt(now);
        subOrders.save(so);

        appendHistory(subOrderId, fromStatus, toStatus, now);
        enqueueStatusChanged(so, fromStatus, toStatus, now);
        if ("delivered".equals(toStatus)) enqueueDelivered(so, now);
    }

    /** Cancel a sub-order: status → cancelled, history entry, {@code order.cancelled} outbox — one tx. */
    @Transactional
    public void applyCancel(UUID subOrderId, String fromStatus) {
        OffsetDateTime now = OffsetDateTime.now();
        SubOrder so = subOrders.findById(subOrderId).orElseThrow(
                () -> ApiException.notFound("sub-order not found"));

        so.setStatus("cancelled");
        subOrders.save(so);

        appendHistory(subOrderId, fromStatus, "cancelled", now);
        enqueueStatusChanged(so, fromStatus, "cancelled", now);

        ObjectNode p = basePayload("order.cancelled", so, now);
        p.put("from_status", fromStatus);
        write(props.topic.orderCancelled, so.getOrderId().toString(), p, now);
    }

    // ---- helpers -----------------------------------------------------------

    private void appendHistory(UUID subOrderId, String from, String to, OffsetDateTime at) {
        OrderStatusHistory h = new OrderStatusHistory();
        h.setSubOrderId(subOrderId);
        h.setFromStatus(from);
        h.setToStatus(to);
        h.setAt(at);
        statusHistory.save(h);
    }

    private void enqueueStatusChanged(SubOrder so, String from, String to, OffsetDateTime at) {
        ObjectNode p = basePayload("order.status_changed", so, at);
        p.put("from_status", from);
        p.put("to_status", to);
        write(props.topic.orderStatusChanged, so.getOrderId().toString(), p, at);
    }

    private void enqueueDelivered(SubOrder so, OffsetDateTime at) {
        ObjectNode p = basePayload("order.delivered", so, at);
        write(props.topic.orderDelivered, so.getOrderId().toString(), p, at);
    }

    private ObjectNode basePayload(String event, SubOrder so, OffsetDateTime at) {
        ObjectNode p = MAPPER.createObjectNode();
        p.put("event", event);
        p.put("order_id", so.getOrderId().toString());
        p.put("sub_order_id", so.getId().toString());
        p.put("shop_id", so.getShopId().toString());
        p.put("status", so.getStatus());
        p.put("at", at.toString());
        return p;
    }

    private void write(String topic, String key, ObjectNode payload, OffsetDateTime at) {
        OutboxEvent ev = new OutboxEvent();
        ev.setTopic(topic);
        ev.setKey(key);
        ev.setPayload(payload.toString());
        ev.setCreatedAt(at);
        outbox.save(ev);
    }
}
