// Idempotency for unsafe REST writes. The Idempotency-Key header is MANDATORY on POST /v1/parties*
// (EF §7 / CLAUDE.md API standard). The first success is stored per key and replayed on retry, so
// clients can safely retry without creating duplicates. Read/GET requests are unaffected.
using System.Security.Cryptography;
using System.Text;
using Dkd.Platform;
using Npgsql;
using NpgsqlTypes;

namespace IdentitySvc.Http.Middleware;

public sealed class IdempotencyMiddleware(RequestDelegate next, NpgsqlDataSource ds, ILogger<IdempotencyMiddleware> log)
{
    public async Task InvokeAsync(HttpContext ctx)
    {
        var isUnsafeWrite = HttpMethods.IsPost(ctx.Request.Method)
                            && ctx.Request.Path.StartsWithSegments("/v1/parties");
        if (!isUnsafeWrite) { await next(ctx); return; }

        var key = ctx.Request.Headers["Idempotency-Key"].ToString();
        if (string.IsNullOrWhiteSpace(key))
        {
            await WriteProblemAsync(ctx, 400,
                Errors.ErrorCode(ContextSlug.Identity, "validation", "idempotency_key_required"),
                "Idempotency-Key header is required on write requests");
            return;
        }

        // ID-02: hash the request body so a key reused with a DIFFERENT payload is a 409, not a
        // silent replay of the first request's response.
        ctx.Request.EnableBuffering();
        string reqBody;
        using (var reader = new StreamReader(ctx.Request.Body, Encoding.UTF8, leaveOpen: true))
            reqBody = await reader.ReadToEndAsync(ctx.RequestAborted);
        ctx.Request.Body.Position = 0;
        var reqHash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(reqBody)));

        await using var conn = await ds.OpenConnectionAsync(ctx.RequestAborted);

        // Replay a previously stored response for this key — unless the body differs (409).
        await using (var q = new NpgsqlCommand(
            "SELECT response_status, response_body::text, request_hash FROM idempotency_keys WHERE key = @k", conn))
        {
            q.Parameters.AddWithValue("k", key);
            await using var r = await q.ExecuteReaderAsync(ctx.RequestAborted);
            if (await r.ReadAsync(ctx.RequestAborted))
            {
                var storedHash = r.IsDBNull(2) ? null : r.GetString(2);
                if (storedHash is not null && storedHash != reqHash)
                {
                    await WriteProblemAsync(ctx, 409,
                        Errors.ErrorCode(ContextSlug.Identity, "conflict", "idempotency_key_reused"),
                        "Idempotency-Key was already used with a different request body");
                    return;
                }
                ctx.Response.StatusCode = r.GetInt32(0);
                ctx.Response.ContentType = "application/json; charset=utf-8";
                ctx.Response.Headers["Idempotency-Replayed"] = "true";
                await ctx.Response.WriteAsync(r.GetString(1), ctx.RequestAborted);
                return;
            }
        }

        // Buffer the response so we can record it after the endpoint runs.
        var original = ctx.Response.Body;
        using var buffer = new MemoryStream();
        ctx.Response.Body = buffer;
        try { await next(ctx); }
        finally { ctx.Response.Body = original; }

        buffer.Position = 0;
        var body = await new StreamReader(buffer).ReadToEndAsync(ctx.RequestAborted);
        buffer.Position = 0;
        await buffer.CopyToAsync(original, ctx.RequestAborted);

        // Only record successful outcomes so failed attempts remain retryable.
        if (ctx.Response.StatusCode is >= 200 and < 300)
        {
            try
            {
                await using var ins = new NpgsqlCommand(
                    @"INSERT INTO idempotency_keys (key, method, path, response_status, response_body, request_hash, created_at)
                      VALUES (@k, @m, @p, @s, @b, @h, @t) ON CONFLICT (key) DO NOTHING", conn);
                ins.Parameters.AddWithValue("k", key);
                ins.Parameters.AddWithValue("m", ctx.Request.Method);
                ins.Parameters.AddWithValue("p", ctx.Request.Path.Value ?? "");
                ins.Parameters.AddWithValue("s", ctx.Response.StatusCode);
                ins.Parameters.Add(new NpgsqlParameter("b", NpgsqlDbType.Jsonb) { Value = string.IsNullOrEmpty(body) ? "{}" : body });
                ins.Parameters.AddWithValue("h", reqHash);
                ins.Parameters.AddWithValue("t", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
                await ins.ExecuteNonQueryAsync(ctx.RequestAborted);
            }
            catch (Exception ex) { log.LogWarning(ex, "idempotency store failed for key {Key}", key); }
        }
    }

    private static async Task WriteProblemAsync(HttpContext ctx, int status, string code, string detail)
    {
        ctx.Response.StatusCode = status;
        ctx.Response.ContentType = "application/problem+json";
        await ctx.Response.WriteAsJsonAsync(new
        { type = "about:blank", title = "Validation Error", status, detail, instance = ctx.Request.Path.Value, code });
    }
}
