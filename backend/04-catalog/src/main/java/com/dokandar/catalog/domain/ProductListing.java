package com.dokandar.catalog.domain;

import jakarta.persistence.*;
import java.time.OffsetDateTime;
import java.util.UUID;

@Entity
@Table(name = "product_listings")
public class ProductListing {
    @Id @GeneratedValue(strategy = GenerationType.UUID)
    @Column(name = "id") public UUID id;
    @Column(name = "product_id", nullable = false) public UUID productId;
    @Column(name = "shop_id", nullable = false) public UUID shopId;
    @Column(name = "visible", nullable = false) public boolean visible = true;
    @Column(name = "created_at", insertable = false, updatable = false) public OffsetDateTime createdAt;
}
