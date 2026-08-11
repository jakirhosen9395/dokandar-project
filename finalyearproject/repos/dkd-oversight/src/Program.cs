// oversight-svc — DOKANDAR Context #11 (Government & Regulatory Oversight, R5/BR-038).
// Read models projected from the spine; the ONLY writes are four-eyes intervention decisions
// whose effects leave as the three registry directives (Kafka, never direct DB writes).
using System.Text.Json;
using Npgsql;
using OversightSvc;

var cfg = Config.Load();
var builder = WebApplication.CreateBuilder(args);
builder.Services.AddSingleton(cfg);
builder.Services.AddSingleton<NpgsqlDataSource>(_ => NpgsqlDataSource.Create(cfg.DbDsn));
builder.Services.AddKeyedSingleton("read",
    (IServiceProvider _, object _key) => NpgsqlDataSource.Create(cfg.ReadDbDsn));
builder.Services.AddHostedService<ProjectionWorker>();
builder.Services.AddHostedService<OutboxRelay>();
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();

var app = builder.Build();

var owner = app.Services.GetRequiredService<NpgsqlDataSource>();
var read = app.Services.GetRequiredKeyedService<NpgsqlDataSource>("read");
await Db.MigrateAsync(owner, CancellationToken.None);

app.UseSwagger(o => o.RouteTemplate = "swagger/{documentName}/swagger.json");
app.UseSwaggerUI(o =>
{
    o.SwaggerEndpoint("/swagger/v1/swagger.json", "oversight-svc v1");
    o.RoutePrefix = "docs";
});

Api.Map(app, owner, read, cfg);

var buildInfo = LoadBuildInfo(cfg.BuildInfoPath);
app.MapGet("/health", () => Results.Json(new
{
    status = "ok", service = "oversight-svc",
    version = buildInfo.GetValueOrDefault("version"), gitSha = buildInfo.GetValueOrDefault("gitSha"),
}));
app.MapGet("/live", () => Results.Json(new { status = "ok" }));
app.MapGet("/ready", async () =>
{
    try
    {
        await using var cx = await owner.OpenConnectionAsync();
        await using var cmd = new NpgsqlCommand("SELECT 1", cx);
        await cmd.ExecuteScalarAsync();
        return Results.Json(new { success = true, data = new { status = "ready", db = true },
            error = (object?)null, meta = (object?)null });
    }
    catch (Exception)
    {
        return Results.Json(new { success = false, data = new { status = "degraded", db = false },
            error = (object?)null, meta = (object?)null }, statusCode: 503);
    }
});
app.MapGet("/version", () => Results.Json(new
{
    success = true, data = buildInfo, error = (object?)null, meta = (object?)null,
}));

app.Run($"http://0.0.0.0:{Environment.GetEnvironmentVariable("DKD_PORT") ?? "8080"}");

static Dictionary<string, string> LoadBuildInfo(string path)
{
    try
    {
        if (File.Exists(path))
        {
            var parsed = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(path));
            if (parsed is not null) return parsed;
        }
    }
    catch (JsonException) { /* fall through to dev defaults */ }
    return new Dictionary<string, string>
    {
        ["version"] = "0.0.0-dev", ["gitSha"] = "unknown", ["buildTime"] = "unknown",
    };
}
