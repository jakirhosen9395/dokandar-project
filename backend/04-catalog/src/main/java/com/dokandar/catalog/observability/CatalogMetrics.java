package com.dokandar.catalog.observability;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.util.concurrent.atomic.AtomicLong;

/**
 * Catalog business metrics. Every series carries {@code service="04-catalog"}
 * (the full service name as the label value; the metric-name prefix is
 * {@code catalog_}) — architecture.md §8.4 / §16-b. Closed-set labels only;
 * never user_id or any unbounded label.
 */
@Component
public class CatalogMetrics {

    private final String SVC;   // the full service name, sourced from SERVICE_NAME (never hardcoded)

    private final MeterRegistry reg;
    public final Counter productsCreated;
    public final Counter variantsCreated;
    public final Counter stockUpdates;
    public final Counter categoriesCreated;
    private final AtomicLong outboxPending = new AtomicLong(0);

    public CatalogMetrics(MeterRegistry reg, @Value("${dokandar.service.name:04-catalog}") String serviceName) {
        this.reg = reg;
        this.SVC = serviceName;
        this.productsCreated   = Counter.builder("catalog_products_created_total").tag("service", SVC).register(reg);
        this.variantsCreated   = Counter.builder("catalog_variants_created_total").tag("service", SVC).register(reg);
        this.stockUpdates      = Counter.builder("catalog_stock_updates_total").tag("service", SVC).register(reg);
        this.categoriesCreated = Counter.builder("catalog_categories_created_total").tag("service", SVC).register(reg);
        reg.gauge("catalog_outbox_pending", io.micrometer.core.instrument.Tags.of("service", SVC), outboxPending, AtomicLong::get);
    }

    public void productRead() { reg.counter("catalog_product_reads_total", "service", SVC, "source", "db").increment(); }
    public void reserveOutcome(String outcome) { reg.counter("catalog_grpc_reserve_total", "service", SVC, "outcome", outcome).increment(); }
    public void releaseCounted() { reg.counter("catalog_grpc_release_total", "service", SVC).increment(); }
    public void gc(long n) { if (n > 0) reg.counter("catalog_reservations_gc_total", "service", SVC).increment(n); }
    public void outboxRelayed(long n) { if (n > 0) reg.counter("catalog_outbox_relayed_total", "service", SVC).increment(n); }
    public void setOutboxPending(long n) { outboxPending.set(n); }
}
