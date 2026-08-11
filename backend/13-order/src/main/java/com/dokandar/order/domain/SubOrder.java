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
 * One sub-order per shop within an order. status / payment_state / delivery_method
 * carry the CHECK-constrained string enums verbatim from the schema (kept as String —
 * the DB enforces the closed set). Maps {@code sub_orders} in V1__init.sql EXACTLY.
 *
 * <p>order_id is an opaque UUID (no @ManyToOne — cross-row refs stay plain so repos
 * query by UUID and the saga sets it directly from the parent Order's generated id).
 */
@Entity
@Table(name = "sub_orders")
public class SubOrder {

    @Id
    @GeneratedValue(strategy = GenerationType.UUID)
    @Column(name = "id", updatable = false, nullable = false)
    private UUID id;

    @Column(name = "order_id", nullable = false)
    private UUID orderId;

    @Column(name = "shop_id", nullable = false)
    private UUID shopId;

    @Column(name = "status", length = 32, nullable = false)
    private String status = "placed";

    @Column(name = "payment_state", length = 16, nullable = false)
    private String paymentState = "pending";

    @Column(name = "delivery_method", length = 16, nullable = false)
    private String deliveryMethod = "delivery";

    @Column(name = "shop_total_minor", nullable = false)
    private int shopTotalMinor;

    @Column(name = "confirmed_at")
    private OffsetDateTime confirmedAt;

    @Column(name = "created_at", nullable = false, updatable = false)
    private OffsetDateTime createdAt;

    public UUID getId() { return id; }
    public void setId(UUID v) { this.id = v; }

    public UUID getOrderId() { return orderId; }
    public void setOrderId(UUID v) { this.orderId = v; }

    public UUID getShopId() { return shopId; }
    public void setShopId(UUID v) { this.shopId = v; }

    public String getStatus() { return status; }
    public void setStatus(String v) { this.status = v; }

    public String getPaymentState() { return paymentState; }
    public void setPaymentState(String v) { this.paymentState = v; }

    public String getDeliveryMethod() { return deliveryMethod; }
    public void setDeliveryMethod(String v) { this.deliveryMethod = v; }

    public int getShopTotalMinor() { return shopTotalMinor; }
    public void setShopTotalMinor(int v) { this.shopTotalMinor = v; }

    public OffsetDateTime getConfirmedAt() { return confirmedAt; }
    public void setConfirmedAt(OffsetDateTime v) { this.confirmedAt = v; }

    public OffsetDateTime getCreatedAt() { return createdAt; }
    public void setCreatedAt(OffsetDateTime v) { this.createdAt = v; }
}
