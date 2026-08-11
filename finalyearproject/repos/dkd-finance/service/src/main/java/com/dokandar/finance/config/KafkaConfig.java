package com.dokandar.finance.config;

import com.dokandar.finance.kafka.DlqGate;
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
 * Money-context poison policy (F-2c/F-2b). A transient consumer error (a cross-topic dependency lag —
 * wallet not yet provisioned, deposit not yet landed) retries with a BOUNDED backoff; on exhaustion the
 * poison record is parked to the per-key DLQ ({@link DlqGate}) and the offset advances, so ONE orphaned
 * record no longer blocks the whole partition (was: FixedBackOff UNLIMITED = partition parked forever).
 * A genuinely unresolvable money event resolves to the DLQ — never a silent ack+skip. Business-final
 * rejections that retrying cannot change are still ack+skipped inside the listener and never reach here.
 */
@Configuration
public class KafkaConfig {

    private static final Logger log = LoggerFactory.getLogger(KafkaConfig.class);
    // ~8 attempts x 2s ≈ 16s: covers realistic cross-topic delivery skew, then quarantine.
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
        // Unwrap the Spring listener wrapper so the DLQ records the ROOT cause (e.g. the
        // wallet-missing / insufficient_funds retry message), not the generic wrapper text.
        Throwable root = ex;
        while (root.getCause() != null && root.getCause() != root) root = root.getCause();
        String err = root.getClass().getSimpleName()
            + (root.getMessage() == null ? "" : ": " + root.getMessage());
        if (err.length() > 1000) err = err.substring(0, 1000);
        try {
            dlq.park(eventId, rec.topic(), aggKey, payload, err);
            log.error("MONEY POISON PARKED to DLQ after {} retries: topic={} key={} event={} err={}",
                MAX_RETRIES, rec.topic(), aggKey, eventId, err);
        } catch (RuntimeException dlqEx) {
            // Never lose a money event: if we cannot even park it, propagate so it retries rather than commits.
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
