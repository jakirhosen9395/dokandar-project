// HAND-AUTHORED platform primitive (NOT dkdgen-generated).
// PL-02 — shared outbox/inbox/DLQ effectively-once quartet (EF §21.1 / EF-EVT-6 / SA-CONV-QUARTET,
// SA-MSG-09/10). One of five runtime implementations exposing the SAME contract; the fleet stops
// hand-rolling these per service (GAP-REPORT PL-02).
package com.dokandar.platform;

import java.util.List;
import java.util.Map;

/**
 * Minimal, driver-agnostic DB-execution seam for the outbox/inbox/DLQ helpers.
 *
 * <p>Single abstract method {@link #execute(String, Object...)} — the caller supplies the concrete
 * transaction/connection handle (JDBC {@code JdbcTemplate}, a pooled {@code Connection}, an in-memory
 * fake, ...). Writes return an empty list; reads return one {@code Map<column,value>} per row in
 * result order. The helper never imports JDBC/pgx/Npgsql/psycopg/pg — the service binds the real
 * handle at the later propagation step, and unit tests bind an in-memory fake (no live DB required).
 *
 * <p>Atomicity contract: for {@code enqueue}/{@code markProcessed}/{@code alreadyProcessed} the caller
 * MUST pass the SAME executor that is running the aggregate write's transaction, so the event row and
 * the state change commit together (SA-CONV-QUARTET).
 */
@FunctionalInterface
public interface SqlExecutor {

    /**
     * Execute {@code sql} with positional {@code params}.
     *
     * @return rows for a query (each a column-keyed map, in result order); an empty list for a write.
     */
    List<Map<String, Object>> execute(String sql, Object... params);
}
