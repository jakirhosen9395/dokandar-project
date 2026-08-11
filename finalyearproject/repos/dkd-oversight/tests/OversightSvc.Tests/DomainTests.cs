// Four-eyes rules (FR-GOV-019/020/021/022), directive payload validation, ID conventions.
using System.Text.Json;
using OversightSvc;
using Xunit;

namespace OversightSvc.Tests;

public class DomainTests
{
    private static JsonElement Json(string s) => JsonDocument.Parse(s).RootElement.Clone();

    // ---- four-eyes gate ----

    [Fact]
    public void SelfApprovalIsRejected()
    {
        var e = Assert.Throws<DomainException>(() => Domain.RequireApprovable(
            "PROPOSED", "did:dokandar:maker", "did:dokandar:maker", "h", "h", 0, 1000, 500));
        Assert.Equal(409, e.Status);
        Assert.Contains("self_approval", e.Code);
    }

    [Fact]
    public void ApprovalBindsToPayloadHash()
    {
        var e = Assert.Throws<DomainException>(() => Domain.RequireApprovable(
            "PROPOSED", "did:dokandar:maker", "did:dokandar:checker", "bound-hash",
            "other-hash", 0, 1000, 500));
        Assert.Contains("payload_drift", e.Code);
    }

    [Fact]
    public void ExpiredRequestLapses()
    {
        var e = Assert.Throws<DomainException>(() => Domain.RequireApprovable(
            "PROPOSED", "did:dokandar:maker", "did:dokandar:checker", "h", "h",
            requestedAt: 0, expiryMs: 1000, now: 5000));
        Assert.Contains("lapsed", e.Code);
    }

    [Fact]
    public void OnlyProposedCasesAreDecidable()
    {
        var e = Assert.Throws<DomainException>(() => Domain.RequireApprovable(
            "ORDERED", "did:dokandar:maker", "did:dokandar:checker", "h", "h", 0, 1000, 500));
        Assert.Contains("bad_state", e.Code);
    }

    [Fact]
    public void DistinctCheckerWithinExpiryPasses()
    {
        Domain.RequireApprovable("PROPOSED", "did:dokandar:maker", "did:dokandar:checker",
            "h", "h", 0, 1000, 500); // no throw
    }

    // ---- directive payload validation (registry shapes, DM §#11) ----

    [Fact]
    public void RecallRequiresGpids()
    {
        Domain.ValidatePayload(DirectiveKind.RECALL,
            Json("""{"gpids":["GP-rice-1"],"reason":"contamination"}"""));
        Assert.Throws<DomainException>(() => Domain.ValidatePayload(DirectiveKind.RECALL,
            Json("""{"gpids":[],"reason":"x"}""")));
        Assert.Throws<DomainException>(() => Domain.ValidatePayload(DirectiveKind.RECALL,
            Json("""{"gpids":["not-a-gpid"],"reason":"x"}""")));
    }

    [Fact]
    public void WalletFreezeCarriesOwnerDidNeverWlt()
    {
        Domain.ValidatePayload(DirectiveKind.WALLET_FREEZE,
            Json("""{"ownerDid":"did:dokandar:abc","reason":"court order"}"""));
        // M-NEW-1: a WLT is finance-internal — the directive must carry the DID.
        Assert.Throws<DomainException>(() => Domain.ValidatePayload(DirectiveKind.WALLET_FREEZE,
            Json("""{"wlt":"WLT-1","reason":"court order"}""")));
    }

    [Fact]
    public void TradeFreezeRequiresTrd()
    {
        Domain.ValidatePayload(DirectiveKind.TRADE_FREEZE,
            Json("""{"trd":"TRD-1","reason":"manipulation"}"""));
        Assert.Throws<DomainException>(() => Domain.ValidatePayload(DirectiveKind.TRADE_FREEZE,
            Json("""{"trd":"ORD-1","reason":"x"}""")));
    }

    [Fact]
    public void ReasonIsAlwaysRequired()
    {
        Assert.Throws<DomainException>(() => Domain.ValidatePayload(DirectiveKind.TRADE_FREEZE,
            Json("""{"trd":"TRD-1"}""")));
    }

    [Fact]
    public void UnknownKindRejected()
    {
        Assert.Throws<DomainException>(() => Domain.ParseKind("PRICE_CAP"));
        Assert.Equal(DirectiveKind.RECALL, Domain.ParseKind("recall"));
    }

    // ---- misc conventions ----

    [Fact]
    public void PayloadHashIsStableAndHex()
    {
        var a = Domain.PayloadHash(Json("""{"trd":"TRD-1","reason":"x"}"""));
        var b = Domain.PayloadHash(Json("""{"trd":"TRD-1","reason":"x"}"""));
        Assert.Equal(a, b);
        Assert.Equal(64, a.Length);
    }

    [Fact]
    public void IdsCarryCanonPrefixesAndUuid7Version()
    {
        Assert.StartsWith("CON-", Domain.NewCon());
        Assert.StartsWith("RCL-", Domain.NewRecallId());
        var body = Domain.NewCon()[4..];
        Assert.Equal('7', body.Split('-')[2][0]);
    }
}
