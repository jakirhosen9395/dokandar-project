package com.dokandar.finance.store;

import java.util.Optional;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

/**
 * Command idempotency for REST writes: the response is stored in the SAME transaction
 * as the state change, keyed (Idempotency-Key, endpoint). A replayed key with the same
 * request hash returns the stored response byte-for-byte; a different hash is a conflict.
 */
@Repository
public class IdemStore {

    public record StoredResponse(String requestHash, int status, String bodyJson) {}

    private final JdbcTemplate jdbc;

    public IdemStore(JdbcTemplate jdbc) { this.jdbc = jdbc; }

    public Optional<StoredResponse> find(String idemKey, String endpoint) {
        return jdbc.query(
            "SELECT request_hash, response_status, response_body::text FROM cmd_idempotency " +
            "WHERE idem_key = ? AND endpoint = ?",
            (rs, i) -> new StoredResponse(rs.getString(1), rs.getInt(2), rs.getString(3)),
            idemKey, endpoint).stream().findFirst();
    }

    /** Insert inside the command transaction; a PK collision aborts the tx (concurrent duplicate). */
    public void insert(String idemKey, String endpoint, String requestHash, int status, String bodyJson, long now) {
        jdbc.update(
            "INSERT INTO cmd_idempotency(idem_key, endpoint, request_hash, response_status, response_body, created_at) " +
            "VALUES (?,?,?,?,?::jsonb,?)",
            idemKey, endpoint, requestHash, status, bodyJson, now);
    }
}
