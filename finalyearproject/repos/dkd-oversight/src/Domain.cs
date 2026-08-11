// InterventionCase aggregate (SA §14.3): DRAFTED→PROPOSED→APPROVED→ORDERED→CLOSED/REJECTED
// (+LAPSED on expiry, FR-GOV-021). Four-eyes is enforced INSIDE the aggregate: checker≠maker,
// approval binds to the immutable payload hash (FR-GOV-022). R5: the ONLY writable state is
// Government's own decision records — every operational effect leaves as a Kafka directive.
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace OversightSvc;

public enum CaseStatus { DRAFTED, PROPOSED, APPROVED, ORDERED, REJECTED, CLOSED, LAPSED }

public enum DirectiveKind { RECALL, TRADE_FREEZE, WALLET_FREEZE }

public sealed class DomainException(int status, string code, string message) : Exception(message)
{
    public int Status { get; } = status;
    public string Code { get; } = code;
}

public static class Domain
{
    public static string NewCon() => "CON-" + Uuid7();
    public static string NewDirectiveId() => Uuid7();
    public static string NewRecallId() => "RCL-" + Uuid7();
    public static string NewEventId() => Uuid7();
    public static long NowMs() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    public static bool IsDid(string? s) =>
        s is not null && s.StartsWith("did:dokandar:", StringComparison.Ordinal) && s.Length > 13;

    /// <summary>Canonical hash the checker's approval binds to (FR-GOV-022).</summary>
    public static string PayloadHash(JsonElement payload)
    {
        var canonical = JsonSerializer.Serialize(payload);
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(canonical)));
    }

    public static DirectiveKind ParseKind(string? raw) => raw?.ToUpperInvariant() switch
    {
        "RECALL" => DirectiveKind.RECALL,
        "TRADE_FREEZE" => DirectiveKind.TRADE_FREEZE,
        "WALLET_FREEZE" => DirectiveKind.WALLET_FREEZE,
        _ => throw new DomainException(400, "dokandar.government.validation.kind",
            "kind must be RECALL | TRADE_FREEZE | WALLET_FREEZE (the three registry directives)"),
    };

    /// <summary>Directive payload shape per the frozen registry (DM §#11) — validated at propose.</summary>
    public static void ValidatePayload(DirectiveKind kind, JsonElement p)
    {
        switch (kind)
        {
            case DirectiveKind.RECALL:
                if (!p.TryGetProperty("gpids", out var gpids) || gpids.ValueKind != JsonValueKind.Array
                    || gpids.GetArrayLength() == 0)
                    throw new DomainException(400, "dokandar.government.validation.gpids",
                        "RECALL requires gpids: [GPID, ...]");
                foreach (var g in gpids.EnumerateArray())
                    if (g.ValueKind != JsonValueKind.String || !g.GetString()!.StartsWith("GP", StringComparison.Ordinal))
                        throw new DomainException(400, "dokandar.government.validation.gpids",
                            "every recall target must be a GP- prefixed GPID");
                break;
            case DirectiveKind.TRADE_FREEZE:
                if (!p.TryGetProperty("trd", out var trd) || trd.ValueKind != JsonValueKind.String
                    || !trd.GetString()!.StartsWith("TRD-", StringComparison.Ordinal))
                    throw new DomainException(400, "dokandar.government.validation.trd",
                        "TRADE_FREEZE requires trd: TRD-…");
                break;
            case DirectiveKind.WALLET_FREEZE:
                if (!p.TryGetProperty("ownerDid", out var did) || !IsDid(did.GetString()))
                    throw new DomainException(400, "dokandar.government.validation.owner_did",
                        "WALLET_FREEZE requires ownerDid (M-NEW-1: the DID, never a WLT)");
                break;
        }
        if (!p.TryGetProperty("reason", out var reason) || reason.ValueKind != JsonValueKind.String
            || string.IsNullOrWhiteSpace(reason.GetString()))
            throw new DomainException(400, "dokandar.government.validation.reason", "reason is required");
    }

    /// <summary>Four-eyes (FR-GOV-019/022, BR-038): distinct checker, hash-bound, not expired.</summary>
    public static void RequireApprovable(string status, string makerDid, string checkerDid,
        string boundHash, string presentedHash, long requestedAt, long expiryMs, long now)
    {
        if (status != nameof(CaseStatus.PROPOSED))
            throw new DomainException(409, "dokandar.government.intervention.bad_state",
                $"only a PROPOSED case can be decided (case is {status})");
        if (now > requestedAt + expiryMs)
            throw new DomainException(409, "dokandar.government.intervention.lapsed",
                "the intervention request expired (FR-GOV-021) — propose it again");
        if (!IsDid(checkerDid))
            throw new DomainException(400, "dokandar.government.validation.checker",
                "checkerDid must be a did:dokandar DID");
        if (checkerDid == makerDid)
            throw new DomainException(409, "dokandar.government.intervention.self_approval",
                "self-approval is rejected and audited (four-eyes, FR-GOV-020/R5)");
        if (boundHash != presentedHash)
            throw new DomainException(409, "dokandar.government.intervention.payload_drift",
                "approval binds to the proposed payload hash (FR-GOV-022) — the payload changed");
    }

    private static string Uuid7()
    {
        Span<byte> b = stackalloc byte[16];
        RandomNumberGenerator.Fill(b);
        var ms = (ulong)DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        b[0] = (byte)(ms >> 40); b[1] = (byte)(ms >> 32); b[2] = (byte)(ms >> 24);
        b[3] = (byte)(ms >> 16); b[4] = (byte)(ms >> 8); b[5] = (byte)ms;
        b[6] = (byte)((b[6] & 0x0F) | 0x70);
        b[8] = (byte)((b[8] & 0x3F) | 0x80);
        var h = Convert.ToHexStringLower(b);
        return $"{h[..8]}-{h[8..12]}-{h[12..16]}-{h[16..20]}-{h[20..32]}";
    }
}
