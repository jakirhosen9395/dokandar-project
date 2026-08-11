package com.dokandar.catalog.domain;

import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface ProductRepository extends JpaRepository<Product, UUID> {
    List<Product> findByStatusOrderByCreatedAtDesc(String status, Pageable page);
    Optional<Product> findByIdAndStatusNot(UUID id, String status);
}
