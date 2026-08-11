// Domain unit tests for the Party aggregate (Context #1). Cover the DM command table, state machine,
// role preconditions, tier invariants, and emitted events. Pure domain — no infrastructure.
using Dkd.Platform;
using IdentitySvc.Domain;
using Xunit;

namespace IdentitySvc.Tests;

public sealed class PartyDomainTests
{
    private const long Now = 1_770_000_000_000;
    private const string Phone1 = "+8801712345678";
    private static IReadOnlySet<VerifierRole> System => new HashSet<VerifierRole> { VerifierRole.SYSTEM };
    private static IReadOnlySet<VerifierRole> Enforcement => new HashSet<VerifierRole> { VerifierRole.ENFORCEMENT };
    private static IReadOnlySet<VerifierRole> None => new HashSet<VerifierRole>();

    private static Party NewRegistered() => Party.Register(new Phone(Phone1), "dev-1", "bn-BD", Now);

    [Fact]
    public void Register_mints_did_and_starts_unverified_active()
    {
        var p = NewRegistered();
        Assert.StartsWith(DID.Prefix, p.Did.Value);
        Assert.Equal(KycTier.UNVERIFIED, p.KycTier);
        Assert.Equal(PartyStatus.ACTIVE, p.Status);
        var ev = Assert.Single(p.DequeueEvents());
        var reg = Assert.IsType<PartyRegisteredV1>(ev);
        Assert.Equal("UNVERIFIED", reg.KycTier);
        Assert.Equal("kafka", reg.Bus);
        Assert.Equal(KafkaTopics.IDENTITY_PARTY_PARTY_REGISTERED_V1, reg.Destination);
        Assert.Equal(p.Did.Value, reg.PartitionKey);
    }

    [Fact]
    public void DequeueEvents_clears_the_buffer()
    {
        var p = NewRegistered();
        Assert.Single(p.DequeueEvents());
        Assert.Empty(p.DequeueEvents());
    }

    [Theory]
    [InlineData("017123")]          // too short, no +880
    [InlineData("+880171234567")]   // too short
    [InlineData("+12025550123")]    // not BD
    [InlineData("+8801212345678")]  // invalid operator digit (1[3-9])
    public void Phone_rejects_non_bd_e164(string bad)
        => Assert.Throws<ValidationException>(() => new Phone(bad));

    [Fact]
    public void NidHash_hashes_and_never_exposes_raw()
    {
        var h = NidHash.FromRawNid("1990123456789");
        Assert.Equal(64, h.Value.Length);
        Assert.DoesNotContain("1990123456789", h.Value);
        Assert.Matches("^[0-9a-f]{64}$", h.Value);
    }

    [Fact]
    public void SubmitKyc_sets_nidhash_and_emits_rabbitmq_event()
    {
        var p = NewRegistered(); p.DequeueEvents();
        p.SubmitKyc(NidHash.FromRawNid("1990123456789"), KycTier.BASIC, Now);
        Assert.NotNull(p.NidHash);
        var ev = Assert.Single(p.DequeueEvents());
        var sub = Assert.IsType<KycSubmittedV1>(ev);
        Assert.Equal("rabbitmq", sub.Bus);
        Assert.Equal(RabbitQueues.IDENTITY_KYC_VERIFICATION, sub.Destination);
    }

    [Fact]
    public void ApproveKyc_requires_system_role()
    {
        var p = NewRegistered(); p.DequeueEvents();
        var ex = Assert.Throws<DokandarException>(() => p.ApproveKyc(None, "did:dokandar:sys", Now));
        Assert.Equal(403, ex.HttpStatus);
        Assert.Equal(KycTier.UNVERIFIED, p.KycTier);
    }

    [Fact]
    public void ApproveKyc_transitions_unverified_to_basic()
    {
        var p = NewRegistered(); p.DequeueEvents();
        p.ApproveKyc(System, "did:dokandar:sys", Now);
        Assert.Equal(KycTier.BASIC, p.KycTier);
        var ev = Assert.IsType<KycApprovedV1>(Assert.Single(p.DequeueEvents()));
        Assert.Equal("BASIC", ev.NewTier);
        Assert.Equal("did:dokandar:sys", ev.VerifiedBy);
    }

    [Fact]
    public void ApproveKyc_only_from_unverified()
    {
        var p = NewRegistered(); p.DequeueEvents();
        p.ApproveKyc(System, "sys", Now); p.DequeueEvents();
        Assert.Throws<BusinessException>(() => p.ApproveKyc(System, "sys", Now));
    }

    [Fact]
    public void UpgradeKycTier_is_monotonic_and_targets_full_or_business()
    {
        var p = NewRegistered(); p.DequeueEvents();
        p.ApproveKyc(System, "sys", Now); p.DequeueEvents();               // BASIC
        Assert.Throws<BusinessException>(() => p.UpgradeKycTier(KycTier.BASIC, System, "sys", null, null, Now)); // not >current
        p.UpgradeKycTier(KycTier.FULL, System, "sys", null, null, Now);
        Assert.Equal(KycTier.FULL, p.KycTier);
        var ev = Assert.IsType<KycTierChangedV1>(Assert.Single(p.DequeueEvents()));
        Assert.Equal("BASIC", ev.PreviousTier);
        Assert.Equal("FULL", ev.NewTier);
    }

    [Fact]
    public void UpgradeToBusiness_requires_bin()
    {
        var p = NewRegistered(); p.DequeueEvents();
        p.ApproveKyc(System, "sys", Now); p.DequeueEvents();
        p.UpgradeKycTier(KycTier.FULL, System, "sys", null, null, Now); p.DequeueEvents();
        Assert.Throws<BusinessException>(() => p.UpgradeKycTier(KycTier.BUSINESS, System, "sys", null, null, Now));
        p.UpgradeKycTier(KycTier.BUSINESS, System, "sys", "1234567890", null, Now);
        Assert.Equal(KycTier.BUSINESS, p.KycTier);
        Assert.Equal("1234567890", p.Bin);
    }

    [Fact]
    public void RejectKyc_requires_system_and_reason()
    {
        var p = NewRegistered(); p.DequeueEvents();
        Assert.Throws<DokandarException>(() => p.RejectKyc("bad docs", None, Now));
        p.RejectKyc("bad docs", System, Now);
        Assert.IsType<KycRejectedV1>(Assert.Single(p.DequeueEvents()));
    }

    [Fact]
    public void Suspend_requires_enforcement_then_reactivate()
    {
        var p = NewRegistered(); p.DequeueEvents();
        Assert.Throws<DokandarException>(() => p.Suspend("fraud", System, "gov", Now)); // wrong role
        p.Suspend("fraud", Enforcement, "gov", Now);
        Assert.Equal(PartyStatus.SUSPENDED, p.Status);
        Assert.IsType<PartySuspendedV1>(Assert.Single(p.DequeueEvents()));
        p.Reactivate("gov", Now);
        Assert.Equal(PartyStatus.ACTIVE, p.Status);
        Assert.IsType<PartyReactivatedV1>(Assert.Single(p.DequeueEvents()));
    }

    [Fact]
    public void Reactivate_only_when_suspended()
    {
        var p = NewRegistered(); p.DequeueEvents();
        Assert.Throws<BusinessException>(() => p.Reactivate("gov", Now));
    }

    [Fact]
    public void Device_binding_is_capped_at_max()
    {
        var p = NewRegistered();
        for (var i = 0; i < Party.MaxDevices + 5; i++)
        {
            if (i + 1 < Party.MaxDevices) p.AddDevice($"d{i}");
        }
        // fill to the cap then expect rejection
        while (p.DeviceIds.Count < Party.MaxDevices) p.AddDevice($"x{p.DeviceIds.Count}");
        Assert.Throws<BusinessException>(() => p.AddDevice("one-too-many"));
    }
}
