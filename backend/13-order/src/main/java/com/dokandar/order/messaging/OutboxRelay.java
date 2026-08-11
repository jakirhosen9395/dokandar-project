package com.dokandar.order.messaging;

import com.dokandar.order.config.OrderProperties;
import com.dokandar.order.domain.OutboxEvent;
import com.dokandar.order.observability.OrderMetrics;
import com.dokandar.order.repo.OutboxRepository;
import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.Producer;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.serialization.StringSerializer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.Properties;

/**
 * The transactional-outbox relay (the producer side of the seam). On a fixed schedule it
 * claims the oldest unsent rows {@code FOR UPDATE SKIP LOCKED} (so multiple replicas never
 * contend), publishes each to Kafka with {@code acks=all}, stamps {@code sent_at}, and
 * publishes the {@code order_outbox_pending} gauge.
 *
 * <p>Two correctness anchors:
 * <ul>
 *   <li>{@code @Transactional} is on the {@code @Scheduled} method directly — the Spring
 *       scheduler invokes through the proxy, so the tx (and thus {@code FOR UPDATE}) applies.</li>
 *   <li>{@code producer.send(...).get()} BLOCKS for the broker ack before {@code sent_at} is
 *       set — fire-and-forget would mark a row sent before {@code acks=all} confirmed and lose
 *       it on a send failure. A failed send leaves {@code sent_at} null → retried next tick.</li>
 * </ul>
 * The producer is built once ({@code @PostConstruct}) from {@code dokandar.kafka.bootstrap}
 * (the SAME source {@code /health} probes) and closed at shutdown. Adaptive: an empty fetch
 * does nothing (no Kafka I/O) and just refreshes the gauge.
 */
@Component
public class OutboxRelay {

    private static final Logger LOG = LoggerFactory.getLogger(OutboxRelay.class);
    private static final int BATCH = 100;

    private final OutboxRepository outbox;
    private final OrderMetrics metrics;
    private final OrderProperties props;
    private volatile Producer<String, String> producer;

    public OutboxRelay(OutboxRepository outbox, OrderMetrics metrics, OrderProperties props) {
        this.outbox = outbox;
        this.metrics = metrics;
        this.props = props;
    }

    @PostConstruct
    public void start() {
        String bootstrap = props.kafka.bootstrap;
        if (bootstrap == null || bootstrap.isBlank()) {
            LOG.warn("KAFKA_BOOTSTRAP unset — outbox relay will buffer (rows stay unsent until configured)");
            return;
        }
        Properties p = new Properties();
        p.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrap);
        p.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        p.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        p.put(ProducerConfig.ACKS_CONFIG, "all");                       // durability: full ISR ack
        p.put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, true);          // dedup on producer retries
        p.put(ProducerConfig.RETRIES_CONFIG, 3);
        p.put(ProducerConfig.MAX_BLOCK_MS_CONFIG, 5000);
        p.put(ProducerConfig.REQUEST_TIMEOUT_MS_CONFIG, 5000);   // must be <= delivery.timeout - linger
        p.put(ProducerConfig.LINGER_MS_CONFIG, 0);
        p.put(ProducerConfig.DELIVERY_TIMEOUT_MS_CONFIG, 10000);
        p.put(ProducerConfig.CLIENT_ID_CONFIG, props.service.name + "-outbox-relay");
        this.producer = new KafkaProducer<>(p);
        LOG.info("outbox relay producer ready (bootstrap={})", bootstrap);
    }

    @PreDestroy
    public void stop() {
        Producer<String, String> p = this.producer;
        if (p != null) try { p.close(); } catch (RuntimeException e) { LOG.warn("producer close failed", e); }
    }

    /**
     * One relay tick. Runs inside a tx (so {@code fetchPending}'s row lock holds) — claim,
     * publish (blocking on the ack), stamp sent_at, then refresh the pending gauge. fixedDelay
     * (not fixedRate): the next tick starts only after this one returns, so a slow broker never
     * stacks overlapping batches.
     */
    @Scheduled(fixedDelayString = "${dokandar.outbox.relay-delay-ms:1000}",
               initialDelayString = "${dokandar.outbox.relay-initial-ms:5000}")
    @Transactional
    public void relay() {
        Producer<String, String> p = this.producer;
        if (p == null) { refreshGauge(); return; }      // Kafka not configured — nothing to ship

        List<OutboxEvent> pending = outbox.fetchPending(BATCH);
        if (pending.isEmpty()) { refreshGauge(); return; }   // adaptive: no work, no Kafka I/O

        OffsetDateTime now = OffsetDateTime.now();
        int sent = 0;
        try {
            for (OutboxEvent ev : pending) {
                ProducerRecord<String, String> rec =
                        new ProducerRecord<>(ev.getTopic(), ev.getKey(), ev.getPayload());
                p.send(rec).get();                       // BLOCK for the acks=all confirmation
                ev.setSentAt(now);
                outbox.save(ev);                          // stamped only AFTER the broker confirmed
                sent++;
            }
        } catch (Exception e) {
            // A failed send aborts the loop; unsent rows keep sent_at=null → retried next tick.
            // Rethrow so the tx rolls back any partial sent_at stamps not yet committed.
            LOG.warn("outbox relay aborted after {}/{} sent: {}", sent, pending.size(), e.toString());
            throw new RuntimeException("outbox relay failed", e);
        } finally {
            metrics.outboxRelayed(sent);
        }
        refreshGauge();
    }

    private void refreshGauge() {
        try { metrics.setOutboxPending(outbox.countPending()); }
        catch (RuntimeException e) { LOG.debug("outbox gauge refresh failed: {}", e.toString()); }
    }
}
