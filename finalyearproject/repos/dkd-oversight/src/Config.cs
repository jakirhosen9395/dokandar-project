// Env-var configuration. The read-side DSN uses the SELECT-only gov_read role (R5);
// projection workers and the intervention store use the owner DSN.
namespace OversightSvc;

public sealed record Config(
    string DbDsn,
    string ReadDbDsn,
    string KafkaBrokers,
    string BuildInfoPath,
    long CaseExpiryMs)
{
    public static Config Load()
    {
        var owner = Env("DKD_DB_DSN",
            "Host=localhost;Port=5432;Database=dkd_government;Username=dokandar");
        return new Config(
            DbDsn: owner,
            // GOV-17 / R5: FAIL-CLOSED — the read side MUST use the SELECT-only gov_read role. Never
            // silently fall back to the owner (read-write) DSN, which would defeat the R5 SELECT-only
            // guard on a misconfig. Require the env explicitly.
            ReadDbDsn: RequireReadDsn(),
            KafkaBrokers: Env("DKD_KAFKA_BROKERS", "localhost:9092"),
            BuildInfoPath: Env("DKD_BUILD_INFO_PATH", "/app/build-info.json"),
            // FR-GOV-021: pending intervention requests auto-expire (LAPSED); dev default 24h.
            CaseExpiryMs: long.Parse(Env("DKD_CASE_EXPIRY_MS", "86400000")));
    }

    private static string Env(string name, string fallback)
    {
        var v = Environment.GetEnvironmentVariable(name);
        return string.IsNullOrWhiteSpace(v) ? fallback : v;
    }

    // GOV-17: no owner fallback — the R5 SELECT-only read DSN is mandatory (fail-fast on misconfig).
    private static string RequireReadDsn()
    {
        var v = Environment.GetEnvironmentVariable("DKD_READ_DB_DSN");
        if (string.IsNullOrWhiteSpace(v))
            throw new InvalidOperationException(
                "DKD_READ_DB_DSN is required (R5 SELECT-only gov_read role) — refusing to fall back to the owner DSN");
        return v;
    }
}
