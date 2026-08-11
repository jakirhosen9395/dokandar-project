package com.dokandar.b2b.kafka;

import com.dokandar.b2b.store.OutboxStore;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.concurrent.TimeUnit;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * Drains the transactional outbox to the spine. At-least-once: a row is marked published
 * only after broker ack; consumers dedup on the event_id header. Stops at the first failure
 * to preserve per-key ordering, retries next tick.
 */
@Component
public class OutboxRelay {
    private static final Logger log = LoggerFactory.getLogger(OutboxRelay.class);
    private static final int BATCH = 200;
    private static final long SEND_TIMEOUT_S = 10;

    private final OutboxStore outbox;
    private final KafkaTemplate<String, String> kafka;

    public OutboxRelay(OutboxStore outbox, KafkaTemplate<String, String> kafka) {
        this.outbox = outbox;
        this.kafka = kafka;
    }

    @Scheduled(fixedDelay = 700)
    public void drain() {
        List<OutboxStore.OutboxRow> rows = outbox.fetchUnpublished(BATCH);
        for (OutboxStore.OutboxRow row : rows) {
            ProducerRecord<String, String> rec =
                new ProducerRecord<>(row.topic(), row.partitionKey(), row.payload());
            rec.headers().add("event_id", row.eventId().getBytes(StandardCharsets.UTF_8));
            rec.headers().add("producer_context", "b2b".getBytes(StandardCharsets.UTF_8));
            try {
                kafka.send(rec).get(SEND_TIMEOUT_S, TimeUnit.SECONDS);
                outbox.markPublished(row.id(), System.currentTimeMillis());
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return;
            } catch (Exception e) {
                log.warn("outbox publish failed for {} on {} — retrying next tick: {}",
                    row.eventId(), row.topic(), e.toString());
                return; // keep ordering: do not skip ahead of a failed row
            }
        }
    }
}
