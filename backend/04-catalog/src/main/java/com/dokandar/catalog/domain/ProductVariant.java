package com.dokandar.catalog.domain;

import jakarta.persistence.*;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.type.SqlTypes;
import java.time.OffsetDateTime;
import java.util.UUID;

@Entity
@Table(name = "product_variants")
public class ProductVariant {
    @Id @GeneratedValue(strategy = GenerationType.UUID)
    @Column(name = "id") public UUID id;
    @Column(name = "product_id", nullable = false) public UUID productId;
    @Column(name = "name_bn") public String nameBn;
    @Column(name = "name_en") public String nameEn;
    @Column(name = "attributes") @JdbcTypeCode(SqlTypes.JSON) public String attributes;   // jsonb, raw JSON text
    @Column(name = "list_price_minor", nullable = false) public Integer listPriceMinor;
    @Column(name = "sale_price_minor") public Integer salePriceMinor;
    @Column(name = "sku") public String sku;
    @Column(name = "created_at", insertable = false, updatable = false) public OffsetDateTime createdAt;
    @Column(name = "updated_at", insertable = false, updatable = false) public OffsetDateTime updatedAt;
}
