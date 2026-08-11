package com.dokandar.order.domain;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

import java.util.UUID;

/**
 * A line item within a sub-order. sale_price_minor is nullable (discounted unit
 * price); all other money is integer minor units. Maps {@code order_lines} in
 * V1__init.sql EXACTLY. sub_order_id is an opaque UUID (no @ManyToOne).
 */
@Entity
@Table(name = "order_lines")
public class OrderLine {

    @Id
    @GeneratedValue(strategy = GenerationType.UUID)
    @Column(name = "id", updatable = false, nullable = false)
    private UUID id;

    @Column(name = "sub_order_id", nullable = false)
    private UUID subOrderId;

    @Column(name = "product_id", nullable = false)
    private UUID productId;

    @Column(name = "variant_id", nullable = false)
    private UUID variantId;

    @Column(name = "quantity", nullable = false)
    private int quantity;

    @Column(name = "unit_price_minor", nullable = false)
    private int unitPriceMinor;

    /** Nullable: discounted unit price. */
    @Column(name = "sale_price_minor")
    private Integer salePriceMinor;

    @Column(name = "line_total_minor", nullable = false)
    private int lineTotalMinor;

    public UUID getId() { return id; }
    public void setId(UUID v) { this.id = v; }

    public UUID getSubOrderId() { return subOrderId; }
    public void setSubOrderId(UUID v) { this.subOrderId = v; }

    public UUID getProductId() { return productId; }
    public void setProductId(UUID v) { this.productId = v; }

    public UUID getVariantId() { return variantId; }
    public void setVariantId(UUID v) { this.variantId = v; }

    public int getQuantity() { return quantity; }
    public void setQuantity(int v) { this.quantity = v; }

    public int getUnitPriceMinor() { return unitPriceMinor; }
    public void setUnitPriceMinor(int v) { this.unitPriceMinor = v; }

    public Integer getSalePriceMinor() { return salePriceMinor; }
    public void setSalePriceMinor(Integer v) { this.salePriceMinor = v; }

    public int getLineTotalMinor() { return lineTotalMinor; }
    public void setLineTotalMinor(int v) { this.lineTotalMinor = v; }
}
