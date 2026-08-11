package com.dokandar.catalog.domain;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;

import java.util.List;

public interface OutboxRepository extends JpaRepository<Outbox, Long> {
    @Query(value = "SELECT * FROM outbox WHERE sent_at IS NULL ORDER BY id LIMIT 100 FOR UPDATE SKIP LOCKED", nativeQuery = true)
    List<Outbox> findUnsentForUpdate();

    long countBySentAtIsNull();
}
