using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.AspNetCore.Routing;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.AspNetCore.WebUtilities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;
using Microsoft.OpenApi.Models;
using Prometheus;
using Coupon;
using Coupon.Data;
using Coupon.Endpoints;
using Coupon.Grpc;
using Coupon.Messaging;
using Coupon.Observability;
using Coupon.Services;
using Elastic.Apm.NetCoreAll;
using AppMetrics = Coupon.Observability.Metrics;

// ---- fail-fast ----
if (string.IsNullOrWhiteSpace(Config.ServiceName)) { Console.Error.WriteLine("FATAL: SERVICE_NAME is required"); Environment.Exit(1); }
if (Config.AppEnv is "stage" or "prod")
{
    if (string.IsNullOrEmpty(Config.JwtPublicKeyB64)) { Console.Error.WriteLine("FATAL: JWT_PUBLIC_KEY_B64 required in stage/prod"); Environment.Exit(1); }
    if (string.IsNullOrEmpty(Config.InternalServiceToken)) { Console.Error.WriteLine("FATAL: INTERNAL_SERVICE_TOKEN required in stage/prod"); Environment.Exit(1); }
}

// ---- Elastic APM config via env (wire ServiceVersion — §16.1 landmine #5) ----
static void SetApm(string k, string? v) { if (!string.IsNullOrEmpty(v)) Environment.SetEnvironmentVariable(k, v); }
SetApm("ELASTIC_APM_SERVER_URL", Config.ApmServerUrl);
SetApm("ELASTIC_APM_SECRET_TOKEN", Config.ApmSecretToken);
SetApm("ELASTIC_APM_SERVICE_NAME", Config.ApmServiceName);
SetApm("ELASTIC_APM_ENVIRONMENT", Config.AppEnv);
SetApm("ELASTIC_APM_SERVICE_VERSION", Config.CodeVersion);
Environment.SetEnvironmentVariable("ELASTIC_APM_TRANSACTION_IGNORE_URLS", "/metrics,/ready,/health,/openapi.json,/docs,/docs/*");
Environment.SetEnvironmentVariable("ELASTIC_APM_VERIFY_SERVER_CERT", "false");
if (string.IsNullOrEmpty(Config.ApmServerUrl)) Environment.SetEnvironmentVariable("ELASTIC_APM_ENABLED", "false");

Log.StartSinks();
Log.Info("coupon.boot", $"starting {Config.ServiceName} code_version={Config.CodeVersion} rest={Config.ServicePort} grpc={Config.GrpcPort} tenant={Config.Tenant} env={Config.AppEnv}");

try { await DbBootstrap.EnsureAsync(); }
catch (Exception e) { Log.Error("coupon.boot", $"db bootstrap failed: {e.Message}"); Environment.Exit(1); }

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders(); // our 3-sink Log is the canonical logger

// Kestrel dual-listener: REST (Http1AndHttp2) + dedicated Http2-only gRPC (§16.1 landmine #1)
builder.WebHost.ConfigureKestrel(o =>
{
    o.ListenAnyIP(Config.ServicePort, l => l.Protocols = HttpProtocols.Http1AndHttp2);
    o.ListenAnyIP(Config.GrpcPort, l => l.Protocols = HttpProtocols.Http2);
});

builder.Services.ConfigureHttpJsonOptions(o =>
{
    o.SerializerOptions.WriteIndented = true;
    o.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower;
    o.SerializerOptions.DefaultIgnoreCondition = JsonIgnoreCondition.Never;
});

builder.Services.AddDbContext<CouponDbContext>(o => o
    .UseNpgsql(Config.PgConn(), n => { n.CommandTimeout(15); })
    .UseSnakeCaseNamingConvention()
    .ConfigureWarnings(w => w.Log((RelationalEventId.CommandError, LogLevel.Debug))));

builder.Services.AddSingleton<RedisService>();
builder.Services.AddScoped<CouponService>();
builder.Services.AddScoped<ValidationService>();
builder.Services.AddGrpc();
builder.Services.AddHostedService<OutboxRelay>();

builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen(c =>
{
    c.SwaggerDoc("v1", new OpenApiInfo
    {
        Title = "DOKANDAR Coupon Service",
        Version = Config.CodeVersion,
        Description =
            $"**service_name**: `{Config.ServiceName}` &nbsp;|&nbsp; **code_version**: `{Config.CodeVersion}` &nbsp;|&nbsp; " +
            $"**env_version**: `{Config.EnvVersion}` &nbsp;|&nbsp; **tenant**: `{Config.Tenant}` &nbsp;|&nbsp; **env**: `{Config.AppEnv}`\n\n" +
            "**07-coupon — discount engine (C#/.NET 10 / ASP.NET Core + EF Core 10).** Coupon templates " +
            "(percent/fixed/free_delivery/min_spend/first_order), the draft→approved→active→revoked/expired " +
            "lifecycle with four-eyes approval, and festival campaigns. Exposes gRPC `Coupon.ValidateCoupon @9090` " +
            "(cart + order call it) and REST `/api/v1/coupon/validate`. PostgreSQL sole writer + Redis DB6 cache " +
            "(degradable) + transactional outbox to Kafka. Money fields are integer **paisa** (BDT minor units). " +
            "Errors use the envelope `{error:{code,message,request_id,details}}` with lowercase snake-case codes.\n\n" +
            "### How to test\n" +
            "1. Click **Authorize** and paste a Bearer **access token** from the auth service " +
            "(`POST /api/v1/auth/login/request` → `/login/verify`). `draftCoupon`/`approveCoupon`/`revokeCoupon` " +
            "need a `shopkeeper`/`admin` token; `createFestival` needs `admin`. `listFestivals` is public.\n" +
            "2. Request bodies are pre-filled with working examples. `code` must be 3–40 chars; change it on reruns.\n" +
            "3. `validateCoupon` is an internal east-west call — it uses the `x-internal-token` header, not a user Bearer token.",
        Contact = new OpenApiContact
        {
            Name = "DOKANDAR Platform",
            Url = new Uri("https://dokandar.com.bd"),
            Email = "api@dokandar.com.bd",
        },
        License = new OpenApiLicense { Name = "Proprietary" },
    });
    var scheme = new OpenApiSecurityScheme
    {
        Name = "Authorization", Type = SecuritySchemeType.Http, Scheme = "bearer", BearerFormat = "JWT",
        In = ParameterLocation.Header, Description = "RS256 token minted by 01-auth",
        Reference = new OpenApiReference { Type = ReferenceType.SecurityScheme, Id = "HTTPBearer" },
    };
    c.AddSecurityDefinition("HTTPBearer", scheme);
    c.AddSecurityRequirement(new OpenApiSecurityRequirement { [scheme] = Array.Empty<string>() });
    // internal east-west surface (validateCoupon): x-internal-token apiKey header.
    c.AddSecurityDefinition("internalToken", new OpenApiSecurityScheme
    {
        Name = "x-internal-token", Type = SecuritySchemeType.ApiKey, In = ParameterLocation.Header,
        Description = "Shared INTERNAL_SERVICE_TOKEN for east-west calls (cart/order → coupon).",
    });
    // doc-only enrichment: servers, tag descriptions, shared ErrorEnvelope, per-op error responses + examples.
    c.DocumentFilter<Coupon.Swagger.CouponDocumentFilter>();
    c.OperationFilter<Coupon.Swagger.CouponOperationFilter>();
});

var app = builder.Build();

// recompute coupon_outbox_pending on each scrape
Prometheus.Metrics.DefaultRegistry.AddBeforeCollectCallback(async (ct) =>
{
    try
    {
        using var scope = app.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<CouponDbContext>();
        var n = await db.Outbox.CountAsync(o => o.SentAt == null, ct);
        AppMetrics.OutboxPending.WithLabels(AppMetrics.Svc).Set(n);
    }
    catch { }
});

// APM must be the FIRST middleware (outermost) — §16.1
app.UseAllElasticApm();

// request-id + access log + RED metrics
app.Use(async (ctx, next) =>
{
    var rid = ctx.Request.Headers["x-request-id"].ToString();
    if (string.IsNullOrEmpty(rid)) rid = Guid.NewGuid().ToString("N");
    ctx.Request.Headers["x-request-id"] = rid;
    ctx.Response.Headers["x-request-id"] = rid;
    var sw = Stopwatch.StartNew();
    try { await next(); }
    finally
    {
        var path = ctx.Request.Path.Value ?? "/";
        if (path != "/metrics")
        {
            var route = (ctx.GetEndpoint() as RouteEndpoint)?.RoutePattern.RawText ?? path;
            AppMetrics.HttpRequests.WithLabels(ctx.Request.Method, route, ctx.Response.StatusCode.ToString()).Inc();
            AppMetrics.HttpDuration.WithLabels(ctx.Request.Method, route).Observe(sw.Elapsed.TotalSeconds);
            if (path != "/ready" && ctx.Request.ContentType?.StartsWith("application/grpc") != true)
                Log.Access($"{ctx.Connection.RemoteIpAddress}:{ctx.Connection.RemotePort}", ctx.Request.Method, path, ctx.Response.StatusCode, ReasonPhrases.GetReasonPhrase(ctx.Response.StatusCode));
        }
    }
});

// error envelope — {error:{code,message,request_id}}; never leak raw 5xx
app.Use(async (ctx, next) =>
{
    try { await next(); }
    catch (ApiException ex) { await WriteErr(ctx, ex.Status, ex.Code, ex.Message); }
    catch (Exception ex) { Log.Error("coupon.error", $"unhandled: {ex.Message}"); await WriteErr(ctx, 500, "internal_error", "internal error"); }
});

app.UseSwagger(o => o.RouteTemplate = "{documentName}/openapi.json");
app.UseSwaggerUI(o =>
{
    o.SwaggerEndpoint("/v1/openapi.json", "v1");
    o.RoutePrefix = "docs";
    o.DocumentTitle = "07-coupon API"; // browser <title> — API_DOCS_STANDARD.md
    o.EnablePersistAuthorization();
});
// root alias so the fleet smoke's GET /openapi.json works
app.MapGet("/openapi.json", (Swashbuckle.AspNetCore.Swagger.ISwaggerProvider sp) =>
{
    var doc = sp.GetSwagger("v1");
    using var sw = new StringWriter();
    doc.SerializeAsV3(new Microsoft.OpenApi.Writers.OpenApiJsonWriter(sw));
    return Results.Text(sw.ToString(), "application/json");
}).ExcludeFromDescription();

app.MapGrpcService<CouponGrpcService>();
app.MapCouponEndpoints();
app.MapOpsEndpoints();
app.MapMetrics(); // prometheus-net text at /metrics
app.MapFallback(() => Results.StatusCode(404)); // bare-404 on unmapped paths

Log.Warn("coupon.boot", $"listening REST :{Config.ServicePort} gRPC :{Config.GrpcPort}");
await app.RunAsync();

static async Task WriteErr(HttpContext ctx, int status, string code, string message)
{
    if (ctx.Response.HasStarted) return;
    ctx.Response.Clear();
    ctx.Response.StatusCode = status;
    ctx.Response.ContentType = "application/json";
    var rid = ctx.Request.Headers["x-request-id"].ToString();
    var body = JsonSerializer.Serialize(new Dictionary<string, object?>
    {
        ["error"] = new Dictionary<string, object?> { ["code"] = code, ["message"] = message, ["request_id"] = rid },
    }, new JsonSerializerOptions { WriteIndented = true });
    await ctx.Response.WriteAsync(body + "\n");
}
