// Ordered, idempotent SQL migrator (implements the blueprint IMigrator). Applies migrations/*.sql
// once each, tracked in schema_migrations. Runs at startup before the readiness gate flips.
using IdentitySvc.Persistence;
using Npgsql;

namespace IdentitySvc.Adapters;

public sealed class SqlMigrator(NpgsqlDataSource ds, ILogger<SqlMigrator> log, string migrationsDir) : IMigrator
{
    private readonly NpgsqlDataSource _ds = ds;
    private readonly ILogger<SqlMigrator> _log = log;
    private readonly string _dir = migrationsDir;

    public async Task Apply(CancellationToken ct = default)
    {
        await using var conn = await _ds.OpenConnectionAsync(ct);
        await using (var init = new NpgsqlCommand(
            "CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY, applied_at BIGINT NOT NULL)", conn))
            await init.ExecuteNonQueryAsync(ct);

        var applied = new HashSet<string>();
        await using (var q = new NpgsqlCommand("SELECT version FROM schema_migrations", conn))
        await using (var r = await q.ExecuteReaderAsync(ct))
            while (await r.ReadAsync(ct)) applied.Add(r.GetString(0));

        if (!Directory.Exists(_dir)) { _log.LogWarning("migrations dir not found: {Dir}", _dir); return; }
        foreach (var file in Directory.GetFiles(_dir, "*.sql").OrderBy(f => f))
        {
            var version = Path.GetFileNameWithoutExtension(file);
            if (applied.Contains(version)) continue;
            var sql = await File.ReadAllTextAsync(file, ct);
            await using var tx = await conn.BeginTransactionAsync(ct);
            await using (var cmd = new NpgsqlCommand(sql, conn, tx)) await cmd.ExecuteNonQueryAsync(ct);
            await using (var rec = new NpgsqlCommand(
                "INSERT INTO schema_migrations (version, applied_at) VALUES (@v, @t)", conn, tx))
            {
                rec.Parameters.AddWithValue("v", version);
                rec.Parameters.AddWithValue("t", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
                await rec.ExecuteNonQueryAsync(ct);
            }
            await tx.CommitAsync(ct);
            _log.LogInformation("applied migration {Version}", version);
        }
    }
}
