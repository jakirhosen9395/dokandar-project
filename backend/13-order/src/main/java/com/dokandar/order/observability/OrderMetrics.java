package com.dokandar.order.observability;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.util.concurrent.atomic.AtomicLong;

/**
 * Order business metrics. Every series carries {@code service="13-order"} (the full
 * service name as the label value; the metric-name prefix is {@code order_}).
 * Closed-set labels only; never user_id / order_id or any unbounded label.
 * Mandatory: {@code order_outbox_pending{service="13-order"}} (the fleet outbox gauge).
 */
@Component
public class OrderMetrics {

    private final String SVC;   // the full service name, sourced from SERVICE_NAME (never hardcoded)

    private final MeterRegistry reg;
    public final Counter ordersPlaced;
    public final Counter ordersConfirmed;
    private final AtomicLong outboxPending = new AtomicLong(0);

    public OrderMetrics(MeterRegistry reg, @Value("${dokandar.service.name:13-order}") String serviceName) {
        this.reg = reg;
        this.SVC = serviceName;
        this.ordersPlaced    = Counter.builder("order_orders_placed_total").tag("service", SVC).register(reg);
        this.ordersConfirmed = Counter.builder("order_orders_confirmed_total").tag("service", SVC).register(reg);
        reg.gauge("order_outbox_pending", io.micrometer.core.instrument.Tags.of("service", SVC), outboxPending, AtomicLong::get);
    }

    /** Saga step outcome (closed set: ok | stock_changed | coupon_invalid | wallet_error | compensated). */
    public void sagaOutcome(String outcome) { reg.counter("order_saga_total", "service", SVC, "outcome", outcome).increment(); }
    /** Sub-order transition (closed set: to-status). */
    public void transition(String toStatus) { reg.counter("order_transitions_total", "service", SVC, "to", toStatus).increment(); }
    public void outboxRelayed(long n) { if (n > 0) reg.counter("order_outbox_relayed_total", "service", SVC).increment(n); }
    public void setOutboxPending(long n) { outboxPending.set(n); }
}
