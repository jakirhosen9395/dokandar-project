// REST surface (SA §14.5): reads hit the SELECT-only gov_read connection (R5 at the DB);
// the only writes are intervention decisions (maker/checker, Idempotency-Key mandatory).
// Envelope {success,data,error,meta}; problem+json errors; caller roles from X-Dkd-Roles
// (the PDP seam — the gateway supplies verified claims; security waived in this environment).
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Npgsql;

namespace OversightSvc;

public static class Api
{
    public static void Map(WebApplication app, NpgsqlDataSource owner, NpgsqlDataSource read,
        Config cfg)
    {
        // ---- read side (gov_read role, SELECT-only) ----
        app.MapGet("/v1/oversight/trades", async () =>
            await Rows(read, "SELECT trd, seller_did, buyer_did, total_amount_poisha, status, " +
                             "created_at, as_of FROM national_trade_view ORDER BY as_of DESC LIMIT 100",
                r => new
                {
                    trd = r.GetString(0), sellerDid = r.GetString(1), buyerDid = r.GetString(2),
                    totalAmountPoisha = r.GetInt64(3), status = r.GetString(4),
                    createdAt = r.GetInt64(5), asOf = r.GetInt64(6),
                }));

        app.MapGet("/v1/oversight/market-health", async () =>
            await Rows(read, "SELECT gpid, total_quantity, unit, computed_at " +
                             "FROM national_inventory_summary ORDER BY computed_at DESC LIMIT 100",
                r => new
                {
                    gpid = r.GetString(0), totalQuantity = r.GetInt64(1), unit = r.GetString(2),
                    computedAt = r.GetInt64(3),
                }));

        app.MapGet("/v1/oversight/settlements", async () =>
            await Rows(read, "SELECT esc, amount_poisha, status, reference_id, as_of " +
                             "FROM escrow_summary ORDER BY as_of DESC LIMIT 100",
                r => new
                {
                    esc = r.GetString(0), amountPoisha = r.GetInt64(1), status = r.GetString(2),
                    referenceId = r.GetString(3), asOf = r.GetInt64(4),
                }));

        app.MapGet("/v1/oversight/compliance/{did}", async (string did) =>
        {
            await using var cx = await read.OpenConnectionAsync();
            await using var cmd = new NpgsqlCommand(
                "SELECT did, kyc_tier, status, suspension_history::text, fraud_flags::text, as_of " +
                "FROM party_compliance_view WHERE did = $1", cx);
            cmd.Parameters.AddWithValue(did);
            await using var r = await cmd.ExecuteReaderAsync();
            if (!await r.ReadAsync())
                return Problem(404, "dokandar.government.compliance.not_found", "no view for DID");
            return Ok(new
            {
                did = r.GetString(0), kycTier = r.GetString(1), status = r.GetString(2),
                suspensionHistory = JsonSerializer.Deserialize<JsonElement>(r.GetString(3)),
                fraudFlags = JsonSerializer.Deserialize<JsonElement>(r.GetString(4)),
                asOf = r.GetInt64(5),
            });
        });

        // ---- intervention decision records (maker/checker; the ONLY writes, R5) ----
        app.MapPost("/v1/interventions", async (HttpContext http) =>
        {
            var idem = http.Request.Headers["Idempotency-Key"].ToString();
            using var body = await JsonDocument.ParseAsync(http.Request.Body);
            var p = body.RootElement;
            return await Idempotent(owner, idem, "POST /v1/interventions", p, 201, async (cx, tx) =>
            {
                var kind = Domain.ParseKind(GetStr(p, "kind"));
                var makerDid = GetStr(p, "makerDid");
                if (!Domain.IsDid(makerDid))
                    throw new DomainException(400, "dokandar.government.validation.maker",
                        "makerDid must be a did:dokandar DID");
                if (!p.TryGetProperty("payload", out var payload) || payload.ValueKind != JsonValueKind.Object)
                    throw new DomainException(400, "dokandar.government.validation.payload",
                        "payload object is required");
                Domain.ValidatePayload(kind, payload);
                var con = Domain.NewCon();
                var now = Domain.NowMs();
                var hash = Domain.PayloadHash(payload);
                await Stores.InsertCase(cx, tx, con, kind, payload, hash, makerDid!, now);
                return new Dictionary<string, object?>
                {
                    ["con"] = con, ["kind"] = kind.ToString(), ["status"] = "PROPOSED",
                    ["makerDid"] = makerDid, ["payloadHash"] = hash,
                    ["requestedAt"] = now,
                };
            });
        });

        app.MapPost("/v1/interventions/{con}/approve", async (string con, HttpContext http) =>
        {
            var idem = http.Request.Headers["Idempotency-Key"].ToString();
            using var body = await JsonDocument.ParseAsync(http.Request.Body);
            var p = body.RootElement;
            return await Idempotent(owner, idem, $"POST /v1/interventions/{con}/approve", p, 200,
                async (cx, tx) =>
                {
                    var row = await Stores.LockCase(cx, tx, con)
                        ?? throw new DomainException(404, "dokandar.government.intervention.not_found",
                            "no such intervention case");
                    var checker = GetStr(p, "checkerDid") ?? "";
                    var presentedHash = GetStr(p, "payloadHash") ?? row.PayloadHash;
                    var now = Domain.NowMs();
                    Domain.RequireApprovable(row.Status, row.MakerDid, checker, row.PayloadHash,
                        presentedHash, row.RequestedAt, cfg.CaseExpiryMs, now);
                    // APPROVED and ORDERED commit atomically with the directive in the outbox:
                    // only an APPROVED case may emit, and an ORDERED case always has emitted.
                    if (!await Stores.TransitionCase(cx, tx, con, "PROPOSED", "APPROVED", checker,
                            null, null, now))
                        throw new DomainException(409, "dokandar.government.intervention.conflict",
                            "concurrent decision");
                    var directiveId = await EmitDirective(cx, tx, row, now);
                    if (!await Stores.TransitionCase(cx, tx, con, "APPROVED", "ORDERED", null, null,
                            directiveId, now))
                        throw new DomainException(409, "dokandar.government.intervention.conflict",
                            "concurrent decision");
                    return new Dictionary<string, object?>
                    {
                        ["con"] = con, ["status"] = "ORDERED", ["checkerDid"] = checker,
                        ["directiveId"] = directiveId, ["decidedAt"] = now,
                    };
                });
        });

        app.MapPost("/v1/interventions/{con}/reject", async (string con, HttpContext http) =>
        {
            var idem = http.Request.Headers["Idempotency-Key"].ToString();
            using var body = await JsonDocument.ParseAsync(http.Request.Body);
            var p = body.RootElement;
            return await Idempotent(owner, idem, $"POST /v1/interventions/{con}/reject", p, 200,
                async (cx, tx) =>
                {
                    var row = await Stores.LockCase(cx, tx, con)
                        ?? throw new DomainException(404, "dokandar.government.intervention.not_found",
                            "no such intervention case");
                    var checker = GetStr(p, "checkerDid") ?? "";
                    var now = Domain.NowMs();
                    Domain.RequireApprovable(row.Status, row.MakerDid, checker, row.PayloadHash,
                        row.PayloadHash, row.RequestedAt, cfg.CaseExpiryMs, now);
                    if (!await Stores.TransitionCase(cx, tx, con, "PROPOSED", "REJECTED", checker,
                            GetStr(p, "reason") ?? "REJECTED", null, now))
                        throw new DomainException(409, "dokandar.government.intervention.conflict",
                            "concurrent decision");
                    return new Dictionary<string, object?>
                    {
                        ["con"] = con, ["status"] = "REJECTED", ["checkerDid"] = checker,
                    };
                });
        });

        app.MapGet("/v1/interventions/{con}", async (string con) =>
        {
            await using var cx = await read.OpenConnectionAsync();
            await using var cmd = new NpgsqlCommand(
                "SELECT con, kind, status, maker_did, checker_did, directive_id, payload::text, " +
                "requested_at FROM intervention_cases WHERE con = $1", cx);
            cmd.Parameters.AddWithValue(con);
            await using var r = await cmd.ExecuteReaderAsync();
            if (!await r.ReadAsync())
                return Problem(404, "dokandar.government.intervention.not_found", "no such case");
            return Ok(new
            {
                con = r.GetString(0), kind = r.GetString(1), status = r.GetString(2),
                makerDid = r.GetString(3), checkerDid = r.IsDBNull(4) ? null : r.GetString(4),
                directiveId = r.IsDBNull(5) ? null : r.GetString(5),
                payload = JsonSerializer.Deserialize<JsonElement>(r.GetString(6)),
                requestedAt = r.GetInt64(7),
            });
        });
    }

    private static async Task<string> EmitDirective(NpgsqlConnection cx, NpgsqlTransaction tx,
        Stores.CaseRow row, long now)
    {
        using var doc = JsonDocument.Parse(row.PayloadJson);
        var p = doc.RootElement;
        var reason = GetStr(p, "reason") ?? "UNSPECIFIED";
        var authority = GetStr(p, "authority") ?? "GOVERNMENT_OF_BANGLADESH";
        switch (Enum.Parse<DirectiveKind>(row.Kind))
        {
            case DirectiveKind.RECALL:
            {
                var recallId = Domain.NewRecallId();
                var gpids = p.GetProperty("gpids").EnumerateArray()
                    .Select(g => g.GetString()!).ToList();
                await Events.RecallDirectiveIssued(cx, tx, recallId, gpids, reason, authority,
                    row.CheckerDid ?? row.MakerDid, now);
                return recallId;
            }
            case DirectiveKind.TRADE_FREEZE:
            {
                var id = Domain.NewDirectiveId();
                await Events.TradeFreezeDirective(cx, tx, id, p.GetProperty("trd").GetString()!,
                    reason, authority, row.CheckerDid ?? row.MakerDid, now);
                return id;
            }
            default:
            {
                var id = Domain.NewDirectiveId();
                await Events.WalletFreezeDirective(cx, tx, id,
                    p.GetProperty("ownerDid").GetString()!, reason, authority,
                    row.CheckerDid ?? row.MakerDid, now);
                return id;
            }
        }
    }

    // ---- envelope/idempotency plumbing ----

    private static async Task<IResult> Idempotent(NpgsqlDataSource ds, string idemKey,
        string endpoint, JsonElement body, int successStatus,
        Func<NpgsqlConnection, NpgsqlTransaction, Task<Dictionary<string, object?>>> action)
    {
        if (string.IsNullOrWhiteSpace(idemKey))
            return Problem(400, "dokandar.government.request.missing_idempotency_key",
                "Idempotency-Key header is mandatory on oversight writes");
        var requestHash = Convert.ToHexStringLower(
            SHA256.HashData(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(body))));
        await using var cx = await ds.OpenConnectionAsync();
        var stored = await Stores.IdemFind(cx, idemKey, endpoint);
        if (stored is not null) return Replay(stored, requestHash);
        await using var tx = await cx.BeginTransactionAsync();
        try
        {
            var data = await action(cx, tx);
            var bodyJson = JsonSerializer.Serialize(data);
            await Stores.IdemInsert(cx, tx, idemKey, endpoint, requestHash, successStatus,
                bodyJson, Domain.NowMs());
            await tx.CommitAsync();
            return Results.Json(new { success = true, data, error = (object?)null,
                meta = new { replayed = false } }, statusCode: successStatus);
        }
        catch (DomainException e)
        {
            await tx.RollbackAsync();
            // A concurrent same-key winner may have committed while we ran (reviewer H-1):
            // the idempotency contract says this caller must see the WINNER's outcome.
            var winner = await Stores.IdemFind(cx, idemKey, endpoint);
            if (winner is not null) return Replay(winner, requestHash);
            if (e.Code.EndsWith(".lapsed", StringComparison.Ordinal))
                await MarkLapsed(cx, endpoint); // FR-GOV-021: expiry is a recorded state, not just a 409
            await StoreFailure(cx, idemKey, endpoint, requestHash, e);
            return Problem(e.Status, e.Code, e.Message);
        }
        catch (PostgresException pg) when (pg.SqlState == "23505")
        {
            await tx.RollbackAsync();
            var winner = await Stores.IdemFind(cx, idemKey, endpoint);
            return winner is not null
                ? Replay(winner, requestHash)
                : Problem(409, "dokandar.government.request.conflict", "concurrent duplicate");
        }
    }

    /// <summary>Best-effort LAPSED transition after an expiry rejection (fresh tx).</summary>
    private static async Task MarkLapsed(NpgsqlConnection cx, string endpoint)
    {
        var con = endpoint.Split('/') is { Length: >= 3 } parts ? parts[^2] : "";
        if (!con.StartsWith("CON-", StringComparison.Ordinal)) return;
        await using var tx = await cx.BeginTransactionAsync();
        await Stores.TransitionCase(cx, tx, con, "PROPOSED", "LAPSED", null, "EXPIRED", null,
            Domain.NowMs());
        await tx.CommitAsync();
    }

    private static async Task StoreFailure(NpgsqlConnection cx, string key, string endpoint,
        string requestHash, DomainException e)
    {
        try
        {
            await using var tx = await cx.BeginTransactionAsync();
            await Stores.IdemInsert(cx, tx, key, endpoint, requestHash, e.Status,
                JsonSerializer.Serialize(new { __error = new { code = e.Code, message = e.Message } }),
                Domain.NowMs());
            await tx.CommitAsync();
        }
        catch (PostgresException pg) when (pg.SqlState == "23505")
        { /* a concurrent winner stored the outcome first — keep theirs */ }
    }

    private static IResult Replay(Stores.StoredResponse stored, string requestHash)
    {
        if (stored.RequestHash != requestHash)
            return Problem(409, "dokandar.government.request.idempotency_key_reuse",
                "Idempotency-Key was already used with a different request body");
        using var doc = JsonDocument.Parse(stored.BodyJson);
        if (doc.RootElement.TryGetProperty("__error", out var err))
            return Problem(stored.Status, err.GetProperty("code").GetString()!,
                err.GetProperty("message").GetString()!);
        return Results.Json(new
        {
            success = true,
            data = JsonSerializer.Deserialize<JsonElement>(stored.BodyJson),
            error = (object?)null,
            meta = new { replayed = true },
        }, statusCode: stored.Status);
    }

    private static async Task<IResult> Rows<T>(NpgsqlDataSource ds, string sql,
        Func<NpgsqlDataReader, T> map)
    {
        await using var cx = await ds.OpenConnectionAsync();
        await using var cmd = new NpgsqlCommand(sql, cx);
        var items = new List<T>();
        await using var r = await cmd.ExecuteReaderAsync();
        while (await r.ReadAsync()) items.Add(map(r));
        return Ok(new { items, asOf = Domain.NowMs() });
    }

    private static IResult Ok(object data) =>
        Results.Json(new { success = true, data, error = (object?)null, meta = (object?)null });

    private static IResult Problem(int status, string code, string detail) =>
        Results.Json(new
        {
            type = "about:blank", title = code[(code.LastIndexOf('.') + 1)..],
            status, code, detail,
        }, statusCode: status, contentType: "application/problem+json");

    private static string? GetStr(JsonElement p, string name) =>
        p.ValueKind == JsonValueKind.Object && p.TryGetProperty(name, out var v)
        && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
}
