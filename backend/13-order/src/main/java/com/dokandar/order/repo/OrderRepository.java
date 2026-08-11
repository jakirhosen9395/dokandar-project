package com.dokandar.order.repo;

import com.dokandar.order.domain.Order;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

@Repository
public interface OrderRepository extends JpaRepository<Order, UUID> {

    /** The POST /orders dedup fence — same key returns the existing order. */
    Optional<Order> findByIdempotencyKey(String idempotencyKey);

    /** Customer order history, newest first (matches idx_orders_customer). */
    List<Order> findByCustomerIdOrderByCreatedAtDesc(UUID customerId);
}
