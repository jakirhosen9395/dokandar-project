package com.dokandar.order.messaging;

import com.dokandar.order.api.OrderWriteService;
import com.dokandar.order.config.OrderProperties;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.consumer.ConsumerRecords;
import org.apache.kafka.clients.consumer.KafkaConsumer;
import org.apache.kafka.common.TopicPartition;
import org.apache.kafka.common.errors.WakeupException;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.util.List;
import java.util.Properties;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * The {@code payment.settled} consumer (the consumer side of the order seam). Hand-rolled on
 * {@code org.apache.kafka.clients} — the project carries the Kafka client but does NOT configure
 * {@code spring.kafka} against {@code dokandar.kafka.bootstrap}, so a {@code @KafkaListener} would
 * silently bind to {@code localhost:9092}; building the consumer here keeps ONE config source
 * (the same {@code bootstrap} {@code /health} probes and the outbox relay uses).
 *
 * <p>Commit-after-handle: {@code enable.auto.commit=false}; we {@code commitSync()} ONLY after the
 * DB tx in {@link OrderWriteService#confirmFromPayment} returns. A crash before the commit
 * redelivers the event — harmless because {@code confirmFromPayment} only advances sub-orders that
 * are still {@code placed} (UNIQUE-effect idempotency). One poll loop on a dedicated daemon thread,
 * started {@code @PostConstruct}, woken + joined at shutdown.
 */
@Component
public class PaymentSettledConsumer {

    private static final Logger LOG = LoggerFactory.getLogger(PaymentSettledConsumer.class);
    private static final String GROUP = "order-payment";
    private static final ObjectMapper MAPPER = new ObjectMapper();

    private final OrderWriteService writes;
    private final OrderProperties props;

    private volatile KafkaConsumer<String, String> consumer;
    private final AtomicBoolean running = new AtomicBoolean(false);
    private ExecutorService exec;

    public PaymentSettledConsumer(OrderWriteService writes, OrderProperties props) {
        this.writes = writes;
        this.props = props;
    }

    @PostConstruct
    public void start() {
        String bootstrap = props.kafka.bootstrap;
        if (bootstrap == null || bootstrap.isBlank()) {
            LOG.warn("KAFKA_BOOTSTRAP unset — payment.settled consumer disabled (placed→confirmed will not advance)");
            return;
        }
        Properties p = new Properties();
        p.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrap);
        p.put(ConsumerConfig.GROUP_ID_CONFIG, GROUP);
        p.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        p.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        p.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, false);     // commit-after-handle
        p.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
        p.put(ConsumerConfig.MAX_POLL_RECORDS_CONFIG, 50);
        p.put(ConsumerConfig.CLIENT_ID_CONFIG, props.service.name + "-payment-settled");
        this.consumer = new KafkaConsumer<>(p);
        this.consumer.subscribe(List.of(props.topic.paymentSettled));
        this.running.set(true);
        this.exec = Executors.newSingleThreadExecutor(r -> {
            Thread t = new Thread(r, "payment-settled-consumer");
            t.setDaemon(true);
            return t;
        });
        this.exec.submit(this::pollLoop);
        LOG.info("payment.settled consumer subscribed topic={} group={} bootstrap={}",
                props.topic.paymentSettled, GROUP, bootstrap);
    }

    private void pollLoop() {
        try {
            while (running.get()) {
                ConsumerRecords<String, String> recs = consumer.poll(Duration.ofMillis(1000));
                boolean ok = true;
                for (ConsumerRecord<String, String> rec : recs) {
                    try {
                        handle(rec.value());
                    } catch (Exception e) {
                        // poll() already advanced the in-memory position, so NOT committing does not
                        // by itself redeliver this session. Rewind the partition to the failed offset
                        // and abort the batch — the next poll re-reads from here (idempotent handle),
                        // and crucially we STAY in the while loop so the consumer is never killed by a
                        // transient DB blip (a return/break here would stop all placed→confirmed advance).
                        LOG.warn("payment.settled handle failed; rewind+retry key={}: {}", rec.key(), e.toString());
                        consumer.seek(new TopicPartition(rec.topic(), rec.partition()), rec.offset());
                        ok = false;
                        break;
                    }
                }
                if (ok && !recs.isEmpty()) consumer.commitSync();   // commit ONLY after the whole batch handled
            }
        } catch (WakeupException ignore) {
            // shutdown-initiated wakeup
        } catch (Exception e) {
            LOG.error("payment.settled consumer loop terminated: {}", e.toString(), e);
        } finally {
            try { consumer.close(); } catch (RuntimeException e) { LOG.warn("consumer close failed", e); }
        }
    }

    /**
     * On a {@code payment.settled} message, resolve the order id and advance its sub-orders
     * {@code placed→confirmed}. Tolerates a few payload shapes: {@code order_id}, nested under
     * {@code order.id}, or {@code data.order_id} (09-payment is Elixir — field names not pinned
     * in this repo, so we probe the common keys). A message with no resolvable order id is a no-op.
     */
    private void handle(String value) throws Exception {
        if (value == null || value.isBlank()) return;
        JsonNode root = MAPPER.readTree(value);
        String orderIdStr = firstNonBlank(
                text(root, "order_id"),
                text(root.path("order"), "id"),
                text(root.path("data"), "order_id"),
                text(root.path("payload"), "order_id"));
        if (orderIdStr == null) {
            LOG.debug("payment.settled with no order_id — ignored");
            return;
        }
        UUID orderId;
        try { orderId = UUID.fromString(orderIdStr); }
        catch (IllegalArgumentException e) { LOG.warn("payment.settled order_id not a UUID: {}", orderIdStr); return; }

        int advanced = writes.confirmFromPayment(orderId);   // separate @Transactional bean → real tx
        LOG.info("payment.settled order={} advanced {} sub-order(s) placed→confirmed", orderId, advanced);
    }

    @PreDestroy
    public void stop() {
        running.set(false);
        KafkaConsumer<String, String> c = this.consumer;
        if (c != null) c.wakeup();
        if (exec != null) {
            exec.shutdown();
            try { exec.awaitTermination(5, java.util.concurrent.TimeUnit.SECONDS); }
            catch (InterruptedException e) { Thread.currentThread().interrupt(); }
        }
    }

    private static String text(JsonNode node, String field) {
        JsonNode v = node == null ? null : node.get(field);
        return v == null || v.isNull() ? null : v.asText();
    }
    private static String firstNonBlank(String... candidates) {
        for (String c : candidates) if (c != null && !c.isBlank()) return c;
        return null;
    }
}
