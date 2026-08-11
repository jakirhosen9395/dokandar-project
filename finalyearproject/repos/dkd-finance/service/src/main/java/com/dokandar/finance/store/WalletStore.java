package com.dokandar.finance.store;

import com.dokandar.finance.domain.Caps;
import java.util.List;
import java.util.Optional;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.stereotype.Repository;

/** Wallet + MFS-account rows. All money math lives in the ledger; wallets carry status/tier only. */
@Repository
public class WalletStore {

    public record WalletRow(String wlt, String ownerDid, String status, String kycTier,
                            String freezeReason, String freezeRef, long createdAt, long updatedAt) {}

    public record MfsRow(String id, String wlt, String provider, String mobile, String accountName,
                         boolean isPrimary, String status, long createdAt) {}

    private static final RowMapper<WalletRow> WALLET = (rs, i) -> new WalletRow(
        rs.getString("wlt"), rs.getString("owner_did"), rs.getString("status"), rs.getString("kyc_tier"),
        rs.getString("freeze_reason"), rs.getString("freeze_ref"), rs.getLong("created_at"), rs.getLong("updated_at"));

    private static final RowMapper<MfsRow> MFS = (rs, i) -> new MfsRow(
        rs.getString("id"), rs.getString("wlt"), rs.getString("provider"), rs.getString("mobile"),
        rs.getString("account_name"), rs.getBoolean("is_primary"), rs.getString("status"), rs.getLong("created_at"));

    private final JdbcTemplate jdbc;

    public WalletStore(JdbcTemplate jdbc) { this.jdbc = jdbc; }

    /** @return true when inserted; false when a wallet for this DID already exists. */
    public boolean insert(String wlt, String ownerDid, String kycTier, long now) {
        return jdbc.update(
            "INSERT INTO wallets(wlt, owner_did, status, kyc_tier, created_at, updated_at) " +
            "VALUES (?,?,'ACTIVE',?,?,?) ON CONFLICT (owner_did) DO NOTHING",
            wlt, ownerDid, kycTier, now, now) == 1;
    }

    /** Re-tier a wallet from a KYC event (F-1). @return rows updated. */
    public int updateTierByDid(String ownerDid, String kycTier, long now) {
        return jdbc.update(
            "UPDATE wallets SET kyc_tier = ?, updated_at = ? WHERE owner_did = ?",
            kycTier, now, ownerDid);
    }

    public Optional<WalletRow> find(String wlt) {
        return jdbc.query("SELECT * FROM wallets WHERE wlt = ?", WALLET, wlt).stream().findFirst();
    }

    public Optional<WalletRow> findByDid(String ownerDid) {
        return jdbc.query("SELECT * FROM wallets WHERE owner_did = ?", WALLET, ownerDid).stream().findFirst();
    }

    /** Row-lock the wallet: serializes every money command per wallet. */
    public Optional<WalletRow> lock(String wlt) {
        return jdbc.query("SELECT * FROM wallets WHERE wlt = ? FOR UPDATE", WALLET, wlt).stream().findFirst();
    }

    public Optional<WalletRow> lockByDid(String ownerDid) {
        return jdbc.query("SELECT * FROM wallets WHERE owner_did = ? FOR UPDATE", WALLET, ownerDid).stream().findFirst();
    }

    public void setStatus(String wlt, String status, String freezeReason, String freezeRef, long now) {
        jdbc.update("UPDATE wallets SET status = ?, freeze_reason = ?, freeze_ref = ?, updated_at = ? WHERE wlt = ?",
            status, freezeReason, freezeRef, now, wlt);
    }

    public Caps.TierLimits tierLimits(String tier) {
        return jdbc.queryForObject(
            "SELECT tier, single_txn_max_poisha, daily_out_max_poisha, max_balance_poisha FROM wallet_limits WHERE tier = ?",
            (rs, i) -> new Caps.TierLimits(rs.getString(1),
                (Long) rs.getObject(2), (Long) rs.getObject(3), (Long) rs.getObject(4)),
            tier);
    }

    public int countActiveMfs(String wlt) {
        Integer n = jdbc.queryForObject(
            "SELECT COUNT(*) FROM mfs_accounts WHERE wlt = ? AND status <> 'REMOVED'", Integer.class, wlt);
        return n == null ? 0 : n;
    }

    public boolean hasPrimaryMfs(String wlt) {
        Integer n = jdbc.queryForObject(
            "SELECT COUNT(*) FROM mfs_accounts WHERE wlt = ? AND is_primary", Integer.class, wlt);
        return n != null && n > 0;
    }

    public void insertMfs(String id, String wlt, String provider, String mobile, String accountName,
                          boolean isPrimary, long now) {
        jdbc.update(
            "INSERT INTO mfs_accounts(id, wlt, provider, mobile, account_name, is_primary, status, created_at) " +
            "VALUES (?,?,?,?,?,?,'PENDING',?)",
            id, wlt, provider, mobile, accountName, isPrimary, now);
    }

    public Optional<MfsRow> findMfs(String id) {
        return jdbc.query("SELECT * FROM mfs_accounts WHERE id = ?", MFS, id).stream().findFirst();
    }

    public boolean markMfsVerified(String id) {
        return jdbc.update("UPDATE mfs_accounts SET status = 'VERIFIED' WHERE id = ? AND status = 'PENDING'", id) == 1;
    }

    public List<MfsRow> listMfs(String wlt) {
        return jdbc.query("SELECT * FROM mfs_accounts WHERE wlt = ? AND status <> 'REMOVED' ORDER BY created_at", MFS, wlt);
    }
}
