package com.dokandar.b2b.config;

import java.nio.charset.StandardCharsets;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.common.header.Header;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.kafka.listener.CommonErrorHandler;
import org.springframework.kafka.listener.DefaultErrorHandler;
import org.springframework.util.backoff.FixedBackOff;

/**
 * Poison policy (B2B-F7). A transient consumer error retries with a BOUNDED backoff; on exhaustion the
 * poison record is parked to the per-key DLQ ({@link DlqGate}) and the offset advances, so ONE bad
 * record no longer blocks the whole partition forever (was: {@code FixedBackOff(2s, UNLIMITED)} =
 * partition parked forever). A genuinely unresolvable event resolves to the DLQ — never a silent drop.
 * Business-final rejections are ack+skipped inside the listener and never reach this handler.
 */
@Configuration
public class KafkaConfig {

    private static final Logger log = LoggerFactory.getLogger(KafkaConfig.class);
    private static final long RETRY_INTERVAL_MS = 2000L;
    private static final long MAX_RETRIES = 8L;

    @Bean
    public CommonErrorHandler kafkaErrorHandler(DlqGate dlq) {
        DefaultErrorHandler handler = new DefaultErrorHandler((rec, ex) -> recover(dlq, rec, ex),
            new FixedBackOff(RETRY_INTERVAL_MS, MAX_RETRIES));
        handler.setCommitRecovered(true); // after DLQ-park, advance the offset so the partition flows
        return handler;
    }

    private static void recover(DlqGate dlq, ConsumerRecord<?, ?> rec, Exception ex) {
        String key = rec.key() == null ? null : rec.key().toString();
        String eventId = eventIdOf(rec);
        String aggKey = (key == null || key.isBlank()) ? eventId : key;
        String payload = rec.value() == null ? "{}" : rec.value().toString();
        Throwable root = ex;
        while (root.getCause() != null && root.getCause() != root) root = root.getCause();
        String err = root.getClass().getSimpleName()
            + (root.getMessage() == null ? "" : ": " + root.getMessage());
        if (err.length() > 1000) err = err.substring(0, 1000);
        try {
            dlq.park(eventId, rec.topic(), aggKey, payload, err);
            log.error("B2B POISON PARKED to DLQ after {} retries: topic={} key={} event={} err={}",
                MAX_RETRIES, rec.topic(), aggKey, eventId, err);
        } catch (RuntimeException dlqEx) {
            // Never lose a trade event: if we cannot even park it, propagate so it retries not commits.
            log.error("DLQ park FAILED (topic={} event={}) — propagating to retry: {}",
                rec.topic(), eventId, dlqEx.toString());
            throw dlqEx;
        }
    }

    private static String eventIdOf(ConsumerRecord<?, ?> rec) {
        Header h = rec.headers().lastHeader("event_id");
        if (h != null) return new String(h.value(), StandardCharsets.UTF_8);
        return rec.topic() + "/" + rec.partition() + "/" + rec.offset();
    }
}
