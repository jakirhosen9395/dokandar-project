// Postgres persistence adapter (Npgsql). Implements the application ports with a single
// connection+transaction per unit of work, so aggregate writes + outbox inserts commit atomically.
using System.Text.Json;
using Dkd.Platform;
using IdentitySvc.Application;
using IdentitySvc.Domain;
using Npgsql;
using NpgsqlTypes;

namespace IdentitySvc.Adapters;

public sealed class NpgsqlUnitOfWork(NpgsqlDataSource dataSource) : IIdentityUnitOfWork
{
    private readonly NpgsqlDataSource _ds = dataSource;

    public async Task<T> ExecuteAsync<T>(Func<IDbSession, CancellationToken, Task<T>> work, CancellationToken ct)
    {
        await using var conn = await _ds.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);
        try
        {
            var session = new NpgsqlDbSession(conn, tx);
            var result = await work(session, ct);
            await tx.CommitAsync(ct);
            return result;
        }
        catch
        {
            await tx.RollbackAsync(ct);
            throw;
        }
    }
}

public sealed class NpgsqlDbSession(NpgsqlConnection conn, NpgsqlTransaction tx) : IDbSession
{
    private readonly NpgsqlConnection _conn = conn;
    private readonly NpgsqlTransaction _tx = tx;

    public async Task<Party?> GetByDidAsync(DID did, CancellationToken ct)
    {
        const string sql = @"SELECT did, phone, nid_hash, kyc_tier, bin, tin, locale, device_ids, status,
                                    created_at, updated_at FROM party WHERE did = @did";
        await using var cmd = Cmd(sql);
        cmd.Parameters.AddWithValue("did", did.Value);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct)) return null;
        var nidHash = r.IsDBNull(2) ? null : NidHash.FromHash(r.GetString(2));
        var deviceIds = r.IsDBNull(7) ? Array.Empty<string>() : r.GetFieldValue<string[]>(7);
        return Party.Rehydrate(
            new DID(r.GetString(0)), new Phone(r.GetString(1)), nidHash,
            (KycTier)r.GetInt16(3), r.IsDBNull(4) ? null : r.GetString(4), r.IsDBNull(5) ? null : r.GetString(5),
            r.GetString(6), deviceIds, Enum.Parse<PartyStatus>(r.GetString(8)),
            r.GetInt64(9), r.GetInt64(10));
    }

    public async Task<bool> ExistsByPhoneAsync(string phone, CancellationToken ct)
    {
        await using var cmd = Cmd("SELECT 1 FROM party WHERE phone = @p LIMIT 1");
        cmd.Parameters.AddWithValue("p", phone);
        return await cmd.ExecuteScalarAsync(ct) is not null;
    }

    public async Task<bool> NidHashBoundToVerifiedPartyAsync(string nidHash, string exceptDid, CancellationToken ct)
    {
        await using var cmd = Cmd("SELECT 1 FROM party WHERE nid_hash = @h AND kyc_tier >= 1 AND did <> @d LIMIT 1");
        cmd.Parameters.AddWithValue("h", nidHash);
        cmd.Parameters.AddWithValue("d", exceptDid);
        return await cmd.ExecuteScalarAsync(ct) is not null;
    }

    public async Task InsertPartyAsync(Party p, CancellationToken ct)
    {
        const string sql = @"INSERT INTO party (did, phone, nid_hash, kyc_tier, bin, tin, locale, device_ids,
                                    status, created_at, updated_at)
                             VALUES (@did,@phone,@nid,@tier,@bin,@tin,@locale,@devs,@status,@ca,@ua)";
        await using var cmd = Cmd(sql);
        Bind(cmd, p);
        cmd.Parameters.AddWithValue("ca", p.CreatedAt);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task UpdatePartyAsync(Party p, CancellationToken ct)
    {
        const string sql = @"UPDATE party SET phone=@phone, nid_hash=@nid, kyc_tier=@tier, bin=@bin, tin=@tin,
                                    locale=@locale, device_ids=@devs, status=@status, updated_at=@ua
                             WHERE did=@did";
        await using var cmd = Cmd(sql);
        Bind(cmd, p);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task EnqueueOutboxAsync(IEnumerable<IDomainEvent> events, long nowMs, CancellationToken ct)
    {
        foreach (var e in events)
        {
            var headers = new EventHeaders(
                EventId: Guid.CreateVersion7().ToString(), OccurredAtMs: nowMs,
                ProducerContext: DID.OwnerContext, PartitionKey: e.PartitionKey);
            const string sql = @"INSERT INTO outbox (event_id, bus, destination, partition_key, payload, headers, created_at)
                                 VALUES (@eid,@bus,@dest,@key,@payload,@headers,@ca)";
            await using var cmd = Cmd(sql);
            cmd.Parameters.AddWithValue("eid", Guid.Parse(headers.EventId));
            cmd.Parameters.AddWithValue("bus", e.Bus);
            cmd.Parameters.AddWithValue("dest", e.Destination);
            cmd.Parameters.AddWithValue("key", e.PartitionKey);
            cmd.Parameters.Add(new NpgsqlParameter("payload", NpgsqlDbType.Jsonb) { Value = Json.String(e.Payload) });
            cmd.Parameters.Add(new NpgsqlParameter("headers", NpgsqlDbType.Jsonb) { Value = Json.String(headers) });
            cmd.Parameters.AddWithValue("ca", nowMs);
            await cmd.ExecuteNonQueryAsync(ct);
        }
    }

    private static void Bind(NpgsqlCommand cmd, Party p)
    {
        cmd.Parameters.AddWithValue("did", p.Did.Value);
        cmd.Parameters.AddWithValue("phone", p.PhoneNumber.Value);
        cmd.Parameters.AddWithValue("nid", (object?)p.NidHash?.Value ?? DBNull.Value);
        cmd.Parameters.AddWithValue("tier", (short)(int)p.KycTier);
        cmd.Parameters.AddWithValue("bin", (object?)p.Bin ?? DBNull.Value);
        cmd.Parameters.AddWithValue("tin", (object?)p.Tin ?? DBNull.Value);
        cmd.Parameters.AddWithValue("locale", p.Locale);
        cmd.Parameters.Add(new NpgsqlParameter("devs", NpgsqlDbType.Array | NpgsqlDbType.Text) { Value = p.DeviceIds.ToArray() });
        cmd.Parameters.AddWithValue("status", p.Status.ToString());
        cmd.Parameters.AddWithValue("ua", p.UpdatedAt);
    }

    private NpgsqlCommand Cmd(string sql) => new(sql, _conn, _tx);
}
