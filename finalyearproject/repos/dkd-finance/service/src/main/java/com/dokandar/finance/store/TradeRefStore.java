package com.dokandar.finance.store;

import java.util.List;
import java.util.Optional;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.stereotype.Repository;

/**
 * Party projection of TradeOrderCreated.v1 (Saga 4). MarginPosted carries only
 * {trd, amountPoisha, postedAt} — the escrow's buyer/seller wallets are resolved from
 * this projection because DID->wallet resolution happens INSIDE Finance (R2).
 */
@Repository
public class TradeRefStore {

    public record TradeRef(String trd, String buyerDid, String sellerDid, long createdAt) {}

    private static final RowMapper<TradeRef> ROW = (rs, i) -> new TradeRef(
        rs.getString("trd"), rs.getString("buyer_did"), rs.getString("seller_did"),
        rs.getLong("created_at"));

    private final JdbcTemplate jdbc;

    public TradeRefStore(JdbcTemplate jdbc) { this.jdbc = jdbc; }

    public void upsert(String trd, String buyerDid, String sellerDid, long now) {
        jdbc.update(
            "INSERT INTO trade_refs(trd, buyer_did, seller_did, created_at) VALUES (?,?,?,?) " +
            "ON CONFLICT (trd) DO NOTHING",
            trd, buyerDid, sellerDid, now);
    }

    public Optional<TradeRef> find(String trd) {
        List<TradeRef> rows = jdbc.query(
            "SELECT trd, buyer_did, seller_did, created_at FROM trade_refs WHERE trd = ?", ROW, trd);
        return rows.stream().findFirst();
    }
}
