package com.dokandar.catalog.messaging;

import com.dokandar.catalog.domain.Outbox;
import com.dokandar.catalog.domain.OutboxRepository;
import com.dokandar.catalog.observability.CatalogMetrics;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.List;

/**
 * Drains the outbox at 1 Hz. Polls {@code WHERE sent_at IS NULL ORDER BY id
 * LIMIT 100 FOR UPDATE SKIP LOCKED} (§16-c — multi-replica safe), publishes with
 * {@code acks=all} (KafkaTemplate.get() waits for the broker ack), then stamps
 * sent_at. On send failure the row stays unsent and the next tick retries.
 * {@code catalog_outbox_pending} exposes relay lag.
 */
@Component
public class OutboxRelay {

    private static final Logger LOG = LoggerFactory.getLogger(OutboxRelay.class);

    private final OutboxRepository repo;
    private final KafkaTemplate<String, String> kafka;
    private final CatalogMetrics metrics;

    public OutboxRelay(OutboxRepository repo, KafkaTemplate<String, String> kafka, CatalogMetrics metrics) {
        this.repo = repo; this.kafka = kafka; this.metrics = metrics;
    }

    @Scheduled(fixedDelay = 1000)
    @Transactional
    public void tick() {
        List<Outbox> rows = repo.findUnsentForUpdate();
        long relayed = 0;
        for (Outbox r : rows) {
            try {
                kafka.send(r.topic, r.key, r.payload).get();
                r.sentAt = OffsetDateTime.now();
                relayed++;
            } catch (Exception e) {
                LOG.warn("outbox send failed topic={} key={}: {}", r.topic, r.key, e.getMessage());
                break;   // back off — retry next tick
            }
        }
        if (relayed > 0) { repo.saveAll(rows.subList(0, (int) relayed)); metrics.outboxRelayed(relayed); }
        metrics.setOutboxPending(repo.countBySentAtIsNull());
    }
}
