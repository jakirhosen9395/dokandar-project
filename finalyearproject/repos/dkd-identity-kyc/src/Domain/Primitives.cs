// Domain primitives for the Identity/Party/KYC context (#1).
// Enums and value objects transcribed from DOKANDAR-Domain-Model.md "Context #1 — Identity/KYC".
// No business rule invented; every type traces to the frozen Domain Model.
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Dkd.Platform;

namespace IdentitySvc.Domain;

/// <summary>KYC tier ladder (DM: UNVERIFIED -> BASIC -> FULL -> BUSINESS). Monotonic for limits,
/// reversible on adverse evidence. The BA V0..V3 tiers map 1:1 onto these names via the
/// FR-IDN-310 enum registry (V0=UNVERIFIED, V1=BASIC, V2=FULL, V3=BUSINESS).</summary>
public enum KycTier { UNVERIFIED = 0, BASIC = 1, FULL = 2, BUSINESS = 3 }

/// <summary>Party lifecycle status (DM: ACTIVE | SUSPENDED | DELETED).</summary>
public enum PartyStatus { ACTIVE, SUSPENDED, DELETED }

/// <summary>Verifier/caller roles used by command preconditions (DM command table).
/// SYSTEM performs KYC approve/upgrade/reject; ENFORCEMENT suspends parties.</summary>
public enum VerifierRole { SYSTEM, ENFORCEMENT }

/// <summary>Phone value object — E.164 Bangladesh MSISDN (+880XXXXXXXXXX). PII: Identity DB only.</summary>
public sealed record Phone
{
    private static readonly Regex E164Bd = new(@"^\+8801[3-9]\d{8}$", RegexOptions.Compiled);
    public string Value { get; }
    public Phone(string value)
    {
        if (value is null || !E164Bd.IsMatch(value))
            throw new ValidationException(
                Errors.ErrorCode(ContextSlug.Identity, "validation", "msisdn_invalid"),
                "phoneNumber must be a Bangladesh E.164 MSISDN (+8801XXXXXXXXX)");
        Value = value;
    }
    public override string ToString() => Value;
}

/// <summary>NID hash value object — SHA-256(rawNID) lowercase hex. The raw NID is NEVER stored
/// (DM invariant; C1 PII rule). Constructed only from a raw NID which is immediately hashed.</summary>
public sealed record NidHash
{
    public string Value { get; }
    private NidHash(string hex) { Value = hex; }

    /// <summary>Hash a raw NID. The raw value is used only transiently and never persisted.</summary>
    public static NidHash FromRawNid(string rawNid)
    {
        if (string.IsNullOrWhiteSpace(rawNid))
            throw new ValidationException(
                Errors.ErrorCode(ContextSlug.Identity, "validation", "nid_invalid"), "NID is required");
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(rawNid.Trim()));
        return new NidHash(Convert.ToHexStringLower(bytes));
    }

    /// <summary>Rehydrate from a stored hash (persistence only).</summary>
    public static NidHash FromHash(string hex) => new(hex);
    public override string ToString() => Value;
}
