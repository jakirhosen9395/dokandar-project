package com.dokandar.finance.store;

import com.dokandar.finance.domain.EscrowStatus;
import java.util.Optional;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.stereotype.Repository;

/** Escrow rows. Status moves only via compare-and-set transitions guarded by EscrowStatus. */
@Repository
public class EscrowStore {

    public record EscrowRow(String esc, String referenceId, String referenceType, String buyerWlt,
                            String sellerWlt, long amountPoisha, EscrowStatus status, String podEvidence,
                            String reason, long createdAt, Long releasedAt, Long coolingOffExpiresAt, Long closedAt) {}

    private static final RowMapper<EscrowRow> ROW = (rs, i) -> new EscrowRow(
        rs.getString("esc"), rs.getString("reference_id"), rs.getString("reference_type"),
        rs.getString("buyer_wlt"), rs.getString("seller_wlt"), rs.getLong("amount_poisha"),
        EscrowStatus.valueOf(rs.getString("status")), rs.getString("pod_evidence"), rs.getString("reason"),
        rs.getLong("created_at"), (Long) rs.getObject("released_at"),
        (Long) rs.getObject("cooling_off_expires_at"), (Long) rs.getObject("closed_at"));

    private final JdbcTemplate jdbc;

    public EscrowStore(JdbcTemplate jdbc) { this.jdbc = jdbc; }

    /** @return false when an escrow already exists for this (referenceId, referenceType). */
    public boolean insert(String esc, String referenceId, String referenceType, String buyerWlt,
                          String sellerWlt, long amountPoisha, long now) {
        return jdbc.update(
            "INSERT INTO escrows(esc, reference_id, reference_type, buyer_wlt, seller_wlt, amount_poisha, " +
            "status, created_at) VALUES (?,?,?,?,?,?,'ACTIVE',?) " +
            "ON CONFLICT (reference_id, reference_type) DO NOTHING",
            esc, referenceId, referenceType, buyerWlt, sellerWlt, amountPoisha, now) == 1;
    }

    public Optional<EscrowRow> find(String esc) {
        return jdbc.query("SELECT * FROM escrows WHERE esc = ?", ROW, esc).stream().findFirst();
    }

    public Optional<EscrowRow> lock(String esc) {
        return jdbc.query("SELECT * FROM escrows WHERE esc = ? FOR UPDATE", ROW, esc).stream().findFirst();
    }

    public Optional<EscrowRow> lockByReference(String referenceId, String referenceType) {
        return jdbc.query("SELECT * FROM escrows WHERE reference_id = ? AND reference_type = ? FOR UPDATE",
            ROW, referenceId, referenceType).stream().findFirst();
    }

    /** Non-locking reference lookup — event handlers pre-read here so the subsequent
     *  release/reverse acquires wallets-sorted-then-escrow (never escrow-first, reviewer H-1). */
    public Optional<EscrowRow> findByReference(String referenceId, String referenceType) {
        return jdbc.query("SELECT * FROM escrows WHERE reference_id = ? AND reference_type = ?",
            ROW, referenceId, referenceType).stream().findFirst();
    }

    /** Compare-and-set transition; the WHERE-status guard makes replays no-ops at the row level. */
    public boolean transition(String esc, EscrowStatus from, EscrowStatus to, String podEvidence,
                              String reason, Long releasedAt, Long coolingOffExpiresAt, Long closedAt) {
        if (!from.canTransitionTo(to))
            throw new IllegalStateException("illegal escrow transition " + from + " -> " + to);
        return jdbc.update(
            "UPDATE escrows SET status = ?, pod_evidence = COALESCE(?, pod_evidence), " +
            "reason = COALESCE(?, reason), released_at = COALESCE(?, released_at), " +
            "cooling_off_expires_at = COALESCE(?, cooling_off_expires_at), closed_at = COALESCE(?, closed_at) " +
            "WHERE esc = ? AND status = ?",
            to.name(), podEvidence, reason, releasedAt, coolingOffExpiresAt, closedAt, esc, from.name()) == 1;
    }
}
