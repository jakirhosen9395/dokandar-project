package com.dokandar.finance.store;

import java.util.List;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.stereotype.Repository;

/** Transactional outbox: state change + event row commit atomically; the relay drains async. */
@Repository
public class OutboxStore {

    public record OutboxRow(long id, String eventId, String topic, String partitionKey,
                            String payload, long occurredAt) {}

    private static final RowMapper<OutboxRow> ROW = (rs, i) -> new OutboxRow(
        rs.getLong("id"), rs.getString("event_id"), rs.getString("topic"),
        rs.getString("partition_key"), rs.getString("payload"), rs.getLong("occurred_at"));

    private final JdbcTemplate jdbc;

    public OutboxStore(JdbcTemplate jdbc) { this.jdbc = jdbc; }

    public void insert(String eventId, String topic, String partitionKey, String payloadJson, long occurredAt) {
        jdbc.update(
            "INSERT INTO outbox(event_id, topic, partition_key, payload, occurred_at) VALUES (?,?,?,?::jsonb,?)",
            eventId, topic, partitionKey, payloadJson, occurredAt);
    }

    public List<OutboxRow> fetchUnpublished(int limit) {
        return jdbc.query(
            "SELECT id, event_id, topic, partition_key, payload::text AS payload, occurred_at " +
            "FROM outbox WHERE published_at IS NULL ORDER BY id LIMIT ?",
            ROW, Math.max(1, Math.min(limit, 500)));
    }

    public void markPublished(long id, long now) {
        jdbc.update("UPDATE outbox SET published_at = ? WHERE id = ?", now, id);
    }
}
