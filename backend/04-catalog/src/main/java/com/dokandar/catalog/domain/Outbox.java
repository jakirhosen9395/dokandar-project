package com.dokandar.catalog.domain;

import jakarta.persistence.*;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.type.SqlTypes;
import java.time.OffsetDateTime;

@Entity
@Table(name = "outbox")
public class Outbox {
    @Id @GeneratedValue(strategy = GenerationType.IDENTITY)
    @Column(name = "id") public Long id;
    @Column(name = "topic", nullable = false) public String topic;
    @Column(name = "key") public String key;
    @Column(name = "payload", nullable = false) @JdbcTypeCode(SqlTypes.JSON) public String payload;
    @Column(name = "created_at", insertable = false, updatable = false) public OffsetDateTime createdAt;
    @Column(name = "sent_at") public OffsetDateTime sentAt;

    public Outbox() {}
    public Outbox(String topic, String key, String payload) { this.topic = topic; this.key = key; this.payload = payload; }
}
