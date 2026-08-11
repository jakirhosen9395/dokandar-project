package com.dokandar.finance.store;

import com.dokandar.finance.domain.Postings;
import java.util.List;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.stereotype.Repository;

/**
 * Append-only double-entry ledger (WORM trigger blocks UPDATE/DELETE at the DB).
 * Balances are ALWAYS derived from entries (BR-028) — never stored.
 * Convention: CREDIT increases an account, DEBIT decreases it (liability-style wallets).
 */
@Repository
public class LedgerStore {

    public record EntryRow(long id, String txnId, String account, String entryType, long amountPoisha,
                           String counterpartAccount, String referenceId, String referenceType,
                           boolean isWithdrawable, long createdAt) {}

    private static final RowMapper<EntryRow> ENTRY = (rs, i) -> new EntryRow(
        rs.getLong("id"), rs.getString("txn_id"), rs.getString("account"), rs.getString("entry_type"),
        rs.getLong("amount_poisha"), rs.getString("counterpart_account"), rs.getString("reference_id"),
        rs.getString("reference_type"), rs.getBoolean("is_withdrawable"), rs.getLong("created_at"));

    private final JdbcTemplate jdbc;

    public LedgerStore(JdbcTemplate jdbc) { this.jdbc = jdbc; }

    /** Appends a balanced posting set under one txn id. Only {@link Postings} can reach here. */
    public void append(String txnId, Postings postings, String idempotencyKey, long now) {
        if (idempotencyKey != null && !idempotencyKey.isBlank()) {
            // F-7: ledger-level effectively-once — a re-append carrying the same canon idempotency
            // key (e.g. ESC:<esc>:release:<ord>) is a no-op; the legs were already written once.
            int claimed = jdbc.update(
                "INSERT INTO ledger_idempotency(idempotency_key, txn_id, created_at) VALUES (?,?,?) "
                    + "ON CONFLICT (idempotency_key) DO NOTHING",
                idempotencyKey, txnId, now);
            if (claimed == 0) {
                return; // duplicate command — the balanced posting set is already in the ledger
            }
        }
        for (Postings.Posting p : postings.legs()) {
            jdbc.update(
                "INSERT INTO ledger_entries(txn_id, account, entry_type, amount_poisha, counterpart_account, " +
                "reference_id, reference_type, is_withdrawable, idempotency_key, created_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
                txnId, p.account(), p.entryType(), p.amountPoisha(), p.counterpartAccount(),
                p.referenceId(), p.referenceType(), p.isWithdrawable(), idempotencyKey, now);
        }
    }

    public long balance(String account) {
        Long v = jdbc.queryForObject(
            "SELECT COALESCE(SUM(CASE WHEN entry_type = 'CREDIT' THEN amount_poisha ELSE -amount_poisha END), 0) " +
            "FROM ledger_entries WHERE account = ?", Long.class, account);
        return v == null ? 0L : v;
    }

    /** Credits parked behind a settlement hold: non-withdrawable until the funding escrow releases. */
    public long heldNonWithdrawable(String account) {
        Long v = jdbc.queryForObject(
            "SELECT COALESCE(SUM(le.amount_poisha), 0) FROM ledger_entries le " +
            "JOIN escrows e ON e.esc = le.reference_id " +
            "WHERE le.account = ? AND le.entry_type = 'CREDIT' AND le.is_withdrawable = FALSE " +
            "AND e.status = 'SETTLEMENT_HELD'", Long.class, account);
        return v == null ? 0L : v;
    }

    /**
     * Withdrawable in ONE statement (single READ COMMITTED snapshot): a concurrent
     * clawback committing between two separate reads could otherwise overstate funds
     * and let a debit overdraw the account (reviewer CRITICAL).
     */
    public long withdrawable(String account) {
        Long v = jdbc.queryForObject(
            "SELECT COALESCE(SUM(CASE WHEN entry_type = 'CREDIT' THEN amount_poisha ELSE -amount_poisha END), 0) " +
            "- COALESCE((SELECT SUM(le2.amount_poisha) FROM ledger_entries le2 " +
            "JOIN escrows e ON e.esc = le2.reference_id " +
            "WHERE le2.account = ? AND le2.entry_type = 'CREDIT' AND le2.is_withdrawable = FALSE " +
            "AND e.status = 'SETTLEMENT_HELD'), 0) " +
            "FROM ledger_entries WHERE account = ?", Long.class, account, account);
        return v == null ? 0L : v;
    }

    /** Total debited out of the account since the given instant (daily-out cap input, BR-035). */
    public long outSince(String account, long sinceMs) {
        Long v = jdbc.queryForObject(
            "SELECT COALESCE(SUM(amount_poisha), 0) FROM ledger_entries " +
            "WHERE account = ? AND entry_type = 'DEBIT' AND created_at >= ?", Long.class, account, sinceMs);
        return v == null ? 0L : v;
    }

    public List<EntryRow> entries(String account, int limit) {
        return entries(account, 0L, limit);
    }

    // F-13: keyset cursor — afterId=0 means first page; else return rows with id < afterId (DESC).
    public List<EntryRow> entries(String account, long afterId, int limit) {
        int capped = limit <= 0 || limit > 200 ? 50 : limit;
        return jdbc.query(
            "SELECT * FROM ledger_entries WHERE account = ? AND (? = 0 OR id < ?) ORDER BY id DESC LIMIT ?",
            ENTRY, account, afterId, afterId, capped);
    }

    /** Double-entry invariant probe: any txn whose signed legs do not sum to zero. */
    public List<String> unbalancedTxns() {
        return jdbc.queryForList(
            "SELECT txn_id FROM ledger_entries GROUP BY txn_id " +
            "HAVING SUM(CASE WHEN entry_type = 'CREDIT' THEN amount_poisha ELSE -amount_poisha END) <> 0",
            String.class);
    }

    public long txnCount() {
        Long v = jdbc.queryForObject("SELECT COUNT(DISTINCT txn_id) FROM ledger_entries", Long.class);
        return v == null ? 0L : v;
    }
}
