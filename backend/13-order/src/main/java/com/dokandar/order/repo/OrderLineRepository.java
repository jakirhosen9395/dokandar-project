package com.dokandar.order.repo;

import com.dokandar.order.domain.OrderLine;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.util.List;
import java.util.UUID;

@Repository
public interface OrderLineRepository extends JpaRepository<OrderLine, UUID> {

    List<OrderLine> findBySubOrderId(UUID subOrderId);
}
