package com.dokandar.catalog.domain;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

public interface ProductVariantRepository extends JpaRepository<ProductVariant, UUID> {
    List<ProductVariant> findByProductIdOrderByCreatedAt(UUID productId);

    @Modifying
    @Query("DELETE FROM ProductVariant v WHERE v.id = :vid AND v.productId = :pid")
    int deleteByIdAndProduct(@Param("vid") UUID vid, @Param("pid") UUID pid);
}
