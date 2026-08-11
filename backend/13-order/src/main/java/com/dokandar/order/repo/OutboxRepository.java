package com.dokandar.order.repo;

import com.dokandar.order.domain.OutboxEvent;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.stereotype.Repository;

import java.util.List;

/**
 * Outbox relay access. NOTE: the id type is {@code Long} (bigserial), NOT UUID.
 */
@Repository
public interface OutboxRepository extends JpaRepository<OutboxEvent, Long> {

    /**
     * The relay claim: oldest-first unsent rows, row-locked with SKIP LOCKED so
     * concurrent relay instances never contend. Must run inside a tx; stamp sent_at
     * and flush before the tx commits.
     */
    @Query(value = "SELECT * FROM outbox WHERE sent_at IS NULL ORDER BY id LIMIT :lim FOR UPDATE SKIP LOCKED",
           nativeQuery = true)
    List<OutboxEvent> fetchPending(@Param("lim") int lim);

    /** Backs the {@code order_outbox_pending} gauge on /metrics. */
    @Query("select count(o) from OutboxEvent o where o.sentAt is null")
    long countPending();
}
