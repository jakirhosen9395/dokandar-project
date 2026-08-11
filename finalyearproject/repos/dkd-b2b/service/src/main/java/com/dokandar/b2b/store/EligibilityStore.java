package com.dokandar.b2b.store;

import java.util.List;
import java.util.Optional;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.stereotype.Repository;

/**
 * Local projection of identity/fraud eligibility events (R7 conformist — DID is the master
 * identifier, no local fork). Upserts are EVENT-TIME guarded: KYC tier changes, suspensions
 * and holds arrive on DIFFERENT topics whose replay order is arbitrary, so a stale event
 * must never overwrite a newer state (same lesson as the b2c eligibility race).
 */
@Repository
public class EligibilityStore {

    public record Eligibility(String did, String kycTier, boolean suspended, boolean held, long updatedAt) {}

    private static final RowMapper<Eligibility> ROW = (rs, i) -> new Eligibility(
        rs.getString("did"), rs.getString("kyc_tier"), rs.getBoolean("suspended"),
        rs.getBoolean("held"), rs.getLong("updated_at"));

    private final JdbcTemplate jdbc;

    public EligibilityStore(JdbcTemplate jdbc) { this.jdbc = jdbc; }

    public Optional<Eligibility> find(String did) {
        List<Eligibility> rows = jdbc.query(
            "SELECT did, kyc_tier, suspended, held, updated_at FROM party_eligibility WHERE did = ?",
            ROW, did);
        return rows.stream().findFirst();
    }

    public void upsertTier(String did, String tier, long occurredAt) {
        jdbc.update(
            "INSERT INTO party_eligibility(did, kyc_tier, updated_at) VALUES (?,?,?) " +
            "ON CONFLICT (did) DO UPDATE SET kyc_tier = EXCLUDED.kyc_tier, updated_at = EXCLUDED.updated_at " +
            "WHERE party_eligibility.updated_at <= EXCLUDED.updated_at",
            did, tier, occurredAt);
    }

    public void upsertSuspended(String did, boolean suspended, long occurredAt) {
        jdbc.update(
            "INSERT INTO party_eligibility(did, suspended, updated_at) VALUES (?,?,?) " +
            "ON CONFLICT (did) DO UPDATE SET suspended = EXCLUDED.suspended, updated_at = EXCLUDED.updated_at " +
            "WHERE party_eligibility.updated_at <= EXCLUDED.updated_at",
            did, suspended, occurredAt);
    }

    public void upsertHeld(String did, boolean held, long occurredAt) {
        jdbc.update(
            "INSERT INTO party_eligibility(did, held, updated_at) VALUES (?,?,?) " +
            "ON CONFLICT (did) DO UPDATE SET held = EXCLUDED.held, updated_at = EXCLUDED.updated_at " +
            "WHERE party_eligibility.updated_at <= EXCLUDED.updated_at",
            did, held, occurredAt);
    }
}
