package com.dokandar.order.domain;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.type.SqlTypes;

import java.time.OffsetDateTime;

/**
 * Transactional-outbox row. Written in the SAME DB tx as the business row; the relay
 * polls {@code sent_at IS NULL ... FOR UPDATE SKIP LOCKED} and stamps sent_at after the
 * Kafka send. Maps {@code outbox} in V1__init.sql EXACTLY.
 *
 * <p>IMPORTANT: unlike the UUID aggregates, {@code outbox.id} is bigserial → {@code Long}
 * with {@code GenerationType.IDENTITY}. {@code payload} is jsonb — Hibernate would map a
 * plain String to varchar (which Postgres rejects into jsonb), so it carries
 * {@code @JdbcTypeCode(SqlTypes.JSON)}. created_at is app-side populated.
 */
@Entity
@Table(name = "outbox")
public class OutboxEvent {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    @Column(name = "id", updatable = false, nullable = false)
    private Long id;

    @Column(name = "topic", length = 120, nullable = false)
    private String topic;

    /** Partition key = order_id / sub_order_id (nullable per schema). */
    @Column(name = "key", length = 120)
    private String key;

    @JdbcTypeCode(SqlTypes.JSON)
    @Column(name = "payload", nullable = false)
    private String payload;

    @Column(name = "created_at", nullable = false, updatable = false)
    private OffsetDateTime createdAt;

    @Column(name = "sent_at")
    private OffsetDateTime sentAt;

    public Long getId() { return id; }
    public void setId(Long v) { this.id = v; }

    public String getTopic() { return topic; }
    public void setTopic(String v) { this.topic = v; }

    public String getKey() { return key; }
    public void setKey(String v) { this.key = v; }

    public String getPayload() { return payload; }
    public void setPayload(String v) { this.payload = v; }

    public OffsetDateTime getCreatedAt() { return createdAt; }
    public void setCreatedAt(OffsetDateTime v) { this.createdAt = v; }

    public OffsetDateTime getSentAt() { return sentAt; }
    public void setSentAt(OffsetDateTime v) { this.sentAt = v; }
}
