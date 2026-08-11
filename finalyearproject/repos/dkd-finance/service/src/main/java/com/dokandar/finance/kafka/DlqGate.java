package com.dokandar.finance.kafka;

import com.dokandar.platform.Dlq;
import com.dokandar.platform.SqlExecutor;
import java.util.ArrayList;
import java.util.List;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

/**
 * Finance's binding of the shared PL-02 {@link Dlq} adapter to Spring {@code JdbcTemplate} (the first
 * propagation of the PL-02 quartet into a live service). Provides per-aggregate-key park-and-freeze
 * (SA-MSG-09/10): a poison money event is parked (never dropped) and its key frozen so other keys on
 * the partition keep flowing (F-2c), and a deposit-lag record resolves to the DLQ rather than a silent
 * ack+skip (F-2b).
 */
@Component
public class DlqGate {

    private final SqlExecutor exec;

    public DlqGate(JdbcTemplate jdbc) {
        // Driver-agnostic seam the SDK Dlq helper runs against: reads -> row maps, writes -> update.
        this.exec = (sql, params) -> {
            if (sql.stripLeading().regionMatches(true, 0, "SELECT", 0, 6)) {
                return new ArrayList<>(jdbc.queryForList(sql, params));
            }
            jdbc.update(sql, params);
            return List.of();
        };
    }

    /** True when this aggregate key already has a parked poison event (skip/re-park further events). */
    public boolean isKeyParked(String aggregateKey) {
        return aggregateKey != null && !aggregateKey.isBlank() && Dlq.isKeyParked(exec, aggregateKey);
    }

    /** Quarantine a poison record and freeze its aggregate key (append-only, replay-safe). */
    public void park(String eventId, String topic, String aggregateKey, String payload, String error) {
        Dlq.park(exec, new Dlq.Record(eventId, topic, aggregateKey, payload, error, aggregateKey));
    }
}
