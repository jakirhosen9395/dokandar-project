package com.dokandar.finance.store;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

/** Consumer inbox dedup on event_id (effectively-once, R6 fleet convention). */
@Repository
public class InboxStore {

    private final JdbcTemplate jdbc;

    public InboxStore(JdbcTemplate jdbc) { this.jdbc = jdbc; }

    /** @return true when this event has not been processed before (row inserted now, in-tx). */
    public boolean tryMark(String eventId, String topic, long now) {
        return jdbc.update(
            "INSERT INTO inbox(event_id, topic, processed_at) VALUES (?,?,?) ON CONFLICT (event_id) DO NOTHING",
            eventId, topic, now) == 1;
    }
}
