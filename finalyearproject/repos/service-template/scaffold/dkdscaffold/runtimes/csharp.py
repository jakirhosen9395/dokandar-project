"""
dkdscaffold.runtimes.csharp — C# / .NET 8 (ASP.NET Core) runtime emitter.

Emits a complete, compilable ASP.NET Core 8 minimal-API service skeleton realising every
blueprint capability: hexagonal structure, 12-factor config + Validate, DI wiring, graceful
shutdown, startup validation, /health /ready /live /version (ContractVersion from Dkd.Platform),
structured JSON logging, Prometheus metrics (:9090/metrics), W3C traceparent propagation +
correlation-id middleware, request logging, JWT auth middleware (bearer extract + claims parse +
injectable IJwtVerifier) + HasRole authz helper, security headers, input validation, centralized
RFC-7807 exception handling, Kafka + RabbitMQ bootstrap as IPublisher/IConsumer abstractions
(NoopPublisher/Consumer wired by default), IDb + ITx + RepositoryBase + IMigrator + NoopMigrator,
xunit unit tests (health handler), xunit integration tests (Trait-guarded), multi-stage Dockerfile
(sdk:8.0 -> aspnet:8.0, non-root), GitLab CI (build+test+lint + docker package on main).

Consumes svc.sdk = Dkd.Platform (NuGet, dkd-platform-libs C# SDK). No business logic.
"""
from __future__ import annotations

from ..blueprint import Service
from ..render import Writer, pascal, camel, snake, kebab
from .common import emit_common


def emit(svc: Service, out_dir: str) -> list[str]:
    w = Writer(out_dir, "//")
    ns = pascal(svc.slug)   # root C# namespace, e.g. CatalogSvc
    emit_common(w, svc)

    _csproj(w, svc, ns)
    _program(w, svc, ns)
    _config(w, svc, ns)
    _readiness(w, ns)
    _logger(w, ns)
    _metrics(w, ns)
    _tracing(w, ns)
    _health(w, ns)
    _middleware_correlation(w, ns)
    _middleware_logging(w, ns)
    _middleware_security(w, ns)
    _middleware_exception(w, svc, ns)
    _middleware_jwt(w, ns)
    _security(w, ns)
    _messaging(w, ns)
    _persistence(w, ns)
    _validation(w, ns)
    _tests_unit(w, svc, ns)
    _tests_integration(w, svc, ns)
    _dockerfile(w, svc, ns)
    _ci(w, svc, ns)
    _makefile(w, svc, ns)

    return list(w.written)


# ---------------------------------------------------------------------------
# String-substitution helper — use __NS__, __PORT__, __SLUG__, __CTX__, __SDK__
# as placeholders in template strings (safe: these tokens never appear in C# code).
# ---------------------------------------------------------------------------

def _sub(template: str, ns: str, svc: Service) -> str:
    return (template
            .replace("__NS__", ns)
            .replace("__PORT__", str(svc.http_port))
            .replace("__SLUG__", svc.slug)
            .replace("__CTX__", svc.context)
            .replace("__SDK__", svc.sdk))


# ---------------------------------------------------------------------------
# Project manifest (.csproj)
# ---------------------------------------------------------------------------

def _csproj(w: Writer, svc: Service, ns: str) -> None:
    body = _sub('''\
<Project Sdk="Microsoft.NET.Sdk.Web">

  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <RootNamespace>__NS__</RootNamespace>
    <AssemblyName>__NS__</AssemblyName>
    <Optimize>true</Optimize>
  </PropertyGroup>

  <ItemGroup>
    <!--
      dkd-platform-libs C# SDK (__SDK__).
      CI: configure the GitLab NuGet registry (see .gitlab-ci.yml NuGet step) then restore.
      Local without the registry: replace PackageReference with a ProjectReference pointing to
        ../../../dkd-platform-libs/sdk/csharp/Dkd.Platform/Dkd.Platform.csproj
    -->
    <!-- Swagger (Swashbuckle) + the ApiDocs helper come transitively from the Dkd.Platform SDK
         (API Documentation Standard, docs/api-documentation-standard.md). -->
    <PackageReference Include="Dkd.Platform" Version="1.0.0" />
  </ItemGroup>

  <ItemGroup>
    <!-- Exclude test source trees from the main project compilation. -->
    <Compile Remove="tests/**" />
  </ItemGroup>

</Project>
''', ns, svc)
    w.write("%s.csproj" % ns, body)


# ---------------------------------------------------------------------------
# Entry point — Program.cs
# ---------------------------------------------------------------------------

def _program(w: Writer, svc: Service, ns: str) -> None:
    body = _sub('''\
using __NS__.Config;
using __NS__.Http;
using __NS__.Http.Middleware;
using __NS__.Messaging;
using __NS__.Observability;
using __NS__.Persistence;
using __NS__.Security;
using Dkd.Platform;   // AddDkdApiDocs / UseDkdApiDocs — the API Documentation Standard helper

var builder = WebApplication.CreateBuilder(args);

// ── 12-factor config: load from environment; fail fast on invalid values ──────────────────────
var config = ServiceConfig.Load();
config.Validate();

// ── Structured JSON logging (Microsoft.Extensions.Logging JSON console) ──────────────────────
builder.Logging.ClearProviders();
builder.Logging.AddJsonConsole(opts => opts.UseUtcTimestamp = true);

// ── Kestrel: main HTTP port + dedicated Prometheus metrics port ───────────────────────────────
builder.WebHost.ConfigureKestrel(kestrel =>
{
    kestrel.ListenAnyIP(config.HttpPort);  // service API
    kestrel.ListenAnyIP(9090);             // metrics (scraped by Prometheus / kube annotation)
});

// ── Infrastructure services (DI wiring) ──────────────────────────────────────────────────────
builder.Services.AddSingleton(config);
builder.Services.AddSingleton<ReadinessState>();
builder.Services.AddSingleton<AppMetrics>();

// JWT verifier integration point: NoopJwtVerifier skips signature checks (local dev only).
// In staging/production replace with the platform JWKS verifier from Dkd.Platform.Security.
builder.Services.AddSingleton<IJwtVerifier, NoopJwtVerifier>();
builder.Services.AddSingleton<JwtAuthenticator>();

// Messaging integration point: replace NoopPublisher/Consumer with Kafka (Redpanda) and
// RabbitMQ drivers. Effectively-once delivery requires the transactional outbox + inbox pattern
// (documented in Engineering-Foundation.md) — wire those in the adapter layer.
builder.Services.AddSingleton<IPublisher, NoopPublisher>();
builder.Services.AddSingleton<IConsumer, NoopConsumer>();

// DB + migrations integration point: replace NoopMigrator with the Npgsql/pgx driver and a
// real schema migrator (e.g. DbUp or Evolve). No business repositories are defined here.
builder.Services.AddSingleton<IMigrator, NoopMigrator>();

// ── API Documentation Standard: Swagger UI at /docs via the platform SDK helper (one call;
// docs/api-documentation-standard.md). No per-service Swagger configuration — the SDK owns it.
builder.Services.AddDkdApiDocs(config.ServiceName);

var app = builder.Build();

// ── Middleware pipeline (order is significant) ────────────────────────────────────────────────
app.UseMiddleware<ExceptionHandlingMiddleware>();  // outermost: converts all unhandled exceptions
app.UseMiddleware<SecurityHeadersMiddleware>();    //   to RFC-7807 problem+json
app.UseMiddleware<CorrelationMiddleware>();
app.UseMiddleware<RequestLoggingMiddleware>();
app.UseMiddleware<JwtAuthMiddleware>();            // optional auth — does not reject anon traffic

// ── Swagger UI at /docs + JSON at /swagger/v1/swagger.json via the platform SDK helper ──────────
app.UseDkdApiDocs();

// ── Prometheus metrics on :9090 only ─────────────────────────────────────────────────────────
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

// ── Health / probe / version endpoints (public — no authentication required) ─────────────────
app.MapGet("/health",  HealthEndpoints.Health);
app.MapGet("/ready",   HealthEndpoints.Ready);
app.MapGet("/live",    HealthEndpoints.Live);
app.MapGet("/version", HealthEndpoints.Version);

// ── Startup: apply migrations then flip readiness gate ───────────────────────────────────────
var migrator  = app.Services.GetRequiredService<IMigrator>();
var readiness = app.Services.GetRequiredService<ReadinessState>();
await migrator.Apply(CancellationToken.None);
readiness.IsReady = true;

app.Logger.LogInformation(
    "Service {ServiceName} started on port {Port} (context: {Context})",
    config.ServiceName, config.HttpPort, config.Context);

app.Run();

// Expose Program for WebApplicationFactory<Program> in integration tests.
public partial class Program { }
''', ns, svc)
    w.write("src/Program.cs", body, banner=True)


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

def _config(w: Writer, svc: Service, ns: str) -> None:
    body = _sub('''\
namespace __NS__.Config;

/// <summary>
/// 12-factor configuration: every value is loaded from environment variables.
/// Secrets are delivered by the platform secret manager in non-local environments — never committed.
/// </summary>
public sealed class ServiceConfig
{
    public string ServiceName  { get; init; } = string.Empty;
    public string Context      { get; init; } = string.Empty;
    public string DkdEnv       { get; init; } = "local";
    public int    HttpPort     { get; init; } = __PORT__;
    public string LogLevel     { get; init; } = "info";
    public string KafkaBrokers { get; init; } = string.Empty;
    public string RabbitUrl    { get; init; } = string.Empty;
    public string DbDsn        { get; init; } = string.Empty;
    public string OtelEndpoint { get; init; } = string.Empty;
    public string JwtIssuer    { get; init; } = string.Empty;

    /// <summary>Load all values from environment variables (12-factor).</summary>
    public static ServiceConfig Load() => new()
    {
        ServiceName  = GetEnv("DKD_SERVICE_NAME",  "__SLUG__"),
        Context      = GetEnv("DKD_CONTEXT",        "__CTX__"),
        DkdEnv       = GetEnv("DKD_ENV",             "local"),
        HttpPort     = int.Parse(GetEnv("DKD_HTTP_PORT", "__PORT__")),
        LogLevel     = GetEnv("DKD_LOG_LEVEL",      "info"),
        KafkaBrokers = GetEnv("DKD_KAFKA_BROKERS",  "localhost:9092"),
        RabbitUrl    = GetEnv("DKD_RABBITMQ_URL",   string.Empty),
        DbDsn        = GetEnv("DKD_DB_DSN",         string.Empty),
        OtelEndpoint = GetEnv("DKD_OTEL_ENDPOINT",  string.Empty),
        JwtIssuer    = GetEnv("DKD_JWT_ISSUER",     string.Empty),
    };

    /// <summary>Startup validation — throws <see cref="InvalidOperationException"/> on missing required values.</summary>
    public void Validate()
    {
        if (string.IsNullOrWhiteSpace(ServiceName))
            throw new InvalidOperationException("DKD_SERVICE_NAME is required");
        if (string.IsNullOrWhiteSpace(Context))
            throw new InvalidOperationException("DKD_CONTEXT is required");
        if (HttpPort is <= 0 or > 65535)
            throw new InvalidOperationException($"DKD_HTTP_PORT is invalid: {HttpPort}");
    }

    private static string GetEnv(string key, string fallback) =>
        Environment.GetEnvironmentVariable(key) is { Length: > 0 } v ? v : fallback;
}
''', ns, svc)
    w.write("src/Config/ServiceConfig.cs", body, banner=True)


# ---------------------------------------------------------------------------
# Readiness gate
# ---------------------------------------------------------------------------

def _readiness(w: Writer, ns: str) -> None:
    body = '''\
namespace %s.Http;

/// <summary>
/// Readiness gate: flipped to true after startup migrations and dependency checks succeed.
/// Consumed by the /ready probe. Use a volatile field to ensure cross-thread visibility without
/// locking — the write happens once at startup before traffic is accepted.
/// </summary>
public sealed class ReadinessState
{
    private volatile bool _ready;

    public bool IsReady
    {
        get => _ready;
        set => _ready = value;
    }
}
''' % ns
    w.write("src/Http/ReadinessState.cs", body, banner=True)


# ---------------------------------------------------------------------------
# Observability: structured logging constants
# ---------------------------------------------------------------------------

def _logger(w: Writer, ns: str) -> None:
    body = '''\
namespace %s.Observability;

/// <summary>
/// Shared structured-log field name constants. Use these throughout the service to keep field
/// names consistent across log entries. Logging itself uses ILogger{T} injected via DI.
/// </summary>
public static class AppLogger
{
    public static class Keys
    {
        public const string CorrelationId = "correlation_id";
        public const string TraceParent   = "traceparent";
        public const string ServiceName   = "service_name";
        public const string DkdContext    = "dkd_context";
    }
}
''' % ns
    w.write("src/Observability/AppLogger.cs", body, banner=True)


# ---------------------------------------------------------------------------
# Observability: Prometheus metrics
# ---------------------------------------------------------------------------

def _metrics(w: Writer, ns: str) -> None:
    body = '''\
using System.Text;
using Microsoft.AspNetCore.Http;

namespace %s.Observability;

/// <summary>
/// Thread-safe Prometheus-text counter registry. Exposed on :9090/metrics.
/// For richer metric types (histograms, gauges) replace with the prometheus-net NuGet package
/// at the integration point — the /metrics handler in Program.cs remains unchanged.
/// </summary>
public sealed class AppMetrics
{
    private readonly Dictionary<string, long> _counters = new();
    private readonly object _lock = new();

    /// <summary>Atomically increment a counter by name.</summary>
    public void Increment(string name)
    {
        lock (_lock)
            _counters[name] = _counters.TryGetValue(name, out var v) ? v + 1 : 1;
    }

    /// <summary>Write all counters in Prometheus text exposition format (version 0.0.4).</summary>
    public async Task WritePrometheusTextAsync(HttpResponse response)
    {
        response.ContentType = "text/plain; version=0.0.4; charset=utf-8";
        string body;
        lock (_lock)
        {
            var sb = new StringBuilder();
            foreach (var (name, value) in _counters)
                sb.Append(name).Append(' ').AppendLine(value.ToString());
            body = sb.ToString();
        }
        await response.WriteAsync(body);
    }
}
''' % ns
    w.write("src/Observability/AppMetrics.cs", body, banner=True)


# ---------------------------------------------------------------------------
# Observability: W3C traceparent + correlation ID
# ---------------------------------------------------------------------------

def _tracing(w: Writer, ns: str) -> None:
    body = '''\
using System.Security.Cryptography;

namespace %s.Observability;

/// <summary>
/// W3C traceparent generation and correlation ID utilities. The OpenTelemetry SDK (OTLP exporter)
/// is the integration point for span export to the platform collector; propagation is independent.
/// </summary>
public static class Tracing
{
    /// <summary>
    /// Generates a W3C traceparent string (version=00, random trace-id + span-id, sampled flag=01).
    /// </summary>
    public static string NewTraceParent()
    {
        Span<byte> traceId = stackalloc byte[16];
        Span<byte> spanId  = stackalloc byte[8];
        RandomNumberGenerator.Fill(traceId);
        RandomNumberGenerator.Fill(spanId);
        return $"00-{Convert.ToHexString(traceId).ToLowerInvariant()}-{Convert.ToHexString(spanId).ToLowerInvariant()}-01";
    }

    /// <summary>Generates a new correlation ID (random hex, 32 chars).</summary>
    public static string NewCorrelationId()
    {
        Span<byte> buf = stackalloc byte[16];
        RandomNumberGenerator.Fill(buf);
        return Convert.ToHexString(buf).ToLowerInvariant();
    }
}
''' % ns
    w.write("src/Observability/Tracing.cs", body, banner=True)


# ---------------------------------------------------------------------------
# HTTP: health / probe / version endpoints
# ---------------------------------------------------------------------------

def _health(w: Writer, ns: str) -> None:
    body = '''\
using Dkd.Platform;
using Microsoft.AspNetCore.Http;

namespace %s.Http;

/// <summary>
/// Standard health, readiness, liveness, and version endpoints. No business logic.
/// The {success, data, error} response envelope follows the Dokandar REST standard.
/// </summary>
public static class HealthEndpoints
{
    public static IResult Health() =>
        Results.Ok(new { success = true, data = new { status = "ok" } });

    public static IResult Live() =>
        Results.Ok(new { success = true, data = new { status = "alive" } });

    /// <summary>
    /// Readiness: returns 503 until the startup gate (migrations + dependency checks) succeeds.
    /// ASP.NET Core resolves ReadinessState from DI automatically when declared as a parameter.
    /// </summary>
    public static IResult Ready(ReadinessState state) =>
        state.IsReady
            ? Results.Ok(new { success = true, data = new { status = "ready" } })
            : Results.Json(
                new { success = false, error = new { status = "not-ready" } },
                statusCode: StatusCodes.Status503ServiceUnavailable);

    /// <summary>
    /// Version: reports the dkd-platform SDK contract version for provenance traceability.
    /// ContractVersion is sourced from the Dkd.Platform NuGet package (dkd-platform-libs).
    /// </summary>
    public static IResult Version() =>
        Results.Ok(new { success = true, data = new
        {
            contractVersion = Provenance.ContractVersion,
            sdkGenerator    = Provenance.Generator,
        }});
}
''' % ns
    w.write("src/Http/HealthEndpoints.cs", body, banner=True)


# ---------------------------------------------------------------------------
# Middleware: correlation ID + W3C traceparent
# ---------------------------------------------------------------------------

def _middleware_correlation(w: Writer, ns: str) -> None:
    body = '''\
using %s.Observability;

namespace %s.Http.Middleware;

/// <summary>
/// Ensures every inbound request carries a correlation ID and W3C traceparent.
/// Generates new values when the caller does not supply them and echoes them on the response.
/// </summary>
public sealed class CorrelationMiddleware(RequestDelegate next)
{
    public async Task InvokeAsync(HttpContext ctx)
    {
        var corrId = ctx.Request.Headers["X-Correlation-Id"].FirstOrDefault()
                     ?? Tracing.NewCorrelationId();
        var traceParent = ctx.Request.Headers["traceparent"].FirstOrDefault()
                          ?? Tracing.NewTraceParent();

        ctx.Items[AppLogger.Keys.CorrelationId] = corrId;
        ctx.Items[AppLogger.Keys.TraceParent]   = traceParent;
        ctx.Response.Headers["X-Correlation-Id"] = corrId;
        ctx.Response.Headers["traceparent"]       = traceParent;

        await next(ctx);
    }
}
''' % (ns, ns)
    w.write("src/Http/Middleware/CorrelationMiddleware.cs", body, banner=True)


# ---------------------------------------------------------------------------
# Middleware: request logging + metrics
# ---------------------------------------------------------------------------

def _middleware_logging(w: Writer, ns: str) -> None:
    body = '''\
using System.Diagnostics;
using %s.Observability;

namespace %s.Http.Middleware;

/// <summary>
/// Logs every request (method, path, status, elapsed ms, correlation ID) and increments the
/// http_requests_total counter. Runs after CorrelationMiddleware so the ID is always present.
/// </summary>
public sealed class RequestLoggingMiddleware(
    RequestDelegate next,
    ILogger<RequestLoggingMiddleware> logger,
    AppMetrics metrics)
{
    public async Task InvokeAsync(HttpContext ctx)
    {
        var start = Stopwatch.GetTimestamp();
        metrics.Increment("http_requests_total");

        await next(ctx);

        var elapsed = Stopwatch.GetElapsedTime(start);
        var corrId  = ctx.Items.TryGetValue(AppLogger.Keys.CorrelationId, out var v) ? v as string : null;

        logger.LogInformation(
            "request {Method} {Path} {StatusCode} {ElapsedMs}ms {CorrelationId}",
            ctx.Request.Method,
            ctx.Request.Path,
            ctx.Response.StatusCode,
            (long)elapsed.TotalMilliseconds,
            corrId);
    }
}
''' % (ns, ns)
    w.write("src/Http/Middleware/RequestLoggingMiddleware.cs", body, banner=True)


# ---------------------------------------------------------------------------
# Middleware: security headers
# ---------------------------------------------------------------------------

def _middleware_security(w: Writer, ns: str) -> None:
    body = '''\
namespace %s.Http.Middleware;

/// <summary>
/// Sets conservative security response headers on every outbound response.
/// Headers are applied via OnStarting to ensure they precede any response body.
/// </summary>
public sealed class SecurityHeadersMiddleware(RequestDelegate next)
{
    public Task InvokeAsync(HttpContext ctx)
    {
        // API Documentation Standard: the strict CSP is relaxed ONLY for the Swagger UI paths
        // (/docs, /swagger) which need inline script/style; all API/data responses keep default-src 'none'.
        var isDocs = ctx.Request.Path.StartsWithSegments("/docs")
                     || ctx.Request.Path.StartsWithSegments("/swagger");
        ctx.Response.OnStarting(() =>
        {
            var h = ctx.Response.Headers;
            h["X-Content-Type-Options"] = "nosniff";
            h["Referrer-Policy"]         = "no-referrer";
            if (isDocs)
                h["Content-Security-Policy"] =
                    "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; " +
                    "img-src 'self' data:; font-src 'self'; connect-src 'self'";
            else
            {
                h["X-Frame-Options"]         = "DENY";
                h["Content-Security-Policy"] = "default-src 'none'";
            }
            return Task.CompletedTask;
        });
        return next(ctx);
    }
}
''' % ns
    w.write("src/Http/Middleware/SecurityHeadersMiddleware.cs", body, banner=True)


# ---------------------------------------------------------------------------
# Middleware: centralized RFC-7807 exception handling
# ---------------------------------------------------------------------------

def _middleware_exception(w: Writer, svc: Service, ns: str) -> None:
    ctx = svc.context
    body = '''\
using Microsoft.AspNetCore.Http;

namespace %s.Http.Middleware;

/// <summary>
/// Outermost middleware: catches all unhandled exceptions and converts them to RFC-7807
/// problem+json responses with the Dokandar error code taxonomy
/// dokandar.%s.{category}.{reason}. Never leaks stack traces to callers.
/// </summary>
public sealed class ExceptionHandlingMiddleware(
    RequestDelegate next,
    ILogger<ExceptionHandlingMiddleware> logger)
{
    public async Task InvokeAsync(HttpContext ctx)
    {
        try
        {
            await next(ctx);
        }
        catch (ArgumentException ex) when (!ctx.Response.HasStarted)
        {
            logger.LogWarning(ex, "Validation error on {Path}", ctx.Request.Path);
            await WriteProblemAsync(ctx, 400, "Validation Error", ex.Message,
                "dokandar.%s.validation.invalid-input");
        }
        catch (UnauthorizedAccessException ex) when (!ctx.Response.HasStarted)
        {
            logger.LogWarning(ex, "Unauthorized on {Path}", ctx.Request.Path);
            await WriteProblemAsync(ctx, 401, "Unauthorized", ex.Message,
                "dokandar.%s.auth.unauthorized");
        }
        catch (Exception ex) when (!ctx.Response.HasStarted)
        {
            logger.LogError(ex, "Unhandled exception on {Path}", ctx.Request.Path);
            await WriteProblemAsync(ctx, 500, "Internal Server Error",
                "An unexpected error occurred.",
                "dokandar.%s.internal.error");
        }
    }

    private static async Task WriteProblemAsync(
        HttpContext ctx, int status, string title, string detail, string code)
    {
        ctx.Response.StatusCode  = status;
        ctx.Response.ContentType = "application/problem+json";
        await ctx.Response.WriteAsJsonAsync(new
        {
            type     = "about:blank",
            title,
            status,
            detail,
            instance = ctx.Request.Path.Value,
            code,
        });
    }
}
''' % (ns, ctx, ctx, ctx, ctx)
    w.write("src/Http/Middleware/ExceptionHandlingMiddleware.cs", body, banner=True)


# ---------------------------------------------------------------------------
# Middleware: JWT bearer authentication (optional — does not reject anon)
# ---------------------------------------------------------------------------

def _middleware_jwt(w: Writer, ns: str) -> None:
    body = '''\
using %s.Security;

namespace %s.Http.Middleware;

/// <summary>
/// Optional JWT authentication middleware: extracts the bearer token, parses and verifies it via
/// <see cref="JwtAuthenticator"/>, then attaches the <see cref="DkdClaims"/> to HttpContext.Items.
/// Does NOT reject unauthenticated requests — health endpoints remain public. Use
/// <see cref="JwtAuthenticator.GetClaims"/> and <see cref="JwtAuthenticator.HasRole"/> downstream
/// to enforce route-level authorization.
/// </summary>
public sealed class JwtAuthMiddleware(RequestDelegate next, JwtAuthenticator auth)
{
    private const string BearerPrefix = "Bearer ";

    public async Task InvokeAsync(HttpContext ctx)
    {
        var token = ExtractBearer(ctx.Request);
        if (token is not null)
        {
            var claims = auth.TryAuthenticate(token);
            if (claims is not null)
                ctx.Items[nameof(DkdClaims)] = claims;
        }
        await next(ctx);
    }

    private static string? ExtractBearer(HttpRequest request)
    {
        var header = request.Headers.Authorization.FirstOrDefault();
        return header?.StartsWith(BearerPrefix, StringComparison.OrdinalIgnoreCase) == true
            ? header[BearerPrefix.Length..]
            : null;
    }
}
''' % (ns, ns)
    w.write("src/Http/Middleware/JwtAuthMiddleware.cs", body, banner=True)


# ---------------------------------------------------------------------------
# Security: JWT authenticator + claims + verifier interface
# ---------------------------------------------------------------------------

def _security(w: Writer, ns: str) -> None:
    body = '''\
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.AspNetCore.Http;

namespace %s.Security;

/// <summary>Minimal claim set issued by the Dokandar platform (see dkd-platform-libs JwtClaims).</summary>
public sealed record DkdClaims(
    [property: JsonPropertyName("sub")]      string   Sub,
    [property: JsonPropertyName("kyc_tier")] string   KycTier,
    [property: JsonPropertyName("roles")]    string[] Roles,
    [property: JsonPropertyName("cid")]      string   Cid);

/// <summary>
/// JWT signature verifier — integration point for the platform JWKS endpoint.
/// Throw <see cref="UnauthorizedAccessException"/> when the token signature is invalid.
/// </summary>
public interface IJwtVerifier
{
    void Verify(string token);
}

/// <summary>
/// No-op verifier: accepts all tokens without signature verification.
/// Safe for local development only. Replace with the Dkd.Platform JWKS verifier in all
/// non-local environments.
/// </summary>
public sealed class NoopJwtVerifier : IJwtVerifier
{
    public void Verify(string token) { }
}

/// <summary>
/// Authenticates bearer JWTs: base64url-decodes the payload, deserialises
/// <see cref="DkdClaims"/>, then delegates signature verification to the injected
/// <see cref="IJwtVerifier"/>. Returns null (never throws) when authentication fails.
/// </summary>
public sealed class JwtAuthenticator(IJwtVerifier verifier)
{
    private static readonly JsonSerializerOptions _jsonOpts = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    /// <summary>Returns parsed claims on success; null on any structural or verification failure.</summary>
    public DkdClaims? TryAuthenticate(string token)
    {
        try
        {
            verifier.Verify(token);
            var parts = token.Split('.');
            if (parts.Length != 3) return null;
            var json = DecodeSegment(parts[1]);
            return JsonSerializer.Deserialize<DkdClaims>(json, _jsonOpts);
        }
        catch
        {
            return null;
        }
    }

    /// <summary>
    /// RBAC authorization helper: returns true when the claims contain the given role (case-insensitive).
    /// Pair with the platform PDP for ABAC enforcement.
    /// </summary>
    public static bool HasRole(DkdClaims? claims, string role) =>
        claims?.Roles.Contains(role, StringComparer.OrdinalIgnoreCase) == true;

    /// <summary>Retrieves claims attached by <see cref="JwtAuthMiddleware"/> from the current request context.</summary>
    public static DkdClaims? GetClaims(HttpContext ctx) =>
        ctx.Items.TryGetValue(nameof(DkdClaims), out var v) ? v as DkdClaims : null;

    private static string DecodeSegment(string segment)
    {
        var padded = (segment.Length %% 4) switch
        {
            2 => segment + "==",
            3 => segment + "=",
            _ => segment,
        };
        var bytes = Convert.FromBase64String(padded.Replace('-', '+').Replace('_', '/'));
        return Encoding.UTF8.GetString(bytes);
    }
}
''' % ns
    w.write("src/Security/JwtAuthenticator.cs", body, banner=True)


# ---------------------------------------------------------------------------
# Messaging: IPublisher, IConsumer, NoopPublisher, NoopConsumer (all in one file)
# ---------------------------------------------------------------------------

def _messaging(w: Writer, ns: str) -> None:
    body = '''\
namespace %s.Messaging;

/// <summary>
/// Event-bus abstractions for the Dokandar Published Language (R6). Concrete Kafka (Redpanda) and
/// RabbitMQ client implementations are the integration point — wire them in the adapters layer.
/// No business events are defined here; topic names and payload schemas come from
/// dkd-contracts-spine/messaging.yaml.
/// </summary>

/// <summary>Handler delegate invoked by <see cref="IConsumer"/> for each received message.</summary>
public delegate Task MessageHandler(
    string topic,
    string key,
    ReadOnlyMemory<byte> payload,
    CancellationToken ct);

/// <summary>
/// Event publisher abstraction (Kafka cross-context Published Language + RabbitMQ intra-context).
/// Implementations must guarantee at-least-once delivery via the transactional outbox pattern.
/// </summary>
public interface IPublisher : IAsyncDisposable
{
    Task PublishAsync(
        string topic,
        string key,
        ReadOnlyMemory<byte> payload,
        CancellationToken ct = default);
}

/// <summary>
/// Event consumer abstraction. Implementations must provide inbox deduplication on event_id
/// and per-topic DLQ with replay (park-and-freeze on poison messages — never silently drop).
/// </summary>
public interface IConsumer : IAsyncDisposable
{
    Task SubscribeAsync(
        IReadOnlyList<string> topics,
        MessageHandler handler,
        CancellationToken ct = default);
}

/// <summary>
/// No-op publisher: safe default for local runs without a broker. Replace with the Redpanda
/// (Kafka-compatible) driver at the integration point for all non-local environments.
/// </summary>
public sealed class NoopPublisher : IPublisher
{
    public Task PublishAsync(string topic, string key, ReadOnlyMemory<byte> payload, CancellationToken ct = default)
        => Task.CompletedTask;

    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}

/// <summary>No-op consumer: mirrors NoopPublisher for local development parity.</summary>
public sealed class NoopConsumer : IConsumer
{
    public Task SubscribeAsync(IReadOnlyList<string> topics, MessageHandler handler, CancellationToken ct = default)
        => Task.CompletedTask;

    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
''' % ns
    w.write("src/Messaging/Messaging.cs", body, banner=True)


# ---------------------------------------------------------------------------
# Persistence: IDb, ITx, RepositoryBase, IMigrator, NoopMigrator (all in one file)
# ---------------------------------------------------------------------------

def _persistence(w: Writer, ns: str) -> None:
    body = '''\
namespace %s.Persistence;

/// <summary>
/// Persistence abstractions for the hexagonal adapters layer. The concrete Npgsql/pgx driver is
/// the integration point — no business repositories are defined here. Each bounded context adds
/// its own repository implementations (inheriting RepositoryBase) in the adapters ring.
/// </summary>

/// <summary>Unit-of-work handle for an active database transaction.</summary>
public interface ITx
{
    /// <summary>Execute a parameterised SQL statement within the transaction.</summary>
    Task ExecuteAsync(string sql, object? parameters = null, CancellationToken ct = default);
}

/// <summary>
/// Database abstraction: ping (readiness), WithTransactionAsync (tx helper), and lifecycle.
/// The concrete implementation wraps a connection pool (e.g. NpgsqlDataSource).
/// </summary>
public interface IDb : IAsyncDisposable
{
    /// <summary>Verifies the database is reachable; used by the /ready probe.</summary>
    Task PingAsync(CancellationToken ct = default);

    /// <summary>
    /// Executes <paramref name="fn"/> inside a database transaction. Commits on success;
    /// rolls back and re-throws on any exception.
    /// </summary>
    Task<T> WithTransactionAsync<T>(Func<ITx, Task<T>> fn, CancellationToken ct = default);
}

/// <summary>
/// Base class for all context repositories. Carries the IDb handle and exposes the transaction
/// helper. Business repositories in the adapters ring inherit from this class.
/// </summary>
public abstract class RepositoryBase(IDb db)
{
    protected IDb Db { get; } = db;

    /// <summary>Convenience wrapper: executes <paramref name="fn"/> in a transaction.</summary>
    protected Task<T> InTransactionAsync<T>(Func<ITx, Task<T>> fn, CancellationToken ct = default)
        => Db.WithTransactionAsync(fn, ct);
}

/// <summary>
/// Schema migration abstraction: Apply runs ordered, idempotent SQL migrations at startup.
/// Replace NoopMigrator with a real driver (DbUp, Evolve, or EF Core Migrate) at the
/// integration point. Migrations run before the readiness gate flips to true.
/// </summary>
public interface IMigrator
{
    Task Apply(CancellationToken ct = default);
}

/// <summary>No-op migrator: safe default for local runs without a real database wired.</summary>
public sealed class NoopMigrator : IMigrator
{
    public Task Apply(CancellationToken ct = default) => Task.CompletedTask;
}
''' % ns
    w.write("src/Persistence/Persistence.cs", body, banner=True)


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

def _validation(w: Writer, ns: str) -> None:
    body = '''\
namespace %s.Validation;

/// <summary>
/// Input validation helpers for system boundary enforcement. Validate all external input before
/// processing (coding-style: fail fast with a clear error, never coerce silently).
/// ExceptionHandlingMiddleware converts ArgumentException to RFC-7807 400 responses.
/// </summary>
public static class InputValidator
{
    /// <summary>Throws <see cref="ArgumentException"/> when the value is null, empty, or whitespace.</summary>
    public static string Required(string fieldName, string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
            throw new ArgumentException($"{fieldName} is required", fieldName);
        return value;
    }

    /// <summary>Throws <see cref="ArgumentOutOfRangeException"/> when the value is not positive.</summary>
    public static int Positive(string fieldName, int value)
    {
        if (value <= 0)
            throw new ArgumentOutOfRangeException(fieldName, value, $"{fieldName} must be positive");
        return value;
    }

    /// <summary>
    /// Throws <see cref="ArgumentOutOfRangeException"/> when the value exceeds the allowed maximum length.
    /// </summary>
    public static string MaxLength(string fieldName, string value, int maxLength)
    {
        if (value.Length > maxLength)
            throw new ArgumentOutOfRangeException(
                fieldName, value.Length, $"{fieldName} must not exceed {maxLength} characters");
        return value;
    }
}
''' % ns
    w.write("src/Validation/InputValidator.cs", body, banner=True)


# ---------------------------------------------------------------------------
# Tests: unit (xunit, WebApplicationFactory)
# ---------------------------------------------------------------------------

def _tests_unit(w: Writer, svc: Service, ns: str) -> None:
    # Test project file
    w.write("tests/%s.Tests/%s.Tests.csproj" % (ns, ns), '''\
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <IsPackable>false</IsPackable>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk"              Version="17.12.0" />
    <PackageReference Include="xunit"                               Version="2.9.0"   />
    <PackageReference Include="xunit.runner.visualstudio"           Version="2.8.2"   />
    <PackageReference Include="Microsoft.AspNetCore.Mvc.Testing"    Version="10.0.0"   />
    <PackageReference Include="Dkd.Platform"                        Version="1.0.0"   />
  </ItemGroup>

  <ItemGroup>
    <ProjectReference Include="../../%s.csproj" />
  </ItemGroup>

</Project>
''' % ns)

    # Health endpoint unit tests
    w.write("tests/%s.Tests/HealthEndpointsTests.cs" % ns, '''\
using System.Net;
using System.Text.Json;
using Microsoft.AspNetCore.Mvc.Testing;
using Xunit;

namespace %s.Tests;

/// <summary>
/// Unit-level tests for the standard health / probe / version endpoints.
/// Uses WebApplicationFactory to boot the full minimal-API pipeline without external infra.
/// </summary>
public sealed class HealthEndpointsTests(WebApplicationFactory<Program> factory)
    : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly HttpClient _client = factory.CreateClient();

    [Fact]
    public async Task GetHealth_Returns200()
    {
        var response = await _client.GetAsync("/health");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    [Fact]
    public async Task GetLive_Returns200()
    {
        var response = await _client.GetAsync("/live");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    [Fact]  // API Documentation Standard: Swagger UI must be served at /docs
    public async Task GetDocs_Returns200()
    {
        var response = await _client.GetAsync("/docs/index.html");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    [Fact]  // API Documentation Standard: OpenAPI JSON must be served at /swagger/v1/swagger.json
    public async Task GetSwaggerJson_Returns200()
    {
        var response = await _client.GetAsync("/swagger/v1/swagger.json");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    [Fact]
    public async Task GetHealth_ResponseBodyContainsSuccessEnvelope()
    {
        var response = await _client.GetAsync("/health");
        var body     = await response.Content.ReadAsStringAsync();
        using var doc = JsonDocument.Parse(body);
        Assert.True(doc.RootElement.GetProperty("success").GetBoolean());
    }

    [Fact]
    public async Task GetVersion_Returns200_WithContractVersion()
    {
        var response = await _client.GetAsync("/version");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var body = await response.Content.ReadAsStringAsync();
        Assert.Contains("contractVersion", body, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task AllProbes_SetCorrelationIdResponseHeader()
    {
        foreach (var path in new[] { "/health", "/live" })
        {
            var response = await _client.GetAsync(path);
            Assert.True(
                response.Headers.Contains("X-Correlation-Id"),
                $"{path} must echo X-Correlation-Id header");
        }
    }

    [Fact]
    public async Task AllProbes_SetSecurityHeaders()
    {
        var response = await _client.GetAsync("/health");
        Assert.True(response.Headers.Contains("X-Content-Type-Options"),
            "X-Content-Type-Options security header must be present");
    }
}
''' % ns, banner=True)


# ---------------------------------------------------------------------------
# Tests: integration (Trait-gated, requires docker infra)
# ---------------------------------------------------------------------------

def _tests_integration(w: Writer, svc: Service, ns: str) -> None:
    w.write("tests/%s.IntegrationTests/%s.IntegrationTests.csproj" % (ns, ns), '''\
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <IsPackable>false</IsPackable>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk"           Version="17.12.0" />
    <PackageReference Include="xunit"                            Version="2.9.0"   />
    <PackageReference Include="xunit.runner.visualstudio"        Version="2.8.2"   />
    <PackageReference Include="Microsoft.AspNetCore.Mvc.Testing" Version="10.0.0"   />
    <PackageReference Include="Dkd.Platform"                     Version="1.0.0"   />
    <!--
      Testcontainers manages ephemeral Docker containers for Postgres, Redpanda, and RabbitMQ.
      The integration CI stage provides Docker-in-Docker; locally: Docker Desktop or Colima.
    -->
    <PackageReference Include="Testcontainers"            Version="4.1.0" />
    <PackageReference Include="Testcontainers.PostgreSql" Version="4.1.0" />
  </ItemGroup>

  <ItemGroup>
    <ProjectReference Include="../../%s.csproj" />
  </ItemGroup>

</Project>
''' % ns)

    w.write("tests/%s.IntegrationTests/IntegrationTest.cs" % ns, '''\
using Microsoft.AspNetCore.Mvc.Testing;
using Xunit;

namespace %s.IntegrationTests;

/// <summary>
/// Integration tests require ephemeral Docker infra (Postgres, Redpanda, RabbitMQ).
/// Run with: dotnet test --filter "Category=Integration"
/// The integration CI stage (see .gitlab-ci.yml) provisions these via Docker-in-Docker.
/// Testcontainers manages container lifecycle; add fixture classes here as infra is wired in.
/// </summary>
[Trait("Category", "Integration")]
public sealed class ServiceBootsTest(WebApplicationFactory<Program> factory)
    : IClassFixture<WebApplicationFactory<Program>>
{
    /// <summary>
    /// Verifies the service starts and returns 200 on /health against the real pipeline
    /// (all middleware, DI wiring, migrations, readiness gate).
    /// </summary>
    [Fact]
    public async Task GetHealth_WhenServiceBoots_Returns200()
    {
        // Brought up by the integration CI stage (postgres + redpanda + rabbitmq).
        // In local runs without docker infra: dotnet test --filter "Category!=Integration"
        var client   = factory.CreateClient();
        var response = await client.GetAsync("/health");
        Assert.Equal(System.Net.HttpStatusCode.OK, response.StatusCode);
    }
}
''' % ns, banner=True)


# ---------------------------------------------------------------------------
# Dockerfile (multi-stage, non-root)
# ---------------------------------------------------------------------------

def _dockerfile(w: Writer, svc: Service, ns: str) -> None:
    w.write("Dockerfile", '''\
# Multi-stage C# / .NET 8 build.
# Stage 1 (build): SDK image — compiles and publishes a self-contained-ready binary.
# Stage 2 (runtime): ASP.NET runtime image — strips SDK, runs as the built-in non-root app user.
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# Restore dependencies in a dedicated layer for cache efficiency.
COPY %s.csproj ./
RUN dotnet restore

# Publish optimised release build.
COPY . .
RUN dotnet publish %s.csproj -c Release -o /out --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app

COPY --from=build /out .

EXPOSE %d 9090

# The built-in non-root 'app' user (uid 1654) ships in the aspnet image.
USER app

ENTRYPOINT ["dotnet", "%s.dll"]
''' % (ns, ns, svc.http_port, ns))


# ---------------------------------------------------------------------------
# GitLab CI
# ---------------------------------------------------------------------------

def _ci(w: Writer, svc: Service, ns: str) -> None:
    w.write(".gitlab-ci.yml", '''\
stages: [build, package]

variables:
  DOTNET_NOLOGO: "true"
  DOTNET_CLI_TELEMETRY_OPTOUT: "true"

dotnet:build-test:
  stage: build
  image: mcr.microsoft.com/dotnet/sdk:10.0
  before_script:
    # Register the GitLab package registry as a NuGet source so dkd-platform-libs (Dkd.Platform)
    # can be restored using the CI job token without embedding credentials in source.
    - >
      dotnet nuget add source
      "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/packages/nuget/index.json"
      --name gitlab
      --username gitlab-ci-token
      --password "${CI_JOB_TOKEN}"
      --store-password-in-clear-text
  script:
    - dotnet restore
    - dotnet build -c Release --no-restore
    - dotnet test tests/%s.Tests/%s.Tests.csproj -c Release --no-build --verbosity normal

dotnet:integration:
  stage: build
  image: mcr.microsoft.com/dotnet/sdk:10.0
  services:
    - name: postgres:16-alpine
      alias: postgres
    - name: redpandadata/redpanda:v24.1.7
      alias: redpanda
    - name: rabbitmq:3.13-alpine
      alias: rabbitmq
  variables:
    POSTGRES_USER: dkd
    POSTGRES_PASSWORD: dkd
    POSTGRES_DB: %s
    DKD_DB_DSN: "Host=postgres;Username=dkd;Password=dkd;Database=%s"
    DKD_KAFKA_BROKERS: "redpanda:9092"
    DKD_RABBITMQ_URL: "amqp://guest:guest@rabbitmq:5672/"
  before_script:
    - >
      dotnet nuget add source
      "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/packages/nuget/index.json"
      --name gitlab
      --username gitlab-ci-token
      --password "${CI_JOB_TOKEN}"
      --store-password-in-clear-text
  script:
    - dotnet restore
    - dotnet build -c Release --no-restore
    - >
      dotnet test tests/%s.IntegrationTests/%s.IntegrationTests.csproj
      -c Release --no-build --filter "Category=Integration"
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
    - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'

docker:build:
  stage: package
  image: docker:27
  services: [docker:27-dind]
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
  script:
    - docker login -u "$CI_REGISTRY_USER" -p "$CI_REGISTRY_PASSWORD" "$CI_REGISTRY"
    - docker build -t "$CI_REGISTRY_IMAGE:0.1.0" .
    - docker push "$CI_REGISTRY_IMAGE:0.1.0"
''' % (ns, ns, svc.pkg, svc.pkg, ns, ns))


# ---------------------------------------------------------------------------
# Makefile
# ---------------------------------------------------------------------------

def _makefile(w: Writer, svc: Service, ns: str) -> None:
    w.write("Makefile", '''\
.PHONY: run build test itest lint

run:
\tdotnet run --project %s.csproj

build:
\tdotnet build -c Release

lint:
\tdotnet build -c Release -warnaserror

test:
\tdotnet test tests/%s.Tests/%s.Tests.csproj -c Release --verbosity normal

itest:
\tdotnet test tests/%s.IntegrationTests/%s.IntegrationTests.csproj \\
\t\t--filter "Category=Integration" --verbosity normal
''' % (ns, ns, ns, ns, ns))
