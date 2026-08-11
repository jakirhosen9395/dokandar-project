// REST /v1 surface for Identity. External API per EF §7: {success,data,error,meta} envelope,
// RFC-7807 errors (via ExceptionHandlingMiddleware), Idempotency-Key on unsafe writes. Each endpoint
// carries full OpenAPI metadata (name/summary/description/tags + Accepts/Produces/ProducesProblem) so
// Swagger discovers every operation and every request/response model gets a schema.
// Authorization: caller roles are resolved from the verified JWT at the edge (the PDP seam); in the
// dev substrate via X-Dkd-Roles / X-Dkd-Caller-Did headers (gateway-injected in production).
using Dkd.Platform;
using IdentitySvc.Application;
using IdentitySvc.Domain;
using Microsoft.AspNetCore.Mvc;

namespace IdentitySvc.Http;

// Response payload models (wrapped by the {success,data,error,meta} envelope) — each generates a schema.
public sealed record DidRef(string Did);
public sealed record CommandAck(string Did, string Status);

public static class PartyEndpoints
{
    public sealed record RegisterReq(string PhoneNumber, string? DeviceId, string? Locale, string OtpToken);
    public sealed record SubmitKycReq(string NidNumber, IReadOnlyList<string>? DocumentUrls, string? SelfieUrl, string? TierRequested);
    public sealed record ApproveReq(string VerifierDid, string? Notes);
    public sealed record UpgradeReq(string TargetTier, string VerifierDid, string? Notes, string? Bin, string? Tin);
    public sealed record RejectReq(string Reason, string VerifierDid);
    public sealed record SuspendReq(string Reason, string By);
    public sealed record ReactivateReq(string By);

    private const string IdemHdr = "Idempotency-Key";
    private const string RolesHdr = "X-Dkd-Roles";

    public static void MapPartyEndpoints(this WebApplication app)
    {
        app.MapPost("/v1/parties",
            async (RegisterReq req, [FromHeader(Name = IdemHdr)] string? idempotencyKey,
                   PartyService svc, CancellationToken ct) =>
            {
                var did = await svc.RegisterPartyAsync(
                    new RegisterPartyCommand(req.PhoneNumber, req.DeviceId, req.Locale, req.OtpToken), ct);
                return Results.Created($"/v1/parties/{did}", Response<DidRef>.Ok(new DidRef(did)));
            })
            .WithName("RegisterParty").WithTags("Parties")
            .WithSummary("Register a party")
            .WithDescription("Registers a new party (OTP-verified, unique phone) and issues an immutable DID.")
            .Accepts<RegisterReq>("application/json")
            .Produces<Response<DidRef>>(StatusCodes.Status201Created)
            .ProducesProblem(StatusCodes.Status400BadRequest)
            .ProducesProblem(StatusCodes.Status409Conflict);

        app.MapGet("/v1/parties/{did}",
            async (string did, PartyService svc, CancellationToken ct) =>
            {
                var view = await svc.GetPartyAsync(did, ct);
                return view is null
                    ? Results.NotFound(Response<object>.Fail(new Dkd.Platform.ProblemDetails(
                        "about:blank", "Not Found", 404, Errors.ErrorCode(ContextSlug.Identity, "party", "not_found"))))
                    : Results.Ok(Response<PartyView>.Ok(view));
            })
            .WithName("GetParty").WithTags("Parties")
            .WithSummary("Get a party")
            .WithDescription("Returns the party read model (phone masked; the raw phone is resolved only via the gRPC OHS).")
            .Produces<Response<PartyView>>(StatusCodes.Status200OK)
            .ProducesProblem(StatusCodes.Status404NotFound);

        app.MapPost("/v1/parties/{did}/kyc",
            async (string did, SubmitKycReq req, [FromHeader(Name = IdemHdr)] string? idempotencyKey,
                   PartyService svc, CancellationToken ct) =>
            {
                await svc.SubmitKycAsync(new SubmitKycCommand(did, req.NidNumber, req.DocumentUrls, req.SelfieUrl, req.TierRequested), ct);
                return Results.Accepted($"/v1/parties/{did}", Response<CommandAck>.Ok(new CommandAck(did, "kyc_submitted")));
            })
            .WithName("SubmitKyc").WithTags("Parties")
            .WithSummary("Submit KYC")
            .WithDescription("Submits KYC (raw NID is hashed, never stored) and queues async review over RabbitMQ.")
            .Accepts<SubmitKycReq>("application/json")
            .Produces<Response<CommandAck>>(StatusCodes.Status202Accepted)
            .ProducesProblem(StatusCodes.Status400BadRequest)
            .ProducesProblem(StatusCodes.Status404NotFound);

        app.MapPost("/v1/parties/{did}/kyc/approve",
            async (string did, ApproveReq req, [FromHeader(Name = IdemHdr)] string? idempotencyKey,
                   [FromHeader(Name = RolesHdr)] string? roles, PartyService svc, HttpContext http, CancellationToken ct) =>
            {
                await svc.ApproveKycAsync(new ApproveKycCommand(did, req.VerifierDid, req.Notes), Caller(http), ct);
                return Results.Ok(Response<CommandAck>.Ok(new CommandAck(did, "kyc_approved")));
            })
            .WithName("ApproveKyc").WithTags("Parties")
            .WithSummary("Approve KYC (SYSTEM role)")
            .WithDescription("Approves KYC (UNVERIFIED → BASIC). Requires the SYSTEM role via X-Dkd-Roles.")
            .Accepts<ApproveReq>("application/json")
            .Produces<Response<CommandAck>>(StatusCodes.Status200OK)
            .ProducesProblem(StatusCodes.Status403Forbidden)
            .ProducesProblem(StatusCodes.Status404NotFound)
            .ProducesProblem(StatusCodes.Status409Conflict);

        app.MapPost("/v1/parties/{did}/kyc/upgrade",
            async (string did, UpgradeReq req, [FromHeader(Name = IdemHdr)] string? idempotencyKey,
                   [FromHeader(Name = RolesHdr)] string? roles, PartyService svc, HttpContext http, CancellationToken ct) =>
            {
                await svc.UpgradeKycTierAsync(new UpgradeKycTierCommand(did, req.TargetTier, req.VerifierDid, req.Notes, req.Bin, req.Tin), Caller(http), ct);
                return Results.Ok(Response<CommandAck>.Ok(new CommandAck(did, $"kyc_tier_changed:{req.TargetTier}")));
            })
            .WithName("UpgradeKyc").WithTags("Parties")
            .WithSummary("Upgrade KYC tier (SYSTEM role)")
            .WithDescription("Upgrades the KYC tier to FULL or BUSINESS (monotonic; BUSINESS requires a BIN). Requires SYSTEM role.")
            .Accepts<UpgradeReq>("application/json")
            .Produces<Response<CommandAck>>(StatusCodes.Status200OK)
            .ProducesProblem(StatusCodes.Status403Forbidden)
            .ProducesProblem(StatusCodes.Status404NotFound)
            .ProducesProblem(StatusCodes.Status409Conflict);

        app.MapPost("/v1/parties/{did}/kyc/reject",
            async (string did, RejectReq req, [FromHeader(Name = IdemHdr)] string? idempotencyKey,
                   [FromHeader(Name = RolesHdr)] string? roles, PartyService svc, HttpContext http, CancellationToken ct) =>
            {
                await svc.RejectKycAsync(new RejectKycCommand(did, req.Reason, req.VerifierDid), Caller(http), ct);
                return Results.Ok(Response<CommandAck>.Ok(new CommandAck(did, "kyc_rejected")));
            })
            .WithName("RejectKyc").WithTags("Parties")
            .WithSummary("Reject KYC (SYSTEM role)")
            .WithDescription("Rejects a KYC submission with a reason. Requires the SYSTEM role.")
            .Accepts<RejectReq>("application/json")
            .Produces<Response<CommandAck>>(StatusCodes.Status200OK)
            .ProducesProblem(StatusCodes.Status403Forbidden)
            .ProducesProblem(StatusCodes.Status404NotFound);

        app.MapPost("/v1/parties/{did}/suspend",
            async (string did, SuspendReq req, [FromHeader(Name = IdemHdr)] string? idempotencyKey,
                   [FromHeader(Name = RolesHdr)] string? roles, PartyService svc, HttpContext http, CancellationToken ct) =>
            {
                await svc.SuspendPartyAsync(new SuspendPartyCommand(did, req.Reason, req.By), Caller(http), ct);
                return Results.Ok(Response<CommandAck>.Ok(new CommandAck(did, "suspended")));
            })
            .WithName("SuspendParty").WithTags("Parties")
            .WithSummary("Suspend a party (ENFORCEMENT role)")
            .WithDescription("Suspends an ACTIVE party. Requires the ENFORCEMENT role via X-Dkd-Roles.")
            .Accepts<SuspendReq>("application/json")
            .Produces<Response<CommandAck>>(StatusCodes.Status200OK)
            .ProducesProblem(StatusCodes.Status403Forbidden)
            .ProducesProblem(StatusCodes.Status404NotFound)
            .ProducesProblem(StatusCodes.Status409Conflict);

        app.MapPost("/v1/parties/{did}/reactivate",
            async (string did, ReactivateReq req, [FromHeader(Name = IdemHdr)] string? idempotencyKey,
                   PartyService svc, CancellationToken ct) =>
            {
                await svc.ReactivatePartyAsync(new ReactivatePartyCommand(did, req.By), ct);
                return Results.Ok(Response<CommandAck>.Ok(new CommandAck(did, "reactivated")));
            })
            .WithName("ReactivateParty").WithTags("Parties")
            .WithSummary("Reactivate a party")
            .WithDescription("Reactivates a SUSPENDED party.")
            .Accepts<ReactivateReq>("application/json")
            .Produces<Response<CommandAck>>(StatusCodes.Status200OK)
            .ProducesProblem(StatusCodes.Status404NotFound)
            .ProducesProblem(StatusCodes.Status409Conflict);

        // ID-01: bind a device to a party — Party.AddDevice enforces MAX_DEVICES=10 (422 device_limit).
        app.MapPost("/v1/parties/{did}/devices",
            async (string did, AddDeviceReq req, [FromHeader(Name = IdemHdr)] string? idempotencyKey,
                   PartyService svc, CancellationToken ct) =>
            {
                await svc.AddDeviceAsync(did, req.DeviceId, ct);
                return Results.Ok(Response<CommandAck>.Ok(new CommandAck(did, "device_added")));
            })
            .WithName("AddDevice").WithTags("Parties")
            .WithSummary("Bind a device to a party (MAX_DEVICES=10)")
            .Accepts<AddDeviceReq>("application/json")
            .Produces<Response<CommandAck>>(StatusCodes.Status200OK)
            .ProducesProblem(StatusCodes.Status404NotFound)
            .ProducesProblem(StatusCodes.Status422UnprocessableEntity);
    }

    public sealed record AddDeviceReq(string DeviceId);

    private static CallerContext Caller(HttpContext http)
    {
        var roles = new HashSet<VerifierRole>();
        var raw = http.Request.Headers[RolesHdr].ToString();
        foreach (var part in raw.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            if (Enum.TryParse<VerifierRole>(part, ignoreCase: true, out var r)) roles.Add(r);
        var callerDid = http.Request.Headers["X-Dkd-Caller-Did"].ToString();
        return new CallerContext(string.IsNullOrEmpty(callerDid) ? null : callerDid, roles);
    }
}
