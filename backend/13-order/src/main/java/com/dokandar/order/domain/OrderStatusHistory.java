package com.dokandar.order.domain;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * Append-only sub-order status transition audit. {@code at} is populated app-side
 * (the DB DEFAULT now() never fires when JPA includes the column). from_status is
 * nullable (the initial 'placed' has no prior state). Maps {@code order_status_history}.
 */
@Entity
@Table(name = "order_status_history")
public class OrderStatusHistory {

    @Id
    @GeneratedValue(strategy = GenerationType.UUID)
    @Column(name = "id", updatable = false, nullable = false)
    private UUID id;

    @Column(name = "sub_order_id", nullable = false)
    private UUID subOrderId;

    @Column(name = "from_status", length = 32)
    private String fromStatus;

    @Column(name = "to_status", length = 32, nullable = false)
    private String toStatus;

    @Column(name = "at", nullable = false, updatable = false)
    private OffsetDateTime at;

    public UUID getId() { return id; }
    public void setId(UUID v) { this.id = v; }

    public UUID getSubOrderId() { return subOrderId; }
    public void setSubOrderId(UUID v) { this.subOrderId = v; }

    public String getFromStatus() { return fromStatus; }
    public void setFromStatus(String v) { this.fromStatus = v; }

    public String getToStatus() { return toStatus; }
    public void setToStatus(String v) { this.toStatus = v; }

    public OffsetDateTime getAt() { return at; }
    public void setAt(OffsetDateTime v) { this.at = v; }
}
