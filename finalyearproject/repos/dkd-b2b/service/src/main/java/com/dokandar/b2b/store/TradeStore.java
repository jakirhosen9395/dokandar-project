package com.dokandar.b2b.store;

import java.util.List;
import java.util.Optional;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.stereotype.Repository;

/**
 * TradeOrder rows. Status changes go through the CAS {@link #transition} (UPDATE … WHERE
 * status = ?) so a concurrent command can never skip a state; items/terms are immutable
 * after insert (DM: TradeItem/ContractTerms are value objects fixed at CreateTradeOrder).
 */
@Repository
public class TradeStore {

    public record TradeRow(String trd, String sellerDid, String buyerDid, String itemsJson,
                           String termsJson, long totalAmountPoisha, long marginRequirementPoisha,
                           Long marginPostedPoisha, String status, boolean recallFlag, String reason,
                           String settlementPpidsJson, long createdAt, long updatedAt) {}

    private static final RowMapper<TradeRow> ROW = (rs, i) -> new TradeRow(
        rs.getString("trd"), rs.getString("seller_did"), rs.getString("buyer_did"),
        rs.getString("items"), rs.getString("contract_terms"),
        rs.getLong("total_amount_poisha"), rs.getLong("margin_requirement_poisha"),
        rs.getObject("margin_posted_poisha") == null ? null : rs.getLong("margin_posted_poisha"),
        rs.getString("status"), rs.getBoolean("recall_flag"), rs.getString("reason"),
        rs.getString("settlement_ppids"), rs.getLong("created_at"), rs.getLong("updated_at"));

    private static final String COLS =
        "trd, seller_did, buyer_did, items::text AS items, contract_terms::text AS contract_terms, " +
        "total_amount_poisha, margin_requirement_poisha, margin_posted_poisha, status, recall_flag, " +
        "reason, settlement_ppids::text AS settlement_ppids, created_at, updated_at";

    private final JdbcTemplate jdbc;

    public TradeStore(JdbcTemplate jdbc) { this.jdbc = jdbc; }

    public void insert(String trd, String sellerDid, String buyerDid, String itemsJson, String termsJson,
                       long totalPoisha, long marginRequirementPoisha, long now) {
        jdbc.update(
            "INSERT INTO trade_orders(trd, seller_did, buyer_did, items, contract_terms, " +
            "total_amount_poisha, margin_requirement_poisha, status, created_at, updated_at) " +
            "VALUES (?,?,?,?::jsonb,?::jsonb,?,?,'MARGIN_PENDING',?,?)",
            trd, sellerDid, buyerDid, itemsJson, termsJson, totalPoisha, marginRequirementPoisha, now, now);
    }

    public Optional<TradeRow> find(String trd) {
        List<TradeRow> rows = jdbc.query(
            "SELECT " + COLS + " FROM trade_orders WHERE trd = ?", ROW, trd);
        return rows.stream().findFirst();
    }

    /** SELECT … FOR UPDATE — commands lock the aggregate row for the whole transaction. */
    public Optional<TradeRow> lock(String trd) {
        List<TradeRow> rows = jdbc.query(
            "SELECT " + COLS + " FROM trade_orders WHERE trd = ? FOR UPDATE", ROW, trd);
        return rows.stream().findFirst();
    }

    /** CAS transition; extra columns (margin/reason/ppids) set atomically with the status. */
    public boolean transition(String trd, String from, String to, Long marginPostedPoisha,
                              String reason, String settlementPpidsJson, long now) {
        int n = jdbc.update(
            "UPDATE trade_orders SET status = ?, " +
            "margin_posted_poisha = COALESCE(?, margin_posted_poisha), " +
            "reason = COALESCE(?, reason), " +
            "settlement_ppids = COALESCE(?::jsonb, settlement_ppids), " +
            "updated_at = ? WHERE trd = ? AND status = ?",
            to, marginPostedPoisha, reason, settlementPpidsJson, now, trd, from);
        return n == 1;
    }

    /** BR-017 advisory flag: a recall/deprecation marks open trades containing the GPID.
     *  The probe is built server-side from a plain text bind — no client-side JSON assembly
     *  (reviewer H-3: metacharacters must never reach the ::jsonb parser unescaped). */
    public int flagRecallByGpid(String gpid, long now) {
        return jdbc.update(
            "UPDATE trade_orders SET recall_flag = TRUE, updated_at = ? " +
            "WHERE status IN ('MARGIN_PENDING','MARGIN_POSTED','ACTIVE','SETTLEMENT_PENDING') " +
            "AND items @> jsonb_build_array(jsonb_build_object('gpid', ?::text))",
            now, gpid);
    }
}
