// Composition root for identity-svc. Extends the blueprint: swaps the Noop adapters for real
// Npgsql/Kafka/RabbitMQ implementations, wires the transactional-outbox dispatcher, the REST /v1
// surface, and the identity-party-ohs gRPC service. When DKD_DB_DSN is empty the service still
// boots with no-op infra (health/version/live only) so blueprint health tests run without a DB.
using IdentitySvc.Adapters;
using OpenTelemetry.Trace;
using IdentitySvc.Application;
using IdentitySvc.Config;
using IdentitySvc.Grpc;
using IdentitySvc.Http;
using IdentitySvc.Http.Middleware;
using IdentitySvc.Messaging;
using IdentitySvc.Observability;
using IdentitySvc.Persistence;
using IdentitySvc.Security;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.OpenApi;
using Npgsql;

var builder = WebApplication.CreateBuilder(args);

var config = ServiceConfig.Load();
config.Validate();
var hasDb = !string.IsNullOrWhiteSpace(config.DbDsn);

builder.Logging.ClearProviders();
builder.Logging.AddJsonConsole(opts => opts.UseUtcTimestamp = true);

// REST on HttpPort (HTTP/1.1); gRPC on a dedicated HTTP/2 cleartext port (Kestrel cannot serve h2c
// on an Http1AndHttp2 port without TLS/ALPN); Prometheus metrics on :9090.
builder.WebHost.ConfigureKestrel(kestrel =>
{
    kestrel.ListenAnyIP(config.HttpPort, o => o.Protocols = HttpProtocols.Http1);
    kestrel.ListenAnyIP(config.GrpcPort, o => o.Protocols = HttpProtocols.Http2);
    kestrel.ListenAnyIP(9090, o => o.Protocols = HttpProtocols.Http1);
});

builder.Services.AddSingleton(config);
builder.Services.AddSingleton<ReadinessState>();
builder.Services.AddSingleton<AppMetrics>();
builder.Services.AddSingleton<IJwtVerifier, NoopJwtVerifier>();
builder.Services.AddSingleton<JwtAuthenticator>();
builder.Services.AddGrpc();

// ID-05: real OpenTelemetry tracing — AspNetCore auto-instrumentation (server spans + W3C
// trace-context propagation) exported over OTLP to DKD_OTLP_ENDPOINT (record-only when unset).
{
    var otlp = Environment.GetEnvironmentVariable("DKD_OTLP_ENDPOINT");
    builder.Services.AddOpenTelemetry().WithTracing(t =>
    {
        t.AddAspNetCoreInstrumentation();
        if (!string.IsNullOrWhiteSpace(otlp))
        {
            var uri = otlp.StartsWith("http") ? otlp : $"http://{otlp}";
            t.AddOtlpExporter(o => o.Endpoint = new Uri(uri));
        }
    });
}

// Swagger / OpenAPI (single generator). JSON at /swagger/v1/swagger.json, UI at /docs.
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen(c =>
{
    c.SwaggerDoc("v1", new OpenApiInfo
    {
        Title = "identity-svc",
        Version = "v1",
        Description = "DOKANDAR Identity, Party & KYC (Context #1) — REST API.",
    });
    // Unique schema ids by full type name — avoids collisions (e.g. two ProblemDetails types).
    c.CustomSchemaIds(t => t.FullName!.Replace("+", "."));
});

// Application ports common to all modes.
builder.Services.AddSingleton<IClock, SystemClock>();
builder.Services.AddSingleton<IOtpVerifier, DevOtpVerifier>();
builder.Services.AddSingleton<PartyService>();

if (hasDb)
{
    var dataSource = new NpgsqlDataSourceBuilder(config.DbDsn).Build();
    builder.Services.AddSingleton(dataSource);
    builder.Services.AddSingleton<IIdentityUnitOfWork, NpgsqlUnitOfWork>();

    var migrationsDir = Path.Combine(AppContext.BaseDirectory, "migrations");
    if (!Directory.Exists(migrationsDir)) migrationsDir = Path.Combine(Directory.GetCurrentDirectory(), "migrations");
    builder.Services.AddSingleton<IMigrator>(sp =>
        new SqlMigrator(dataSource, sp.GetRequiredService<ILogger<SqlMigrator>>(), migrationsDir));

    builder.Services.AddSingleton<IPublisher>(_ => new KafkaBusPublisher(config.KafkaBrokers));
    builder.Services.AddSingleton(_ => new RabbitBusPublisher(config.RabbitUrl));
    builder.Services.AddHostedService<OutboxDispatcher>();
}
else
{
    builder.Services.AddSingleton<IIdentityUnitOfWork, NullUnitOfWork>();
    builder.Services.AddSingleton<IMigrator, NoopMigrator>();
    builder.Services.AddSingleton<IPublisher, NoopPublisher>();
}

var app = builder.Build();

app.UseMiddleware<ExceptionHandlingMiddleware>();
app.UseMiddleware<SecurityHeadersMiddleware>();
app.UseMiddleware<CorrelationMiddleware>();
app.UseMiddleware<RequestLoggingMiddleware>();
app.UseMiddleware<JwtAuthMiddleware>();
// Idempotency for unsafe writes (requires the DB store); only when a database is configured.
if (hasDb) app.UseMiddleware<IdempotencyMiddleware>();

// Swagger JSON (/swagger/v1/swagger.json) + interactive UI at /docs.
app.UseSwagger();
app.UseSwaggerUI(o =>
{
    o.SwaggerEndpoint("/swagger/v1/swagger.json", "identity-svc v1");
    o.RoutePrefix = "docs";
    o.DocumentTitle = "identity-svc API";
});

app.MapWhen(ctx => ctx.Connection.LocalPort == 9090, metricsApp =>
{
    metricsApp.Run(async httpCtx =>
    {
        var metrics = httpCtx.RequestServices.GetRequiredService<AppMetrics>();
        if (httpCtx.Request.Path == "/metrics")
            await metrics.WritePrometheusTextAsync(httpCtx.Response);
        else
            httpCtx.Response.StatusCode = 404;
    });
});

app.MapGet("/health",  HealthEndpoints.Health);
app.MapGet("/ready",   HealthEndpoints.Ready);
app.MapGet("/live",    HealthEndpoints.Live);
app.MapGet("/version", HealthEndpoints.Version);

app.MapPartyEndpoints();
app.MapGrpcService<IdentityPartyOhsService>();

var migrator  = app.Services.GetRequiredService<IMigrator>();
var readiness = app.Services.GetRequiredService<ReadinessState>();
await migrator.Apply(CancellationToken.None);
readiness.IsReady = true;

app.Logger.LogInformation(
    "Service {ServiceName} started on port {Port} (context: {Context}, db: {HasDb})",
    config.ServiceName, config.HttpPort, config.Context, hasDb);

app.Run();

// Expose Program for WebApplicationFactory<Program> in integration tests.
public partial class Program { }
