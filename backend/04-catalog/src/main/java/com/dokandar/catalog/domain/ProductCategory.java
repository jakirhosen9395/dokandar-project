package com.dokandar.catalog.domain;

import jakarta.persistence.*;
import java.time.OffsetDateTime;
import java.util.UUID;

@Entity
@Table(name = "product_categories")
public class ProductCategory {
    @Id @GeneratedValue(strategy = GenerationType.UUID)
    @Column(name = "id") public UUID id;
    @Column(name = "name_bn", nullable = false) public String nameBn;
    @Column(name = "name_en", nullable = false) public String nameEn;
    @Column(name = "parent_id") public UUID parentId;
    @Column(name = "defined_by", nullable = false) public String definedBy;
    @Column(name = "owner_id") public UUID ownerId;
    @Column(name = "created_at", insertable = false, updatable = false) public OffsetDateTime createdAt;
}
