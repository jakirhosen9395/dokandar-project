package com.dokandar.catalog.domain;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

public interface ProductListingRepository extends JpaRepository<ProductListing, UUID> {
    @Modifying
    @Query(value = "INSERT INTO product_listings (product_id, shop_id) VALUES (CAST(:pid AS uuid), CAST(:sid AS uuid)) "
                 + "ON CONFLICT (product_id, shop_id) DO UPDATE SET visible = true", nativeQuery = true)
    int listInShop(@Param("pid") String pid, @Param("sid") String sid);

    @Query(value = "SELECT shop_id::text FROM product_listings WHERE product_id = CAST(:pid AS uuid) AND visible = true ORDER BY created_at",
           nativeQuery = true)
    List<String> visibleShopIds(@Param("pid") String pid);
}
