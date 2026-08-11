using System.Diagnostics;
using System.Net.Sockets;
using System.Text.Json;
using Npgsql;
using Coupon.Observability;
using Coupon.Services;

namespace Coupon.Endpoints;

public static class OpsEndpoints
{
    static readonly long Boot = Stopwatch.GetTimestamp();

    static Dictionary<string, object?> Identity() => new()
    {
        ["service_name"] = Config.ServiceName,
        ["code_version"] = Config.CodeVersion,
        ["env_version"] = Config.EnvVersion,
        ["tenant"] = Config.Tenant,
        ["env"] = Config.AppEnv,
        ["uptime_seconds"] = (int)Stopwatch.GetElapsedTime(Boot).TotalSeconds,
    };

    public static void MapOpsEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("/ready", async () =>
        {
            var pg = await CheckPg();
            var body = new Dictionary<string, object?>
            {
                ["status"] = pg.ok ? "ready" : "not_ready",
                ["identity"] = Identity(),
                ["dependencies"] = new[] { new Dictionary<string, object?> { ["name"] = "postgres", ["reachable"] = pg.ok, ["latency_ms"] = pg.ms, ["detail"] = pg.detail } },
            };
            return Results.Json(body, statusCode: pg.ok ? 200 : 503);
        }).WithTags("ops").WithName("getReady")
          .WithSummary("Readiness — gates on PostgreSQL only")
          .WithDescription("LB readiness gate. Returns 200 only when PostgreSQL (the system of record) is reachable; Redis/Kafka are degradable and never gate readiness. 503 when not ready.");

        app.MapGet("/health", async (RedisService redis) =>
        {
            var pg = await CheckPg();
            var rd = await redis.PingAsync();
            var kf = CheckKafka();
            var mongo = Log.MongoHealthy;
            var apm = !string.IsNullOrEmpty(Config.ApmServerUrl);
            var healthy = pg.ok && kf.ok; // redis degradable; mongo/apm diagnostic
            var body = new Dictionary<string, object?>
            {
                ["status"] = healthy ? "healthy" : "unhealthy",
                ["identity"] = Identity(),
                ["checks"] = new Dictionary<string, object?>
                {
                    ["postgres"] = new { ok = pg.ok, latency_ms = pg.ms, detail = pg.detail },
                    ["redis"] = new { ok = rd, detail = rd ? "ok" : "redis-not-connected (degraded path)" },
                    ["kafka"] = new { ok = kf.ok, detail = kf.detail },
                    ["mongo_logs"] = new { ok = mongo, detail = mongo ? "ping-ok" : "unreachable" },
                    ["apm"] = new { ok = apm, detail = apm ? "configured" : "disabled" },
                },
                ["observability"] = new Dictionary<string, object?>
                {
                    ["apm_service_name"] = Config.ApmServiceName,
                    ["logs_sink_mongo"] = string.IsNullOrEmpty(Config.MongoLogUri) ? null : $"{Config.MongoLogDb}.{Config.ServiceName}",
                    ["logs_sink_es"] = string.IsNullOrEmpty(Config.EsUrl) ? null : $"{Config.EsUrl}/logs-app-{Config.ServiceName}-*",
                },
            };
            return Results.Json(body, statusCode: healthy ? 200 : 503);
        }).WithTags("ops").WithName("getHealth")
          .WithSummary("Liveness + all dependency health")
          .WithDescription("Full diagnostics over all dependencies (postgres, redis, kafka, mongo log sink, apm) plus an observability block. Redis/mongo/apm are diagnostic-only and do not flip status. 503 when a core dependency is down.");

        app.MapGet("/data", () =>
        {
            foreach (var p in new[] { $"data/{Config.Tenant}/result.json", $"/app/data/{Config.Tenant}/result.json" })
            {
                string txt;
                try { txt = File.ReadAllText(p); }
                catch { continue; }
                try
                {
                    var snap = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(txt);
                    if (snap == null) return Err(500, "snapshot_parse_failed", "snapshot root must be an object");
                    var merged = new Dictionary<string, object?>();
                    foreach (var kv in Identity()) merged[kv.Key] = kv.Value;
                    foreach (var kv in snap) merged[kv.Key] = kv.Value;
                    return Results.Json(merged, statusCode: 200);
                }
                catch (JsonException) { return Err(500, "snapshot_parse_failed", "snapshot is not valid JSON"); }
            }
            return Err(404, "no_snapshot", $"data/{Config.Tenant}/result.json not present (run data/{Config.Tenant}/collect.sh)");
        }).WithTags("ops").WithName("getData")
          .WithSummary("Tenant data snapshot")
          .WithDescription("Returns the identity block prepended to the read-only `data/<tenant>/result.json` snapshot (not live DB introspection). `404 no_snapshot` when the snapshot is absent; `500 snapshot_parse_failed` when it is not a JSON object.");
    }

    static IResult Err(int status, string code, string message) =>
        Results.Json(new Dictionary<string, object?> { ["error"] = new Dictionary<string, object?> { ["code"] = code, ["message"] = message } }, statusCode: status);

    static async Task<(bool ok, double ms, string detail)> CheckPg()
    {
        var sw = Stopwatch.StartNew();
        try
        {
            await using var c = new NpgsqlConnection(Config.PgConn());
            await c.OpenAsync();
            await using var cmd = new NpgsqlCommand("SELECT 1", c);
            await cmd.ExecuteScalarAsync();
            return (true, Math.Round(sw.Elapsed.TotalMilliseconds, 2), "ok");
        }
        catch (Exception e) { return (false, Math.Round(sw.Elapsed.TotalMilliseconds, 2), $"err:{e.GetType().Name}"); }
    }

    static (bool ok, string detail) CheckKafka()
    {
        try
        {
            var parts = Config.KafkaBootstrap.Split(':');
            using var tcp = new TcpClient();
            tcp.Connect(parts[0], parts.Length > 1 ? int.Parse(parts[1]) : 9092);
            return (true, "metadata-ok");
        }
        catch { return (false, "unreachable"); }
    }
}
