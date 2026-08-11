package com.dokandar.order.saga;

import com.dokandar.order.config.OrderProperties;
import io.temporal.worker.Worker;
import io.temporal.worker.WorkerFactory;
import jakarta.annotation.PreDestroy;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;

/**
 * Registers the checkout saga on a Temporal worker and starts the {@link WorkerFactory}
 * (created-but-not-started in {@link com.dokandar.order.config.TemporalConfig}).
 *
 * <p>Bean topology trap (the #1 Spring+Temporal mistake): WORKFLOWS register as a TYPE —
 * Temporal news a fresh instance per execution, so it must NOT be a Spring bean;
 * ACTIVITIES register as the Spring-managed INSTANCE, which carries the injected gRPC
 * clients + repositories. The worker polls {@code props.temporal.taskQueue}
 * ({@code "checkout-saga"}) — the SAME value the controller's WorkflowOptions must set,
 * or the workflow is started on a queue no worker polls (silent hang).
 *
 * <p>Lifecycle mirrors the gRPC server: start on {@link ApplicationReadyEvent} (after the
 * Spring context + DB bootstrap), shut down on {@link PreDestroy}. Temporal is NEVER a
 * {@code /ready} gate (spec §8) — connectivity is a diagnostic on {@code /health} only.
 */
@Component
public class CheckoutWorker {

    private static final Logger log = LoggerFactory.getLogger(CheckoutWorker.class);

    private final WorkerFactory factory;
    private final CheckoutActivitiesImpl activities;   // Spring bean instance (DI-wired)
    private final OrderProperties props;
    private volatile boolean started = false;

    public CheckoutWorker(WorkerFactory factory, CheckoutActivitiesImpl activities, OrderProperties props) {
        this.factory = factory;
        this.activities = activities;
        this.props = props;
    }

    @EventListener(ApplicationReadyEvent.class)
    public synchronized void start() {
        if (started) return;
        String taskQueue = props.temporal.taskQueue;
        Worker worker = factory.newWorker(taskQueue);
        worker.registerWorkflowImplementationTypes(CheckoutWorkflowImpl.class);  // TYPE — Temporal instantiates
        worker.registerActivitiesImplementations(activities);                    // INSTANCE — DI-wired
        factory.start();
        started = true;
        log.info("Temporal worker started on task queue '{}' (namespace {})",
                taskQueue, props.temporal.namespace);
    }

    @PreDestroy
    public synchronized void stop() {
        if (!started) return;
        factory.shutdown();   // WorkflowServiceStubs.shutdown() runs via its bean destroyMethod
        started = false;
        log.info("Temporal worker shut down");
    }
}
