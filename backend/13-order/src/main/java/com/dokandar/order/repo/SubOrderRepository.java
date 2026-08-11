package com.dokandar.order.repo;

import com.dokandar.order.domain.SubOrder;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.stereotype.Repository;

import java.util.List;
import java.util.UUID;

@Repository
public interface SubOrderRepository extends JpaRepository<SubOrder, UUID> {

    List<SubOrder> findByOrderId(UUID orderId);

    /**
     * Backs Order.HasPurchased — has this customer ever ordered this product?
     * Native query (entities are plain-UUID, no @ManyToOne to path-navigate; also
     * keeps the reserved word {@code Order} out of JPQL). Reaches orders.customer_id
     * (not on sub_orders) via the join order_lines → sub_orders → orders.
     */
    @Query(value = """
            SELECT EXISTS(
              SELECT 1
                FROM order_lines ol
                JOIN sub_orders so ON so.id = ol.sub_order_id
                JOIN orders o      ON o.id  = so.order_id
               WHERE o.customer_id = :customerId
                 AND ol.product_id = :productId
            )
            """, nativeQuery = true)
    boolean hasPurchased(@Param("customerId") UUID customerId,
                         @Param("productId") UUID productId);
}
