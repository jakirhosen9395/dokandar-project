// Postgres stores. Projections are EVENT-TIME guarded upserts (as_of watermark, G11) —
// cross-topic replay order is arbitrary, a stale event never overwrites newer state.
// All command writes happen on one connection/transaction owned by the caller.
using System.Text.Json;
using Npgsql;

namespace OversightSvc;

public static class Stores
{
    // ---- read models (worker-only writes; gov_read has SELECT) ----

    public static async Task UpsertTrade(NpgsqlConnection cx, NpgsqlTransaction tx, string trd,
        string? seller, string? buyer, long total, string status, long createdAt, long asOf)
    {
        await using var cmd = new NpgsqlCommand(
            """
            INSERT INTO national_trade_view(trd, seller_did, buyer_did, total_amount_poisha,
              status, created_at, as_of) VALUES ($1,$2,$3,$4,$5,$6,$7)
            ON CONFLICT (trd) DO UPDATE SET status = EXCLUDED.status, as_of = EXCLUDED.as_of,
              seller_did = CASE WHEN EXCLUDED.seller_did <> '' THEN EXCLUDED.seller_did
                                ELSE national_trade_view.seller_did END,
              buyer_did = CASE WHEN EXCLUDED.buyer_did <> '' THEN EXCLUDED.buyer_did
                               ELSE national_trade_view.buyer_did END,
              total_amount_poisha = CASE WHEN EXCLUDED.total_amount_poisha > 0
                THEN EXCLUDED.total_amount_poisha ELSE national_trade_view.total_amount_poisha END
            WHERE national_trade_view.as_of <= EXCLUDED.as_of
            """, cx, tx);
        cmd.Parameters.AddWithValue(trd);
        cmd.Parameters.AddWithValue(seller ?? "");
        cmd.Parameters.AddWithValue(buyer ?? "");
        cmd.Parameters.AddWithValue(total);
        cmd.Parameters.AddWithValue(status);
        cmd.Parameters.AddWithValue(createdAt);
        cmd.Parameters.AddWithValue(asOf);
        await cmd.ExecuteNonQueryAsync();
    }

    /// <summary>NIL summary — additive quantity deltas keyed GPID (custody events).</summary>
    public static async Task BumpInventory(NpgsqlConnection cx, NpgsqlTransaction tx, string gpid,
        long deltaQuantity, string unit, long asOf)
    {
        await using var cmd = new NpgsqlCommand(
            """
            INSERT INTO national_inventory_summary(gpid, total_quantity, unit, computed_at)
            VALUES ($1, GREATEST($2, 0), $3, $4)
            ON CONFLICT (gpid) DO UPDATE SET
              total_quantity = GREATEST(national_inventory_summary.total_quantity + $2, 0),
              unit = EXCLUDED.unit,
              computed_at = GREATEST(national_inventory_summary.computed_at, EXCLUDED.computed_at)
            """, cx, tx);
        cmd.Parameters.AddWithValue(gpid);
        cmd.Parameters.AddWithValue(deltaQuantity);
        cmd.Parameters.AddWithValue(unit);
        cmd.Parameters.AddWithValue(asOf);
        await cmd.ExecuteNonQueryAsync();
    }

    public static async Task UpsertEscrow(NpgsqlConnection cx, NpgsqlTransaction tx, string esc,
        long amount, string status, string referenceId, long asOf)
    {
        await using var cmd = new NpgsqlCommand(
            """
            INSERT INTO escrow_summary(esc, amount_poisha, status, reference_id, as_of)
            VALUES ($1,$2,$3,$4,$5)
            ON CONFLICT (esc) DO UPDATE SET status = EXCLUDED.status, as_of = EXCLUDED.as_of,
              amount_poisha = CASE WHEN EXCLUDED.amount_poisha > 0 THEN EXCLUDED.amount_poisha
                                   ELSE escrow_summary.amount_poisha END,
              reference_id = CASE WHEN EXCLUDED.reference_id <> '' THEN EXCLUDED.reference_id
                                  ELSE escrow_summary.reference_id END
            WHERE escrow_summary.as_of <= EXCLUDED.as_of
            """, cx, tx);
        cmd.Parameters.AddWithValue(esc);
        cmd.Parameters.AddWithValue(amount);
        cmd.Parameters.AddWithValue(status);
        cmd.Parameters.AddWithValue(referenceId);
        cmd.Parameters.AddWithValue(asOf);
        await cmd.ExecuteNonQueryAsync();
    }

    public static async Task UpsertCompliance(NpgsqlConnection cx, NpgsqlTransaction tx, string did,
        string? kycTier, string? status, string? historyAppend, string? fraudFlagAppend, long asOf)
    {
        await using var cmd = new NpgsqlCommand(
            """
            INSERT INTO party_compliance_view(did, kyc_tier, status, suspension_history,
              fraud_flags, as_of, kyc_tier_as_of, status_as_of)
            VALUES ($1, COALESCE($2,'UNVERIFIED'), COALESCE($3,'ACTIVE'),
                    CASE WHEN $4 IS NULL THEN '[]'::jsonb
                         ELSE jsonb_build_array(jsonb_build_object('ev',$4::text,'at',$6)) END,
                    CASE WHEN $5 IS NULL THEN '[]'::jsonb
                         ELSE jsonb_build_array(jsonb_build_object('ev',$5::text,'at',$6)) END,
                    $6,
                    CASE WHEN $2 IS NULL THEN 0 ELSE $6 END,
                    CASE WHEN $3 IS NULL THEN 0 ELSE $6 END)
            ON CONFLICT (did) DO UPDATE SET
              -- per-FIELD event-time guards (reviewer H-2): a late replay never regresses state
              kyc_tier = CASE WHEN $2 IS NOT NULL AND $6 >= party_compliance_view.kyc_tier_as_of
                              THEN $2 ELSE party_compliance_view.kyc_tier END,
              kyc_tier_as_of = CASE WHEN $2 IS NOT NULL AND $6 >= party_compliance_view.kyc_tier_as_of
                              THEN $6 ELSE party_compliance_view.kyc_tier_as_of END,
              status = CASE WHEN $3 IS NOT NULL AND $6 >= party_compliance_view.status_as_of
                            THEN $3 ELSE party_compliance_view.status END,
              status_as_of = CASE WHEN $3 IS NOT NULL AND $6 >= party_compliance_view.status_as_of
                            THEN $6 ELSE party_compliance_view.status_as_of END,
              suspension_history = CASE WHEN $4 IS NULL THEN party_compliance_view.suspension_history
                ELSE party_compliance_view.suspension_history
                     || jsonb_build_object('ev',$4::text,'at',$6) END,
              fraud_flags = CASE WHEN $5 IS NULL THEN party_compliance_view.fraud_flags
                ELSE party_compliance_view.fraud_flags
                     || jsonb_build_object('ev',$5::text,'at',$6) END,
              as_of = GREATEST(party_compliance_view.as_of, $6)
            """, cx, tx);
        cmd.Parameters.AddWithValue(did);
        AddText(cmd, kycTier);
        AddText(cmd, status);
        AddText(cmd, historyAppend);
        AddText(cmd, fraudFlagAppend);
        cmd.Parameters.AddWithValue(asOf);
        await cmd.ExecuteNonQueryAsync();
    }

    /// <summary>Nullable text params need an explicit type or Postgres cannot infer $n (42P08).</summary>
    private static void AddText(NpgsqlCommand cmd, string? value) =>
        cmd.Parameters.Add(new NpgsqlParameter
        {
            Value = (object?)value ?? DBNull.Value,
            NpgsqlDbType = NpgsqlTypes.NpgsqlDbType.Text,
        });

    // ---- intervention decision store (the ONLY command aggregate, R5) ----

    public sealed record CaseRow(string Con, string Kind, string PayloadJson, string PayloadHash,
        string MakerDid, string? CheckerDid, string Status, string? DirectiveId, long RequestedAt);

    public static async Task InsertCase(NpgsqlConnection cx, NpgsqlTransaction tx, string con,
        DirectiveKind kind, JsonElement payload, string payloadHash, string makerDid, long now)
    {
        await using var cmd = new NpgsqlCommand(
            "INSERT INTO intervention_cases(con, kind, payload, payload_hash, maker_did, status, " +
            "requested_at, updated_at) VALUES ($1,$2,$3::jsonb,$4,$5,'PROPOSED',$6,$6)", cx, tx);
        cmd.Parameters.AddWithValue(con);
        cmd.Parameters.AddWithValue(kind.ToString());
        cmd.Parameters.AddWithValue(JsonSerializer.Serialize(payload));
        cmd.Parameters.AddWithValue(payloadHash);
        cmd.Parameters.AddWithValue(makerDid);
        cmd.Parameters.AddWithValue(now);
        await cmd.ExecuteNonQueryAsync();
    }

    public static async Task<CaseRow?> LockCase(NpgsqlConnection cx, NpgsqlTransaction tx, string con)
    {
        await using var cmd = new NpgsqlCommand(
            "SELECT con, kind, payload::text, payload_hash, maker_did, checker_did, status, " +
            "directive_id, requested_at FROM intervention_cases WHERE con = $1 FOR UPDATE", cx, tx);
        cmd.Parameters.AddWithValue(con);
        await using var r = await cmd.ExecuteReaderAsync();
        if (!await r.ReadAsync()) return null;
        return new CaseRow(r.GetString(0), r.GetString(1), r.GetString(2), r.GetString(3),
            r.GetString(4), r.IsDBNull(5) ? null : r.GetString(5), r.GetString(6),
            r.IsDBNull(7) ? null : r.GetString(7), r.GetInt64(8));
    }

    public static async Task<bool> TransitionCase(NpgsqlConnection cx, NpgsqlTransaction tx,
        string con, string from, string to, string? checkerDid, string? reason,
        string? directiveId, long now)
    {
        await using var cmd = new NpgsqlCommand(
            "UPDATE intervention_cases SET status = $3, checker_did = COALESCE($4, checker_did), " +
            "reason = COALESCE($5, reason), directive_id = COALESCE($6, directive_id), " +
            "decided_at = $7, updated_at = $7 WHERE con = $1 AND status = $2", cx, tx);
        cmd.Parameters.AddWithValue(con);
        cmd.Parameters.AddWithValue(from);
        cmd.Parameters.AddWithValue(to);
        AddText(cmd, checkerDid);
        AddText(cmd, reason);
        AddText(cmd, directiveId);
        cmd.Parameters.AddWithValue(now);
        return await cmd.ExecuteNonQueryAsync() == 1;
    }

    // ---- spine plumbing ----

    public static async Task<bool> InboxTryMark(NpgsqlConnection cx, NpgsqlTransaction tx,
        string eventId, string topic, long now)
    {
        await using var cmd = new NpgsqlCommand(
            "INSERT INTO inbox(event_id, topic, processed_at) VALUES ($1,$2,$3) " +
            "ON CONFLICT (event_id) DO NOTHING", cx, tx);
        cmd.Parameters.AddWithValue(eventId);
        cmd.Parameters.AddWithValue(topic);
        cmd.Parameters.AddWithValue(now);
        return await cmd.ExecuteNonQueryAsync() == 1;
    }

    public static async Task OutboxInsert(NpgsqlConnection cx, NpgsqlTransaction tx, string eventId,
        string topic, string key, string payloadJson, long now)
    {
        await using var cmd = new NpgsqlCommand(
            "INSERT INTO outbox(event_id, topic, partition_key, payload, occurred_at) " +
            "VALUES ($1,$2,$3,$4::jsonb,$5)", cx, tx);
        cmd.Parameters.AddWithValue(eventId);
        cmd.Parameters.AddWithValue(topic);
        cmd.Parameters.AddWithValue(key);
        cmd.Parameters.AddWithValue(payloadJson);
        cmd.Parameters.AddWithValue(now);
        await cmd.ExecuteNonQueryAsync();
    }

    public sealed record OutboxRow(long Id, string EventId, string Topic, string Key, string Payload);

    public static async Task<List<OutboxRow>> FetchUnpublished(NpgsqlConnection cx, int limit)
    {
        await using var cmd = new NpgsqlCommand(
            "SELECT id, event_id, topic, partition_key, payload::text FROM outbox " +
            "WHERE published_at IS NULL ORDER BY id LIMIT $1", cx);
        cmd.Parameters.AddWithValue(Math.Clamp(limit, 1, 500));
        var rows = new List<OutboxRow>();
        await using var r = await cmd.ExecuteReaderAsync();
        while (await r.ReadAsync())
            rows.Add(new OutboxRow(r.GetInt64(0), r.GetString(1), r.GetString(2), r.GetString(3),
                r.GetString(4)));
        return rows;
    }

    public static async Task MarkPublished(NpgsqlConnection cx, long id, long now)
    {
        await using var cmd = new NpgsqlCommand(
            "UPDATE outbox SET published_at = $2 WHERE id = $1", cx);
        cmd.Parameters.AddWithValue(id);
        cmd.Parameters.AddWithValue(now);
        await cmd.ExecuteNonQueryAsync();
    }

    public sealed record StoredResponse(string RequestHash, int Status, string BodyJson);

    public static async Task<StoredResponse?> IdemFind(NpgsqlConnection cx, string key, string endpoint)
    {
        await using var cmd = new NpgsqlCommand(
            "SELECT request_hash, response_status, response_body::text FROM cmd_idempotency " +
            "WHERE idem_key = $1 AND endpoint = $2", cx);
        cmd.Parameters.AddWithValue(key);
        cmd.Parameters.AddWithValue(endpoint);
        await using var r = await cmd.ExecuteReaderAsync();
        if (!await r.ReadAsync()) return null;
        return new StoredResponse(r.GetString(0), r.GetInt32(1), r.GetString(2));
    }

    public static async Task IdemInsert(NpgsqlConnection cx, NpgsqlTransaction tx, string key,
        string endpoint, string requestHash, int status, string bodyJson, long now)
    {
        await using var cmd = new NpgsqlCommand(
            "INSERT INTO cmd_idempotency(idem_key, endpoint, request_hash, response_status, " +
            "response_body, created_at) VALUES ($1,$2,$3,$4,$5::jsonb,$6)", cx, tx);
        cmd.Parameters.AddWithValue(key);
        cmd.Parameters.AddWithValue(endpoint);
        cmd.Parameters.AddWithValue(requestHash);
        cmd.Parameters.AddWithValue(status);
        cmd.Parameters.AddWithValue(bodyJson);
        cmd.Parameters.AddWithValue(now);
        await cmd.ExecuteNonQueryAsync();
    }
}
