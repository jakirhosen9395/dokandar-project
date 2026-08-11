using System.Text.RegularExpressions;
using Npgsql;
using Coupon.Observability;

namespace Coupon.Data;

// Self-bootstrap: create the DB if missing, then apply migrations/*.sql — BEFORE the listener binds.
public static class DbBootstrap
{
    public static async Task EnsureAsync()
    {
        if (!Regex.IsMatch(Config.PgDb, "^[A-Za-z_][A-Za-z0-9_]*$"))
            throw new InvalidOperationException($"refusing unsafe db name: {Config.PgDb}");

        await using (var admin = new NpgsqlConnection(Config.PgConn("postgres")))
        {
            await admin.OpenAsync();
            bool exists;
            await using (var check = new NpgsqlCommand("SELECT 1 FROM pg_database WHERE datname=@d", admin))
            {
                check.Parameters.AddWithValue("d", Config.PgDb);
                exists = await check.ExecuteScalarAsync() != null;
            }
            if (!exists)
            {
                try
                {
                    await using var create = new NpgsqlCommand($"CREATE DATABASE \"{Config.PgDb}\"", admin);
                    await create.ExecuteNonQueryAsync();
                    Log.Info("coupon.boot", $"created database {Config.PgDb}");
                }
                catch (PostgresException e) when (e.SqlState == "42P04") { /* race: already exists */ }
            }
        }

        await using (var conn = new NpgsqlConnection(Config.PgConn()))
        {
            await conn.OpenAsync();
            var dir = Directory.Exists("migrations") ? "migrations" : "/app/migrations";
            foreach (var f in Directory.GetFiles(dir, "*.sql").OrderBy(x => x))
            {
                var sql = await File.ReadAllTextAsync(f);
                await using var cmd = new NpgsqlCommand(sql, conn);
                await cmd.ExecuteNonQueryAsync();
            }
            Log.Info("coupon.boot", "migrations applied; schema ready");
        }
    }
}
