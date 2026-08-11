package com.dokandar.catalog.domain;

import jakarta.persistence.*;
import java.time.OffsetDateTime;
import java.util.UUID;

@Entity
@Table(name = "products")
public class Product {
    @Id @GeneratedValue(strategy = GenerationType.UUID)
    @Column(name = "id") public UUID id;
    @Column(name = "owner_id", nullable = false) public UUID ownerId;
    @Column(name = "name_bn") public String nameBn;
    @Column(name = "name_en") public String nameEn;
    @Column(name = "description_bn") public String descriptionBn;
    @Column(name = "description_en") public String descriptionEn;
    @Column(name = "brand") public String brand;
    @Column(name = "sku") public String sku;
    @Column(name = "category_id") public UUID categoryId;
    @Column(name = "sharing_model", nullable = false) public String sharingModel = "shared";
    @Column(name = "list_price_minor", nullable = false) public Integer listPriceMinor;
    @Column(name = "sale_price_minor") public Integer salePriceMinor;
    @Column(name = "backorderable", nullable = false) public boolean backorderable = true;
    @Column(name = "status", nullable = false) public String status = "draft";
    @Column(name = "created_at", insertable = false, updatable = false) public OffsetDateTime createdAt;
    @Column(name = "updated_at", insertable = false, updatable = false) public OffsetDateTime updatedAt;
}
