package com.dokandar.finance.store;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import com.dokandar.finance.db.MigrationRunner;
import com.dokandar.finance.domain.Postings;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

/**
 * F-8: real DB integration coverage of the money core — the double-entry ledger append, the
 * sum-to-zero invariant, and the WORM immutability (ledger_entries can never be UPDATEd/DELETEd).
 * Runs against a real Postgres via TEST_JDBC_URL (the integration CI stage); skips otherwise so the
 * normal unit build is unaffected.
 */
class LedgerIntegrationTest {

    private static JdbcTemplate jdbc;

    @BeforeAll
    static void setup() throws Exception {
        String url = System.getenv("TEST_JDBC_URL");
        assumeTrue(url != null && !url.isBlank(), "TEST_JDBC_URL not set — integration DB required");
        DriverManagerDataSource ds = new DriverManagerDataSource(url,
            System.getenv("TEST_JDBC_USER"), System.getenv("TEST_JDBC_PASSWORD"));
        ds.setDriverClassName("org.postgresql.Driver");
        new MigrationRunner(ds).migrate();
        jdbc = new JdbcTemplate(ds);
    }

    @Test
    void balancedTransfer_appends_and_sumsToZero() {
        LedgerStore store = new LedgerStore(jdbc);
        String txn = "TXN-" + UUID.randomUUID();
        String from = "WLT-" + UUID.randomUUID();
        String to = "WLT-" + UUID.randomUUID();
        long now = System.currentTimeMillis();

        store.append(txn, Postings.transfer(from, to, 5000L, "ORD-x", "ORDER", true), null, now);

        Long legs = jdbc.queryForObject("SELECT count(*) FROM ledger_entries WHERE txn_id=?", Long.class, txn);
        assertEquals(2L, legs, "a balanced transfer writes exactly 2 legs");
        // signed legs sum to zero for this txn (double-entry invariant, BR-028)
        Long signed = jdbc.queryForObject(
            "SELECT COALESCE(SUM(CASE WHEN entry_type='DEBIT' THEN -amount_poisha ELSE amount_poisha END),0) "
                + "FROM ledger_entries WHERE txn_id=?", Long.class, txn);
        assertEquals(0L, signed, "DEBIT and CREDIT legs must net to zero");
        assertTrue(store.unbalancedTxns().stream().noneMatch(t -> t.equals(txn)),
            "the txn must NOT appear in the unbalanced-txn probe");
    }

    @Test
    void append_isEffectivelyOnce_onCanonIdempotencyKey() {
        // F-7: a re-append carrying the SAME canon idempotency key writes NO second posting set.
        LedgerStore store = new LedgerStore(jdbc);
        String from = "WLT-" + UUID.randomUUID();
        String to = "WLT-" + UUID.randomUUID();
        String esc = "ESC-" + UUID.randomUUID();
        String idem = "ESC:" + esc + ":release:ORD-f7";
        long now = System.currentTimeMillis();
        store.append("TXN-" + UUID.randomUUID(), Postings.transfer(from, to, 4000L, "ORD-f7", "ORDER", true), idem, now);
        store.append("TXN-" + UUID.randomUUID(), Postings.transfer(from, to, 4000L, "ORD-f7", "ORDER", true), idem, now);
        Long legs = jdbc.queryForObject(
            "SELECT count(*) FROM ledger_entries WHERE idempotency_key = ?", Long.class, idem);
        assertEquals(2L, legs, "a duplicate append on the same idem key must add NO second posting set");
    }

    @Test
    void unbalancedPostings_rejectedByDomain() {
        // the domain guard forbids constructing an unbalanced set (never reaches the ledger)
        assertThrows(IllegalArgumentException.class, () -> Postings.balanced(List.of(
            new Postings.Posting("A", Postings.DEBIT, 100L, "B", "r", "ORDER", true),
            new Postings.Posting("B", Postings.CREDIT, 99L, "A", "r", "ORDER", true))));
    }

    @Test
    void ledgerEntries_areWORM() {
        LedgerStore store = new LedgerStore(jdbc);
        String txn = "TXN-" + UUID.randomUUID();
        String from = "WLT-" + UUID.randomUUID();
        String to = "WLT-" + UUID.randomUUID();
        store.append(txn, Postings.transfer(from, to, 1000L, "ORD-w", "ORDER", true), null, System.currentTimeMillis());

        // WORM: an UPDATE or DELETE on a posted ledger entry MUST be blocked by the trigger (BR-028/R3)
        assertThrows(Exception.class,
            () -> jdbc.update("UPDATE ledger_entries SET amount_poisha=1 WHERE txn_id=?", txn),
            "ledger_entries must be immutable — UPDATE blocked");
        assertThrows(Exception.class,
            () -> jdbc.update("DELETE FROM ledger_entries WHERE txn_id=?", txn),
            "ledger_entries must be immutable — DELETE blocked");
    }
}
