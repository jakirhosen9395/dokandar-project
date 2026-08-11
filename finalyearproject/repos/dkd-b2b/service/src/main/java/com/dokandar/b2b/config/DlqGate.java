package com.dokandar.b2b.config;

import com.dokandar.platform.Dlq;
import com.dokandar.platform.SqlExecutor;
import java.util.ArrayList;
import java.util.List;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

/**
 * B2B's binding of the shared PL-02 {@link Dlq} adapter to Spring {@code JdbcTemplate} (B2B-F7 —
 * mirrors the finance F-2c propagation). After the bounded retry budget is exhausted, a poison trade
 * event is parked to the per-key DLQ (SA-MSG-09/10) and the offset advances, so one bad event no
 * longer blocks the whole partition forever (was: {@code FixedBackOff(2s, UNLIMITED)} = park forever).
 */
@Component
public class DlqGate {

    private final SqlExecutor exec;

    public DlqGate(JdbcTemplate jdbc) {
        this.exec = (sql, params) -> {
            if (sql.stripLeading().regionMatches(true, 0, "SELECT", 0, 6)) {
                return new ArrayList<>(jdbc.queryForList(sql, params));
            }
            jdbc.update(sql, params);
            return List.of();
        };
    }

    /** True when this aggregate key already has a parked poison event. */
    public boolean isKeyParked(String aggregateKey) {
        return aggregateKey != null && !aggregateKey.isBlank() && Dlq.isKeyParked(exec, aggregateKey);
    }

    /** Quarantine a poison record and freeze its aggregate key (append-only, replay-safe). */
    public void park(String eventId, String topic, String aggregateKey, String payload, String error) {
        Dlq.park(exec, new Dlq.Record(eventId, topic, aggregateKey, payload, error, aggregateKey));
    }
}
