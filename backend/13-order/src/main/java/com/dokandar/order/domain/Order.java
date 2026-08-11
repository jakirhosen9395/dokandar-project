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
 * The customer-facing order aggregate (one per checkout). Money is integer minor
 * units (paisa). Maps {@code orders} in V1__init.sql EXACTLY.
 *
 * <p>id is Hibernate-generated ({@code GenerationType.UUID}) — populated at persist,
 * so {@code orderRepo.save(o).getId()} is available for the outbox key + sub-order
 * order_id. created_at is populated app-side (the DB DEFAULT now() never fires when
 * JPA includes the column in the INSERT).
 */
@Entity
@Table(name = "orders")
public class Order {

    @Id
    @GeneratedValue(strategy = GenerationType.UUID)
    @Column(name = "id", updatable = false, nullable = false)
    private UUID id;

    @Column(name = "customer_id", nullable = false)
    private UUID customerId;

    /** The POST /orders dedup fence (UNIQUE). */
    @Column(name = "idempotency_key", length = 120, unique = true)
    private String idempotencyKey;

    @Column(name = "grand_total_minor", nullable = false)
    private int grandTotalMinor;

    @Column(name = "currency", length = 3, nullable = false)
    private String currency = "BDT";

    @Column(name = "created_at", nullable = false, updatable = false)
    private OffsetDateTime createdAt;

    public UUID getId() { return id; }
    public void setId(UUID v) { this.id = v; }

    public UUID getCustomerId() { return customerId; }
    public void setCustomerId(UUID v) { this.customerId = v; }

    public String getIdempotencyKey() { return idempotencyKey; }
    public void setIdempotencyKey(String v) { this.idempotencyKey = v; }

    public int getGrandTotalMinor() { return grandTotalMinor; }
    public void setGrandTotalMinor(int v) { this.grandTotalMinor = v; }

    public String getCurrency() { return currency; }
    public void setCurrency(String v) { this.currency = v; }

    public OffsetDateTime getCreatedAt() { return createdAt; }
    public void setCreatedAt(OffsetDateTime v) { this.createdAt = v; }
}
