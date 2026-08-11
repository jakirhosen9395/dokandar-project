// Identity application service (CQRS command handlers + party query). Each command loads/creates the
// aggregate, invokes the domain, and persists aggregate state + emitted events in ONE transaction
// (transactional outbox). Cross-aggregate invariants (phone uniqueness, NID->one-verified-party) are
// enforced here against the repository.
using Dkd.Platform;
using IdentitySvc.Domain;

namespace IdentitySvc.Application;

// ---- Commands (DM command table) + query projection ----
public sealed record RegisterPartyCommand(string PhoneNumber, string? DeviceId, string? Locale, string OtpToken);
public sealed record SubmitKycCommand(string Did, string NidNumber, IReadOnlyList<string>? DocumentUrls, string? SelfieUrl, string? TierRequested);
public sealed record ApproveKycCommand(string Did, string VerifierDid, string? Notes);
public sealed record UpgradeKycTierCommand(string Did, string TargetTier, string VerifierDid, string? Notes, string? Bin, string? Tin);
public sealed record RejectKycCommand(string Did, string Reason, string VerifierDid);
public sealed record SuspendPartyCommand(string Did, string Reason, string By);
public sealed record ReactivatePartyCommand(string Did, string By);

public sealed record PartyView(string Did, string KycTier, string Status, string Locale,
                               string PhoneMasked, bool KycSubmitted, string? Bin, int DeviceCount,
                               long CreatedAt, long UpdatedAt);

/// <summary>OHS projection — includes raw phone (PII); returned only over the internal gRPC OHS.</summary>
public sealed record OhsParty(string Did, string KycTier, string Status, string Locale,
                              string Phone, bool KycSubmitted, string? Bin, long CreatedAt, long UpdatedAt);

public sealed class PartyService(IIdentityUnitOfWork uow, IClock clock, IOtpVerifier otp)
{
    private readonly IIdentityUnitOfWork _uow = uow;
    private readonly IClock _clock = clock;
    private readonly IOtpVerifier _otp = otp;

    public async Task<string> RegisterPartyAsync(RegisterPartyCommand cmd, CancellationToken ct)
    {
        var phone = new Phone(cmd.PhoneNumber);                       // validates E.164 +880
        if (!await _otp.VerifyAsync(phone.Value, cmd.OtpToken, ct))
            throw new ValidationException(Code("otp", "invalid"), "OTP verification failed");

        return await _uow.ExecuteAsync(async (db, c) =>
        {
            if (await db.ExistsByPhoneAsync(phone.Value, c))
                throw new BusinessException(Code("party", "phone_taken"), "phone number already registered");
            var party = Party.Register(phone, cmd.DeviceId ?? "", cmd.Locale ?? "bn-BD", _clock.NowMs);
            await db.InsertPartyAsync(party, c);
            await db.EnqueueOutboxAsync(party.DequeueEvents(), _clock.NowMs, c);
            return party.Did.Value;
        }, ct);
    }

    public Task SubmitKycAsync(SubmitKycCommand cmd, CancellationToken ct)
    {
        var did = new DID(cmd.Did);
        var nidHash = NidHash.FromRawNid(cmd.NidNumber);             // raw NID hashed, never stored
        var tierRequested = ParseTier(cmd.TierRequested ?? nameof(KycTier.BASIC));
        return Mutate(did, (party, db, c) =>
        {
            party.SubmitKyc(nidHash, tierRequested, _clock.NowMs);
            return Task.CompletedTask;
        }, ct);
    }

    public Task ApproveKycAsync(ApproveKycCommand cmd, CallerContext caller, CancellationToken ct)
    {
        var did = new DID(cmd.Did);
        return Mutate(did, async (party, db, c) =>
        {
            if (party.NidHash is null)
                throw new BusinessException(Code("kyc", "not_submitted"), "KYC must be submitted before approval");
            if (await db.NidHashBoundToVerifiedPartyAsync(party.NidHash.Value, did.Value, c))
                throw new BusinessException(Code("kyc", "nid_reuse"), "this NID is already bound to a verified party");
            party.ApproveKyc(caller.Roles, cmd.VerifierDid, _clock.NowMs);
        }, ct);
    }

    public Task UpgradeKycTierAsync(UpgradeKycTierCommand cmd, CallerContext caller, CancellationToken ct)
    {
        var did = new DID(cmd.Did);
        var target = ParseTier(cmd.TargetTier);
        return Mutate(did, (party, db, c) =>
        {
            party.UpgradeKycTier(target, caller.Roles, cmd.VerifierDid, cmd.Bin, cmd.Tin, _clock.NowMs);
            return Task.CompletedTask;
        }, ct);
    }

    public Task RejectKycAsync(RejectKycCommand cmd, CallerContext caller, CancellationToken ct)
    {
        var did = new DID(cmd.Did);
        return Mutate(did, (party, db, c) =>
        {
            party.RejectKyc(cmd.Reason, caller.Roles, _clock.NowMs);
            return Task.CompletedTask;
        }, ct);
    }

    public Task SuspendPartyAsync(SuspendPartyCommand cmd, CallerContext caller, CancellationToken ct)
    {
        var did = new DID(cmd.Did);
        return Mutate(did, (party, db, c) =>
        {
            party.Suspend(cmd.Reason, caller.Roles, cmd.By, _clock.NowMs);
            return Task.CompletedTask;
        }, ct);
    }

    public Task ReactivatePartyAsync(ReactivatePartyCommand cmd, CancellationToken ct)
    {
        var did = new DID(cmd.Did);
        return Mutate(did, (party, db, c) =>
        {
            party.Reactivate(cmd.By, _clock.NowMs);
            return Task.CompletedTask;
        }, ct);
    }

    /// <summary>OHS resolution — returns the Party read model INCLUDING PII (phone). Identity is the
    /// only PII resolver (R7); callers are internal contexts over gRPC.</summary>
    public async Task<OhsParty?> ResolveAsync(string didValue, CancellationToken ct)
    {
        var did = new DID(didValue);
        return await _uow.ExecuteAsync(async (db, c) =>
        {
            var p = await db.GetByDidAsync(did, c);
            return p is null ? null : new OhsParty(
                p.Did.Value, p.KycTier.ToString(), p.Status.ToString(), p.Locale,
                p.PhoneNumber.Value, p.NidHash is not null, p.Bin, p.CreatedAt, p.UpdatedAt);
        }, ct);
    }

    public async Task<PartyView?> GetPartyAsync(string didValue, CancellationToken ct)
    {
        var did = new DID(didValue);
        return await _uow.ExecuteAsync(async (db, c) =>
        {
            var p = await db.GetByDidAsync(did, c);
            return p is null ? null : ToView(p);
        }, ct);
    }

    // ID-01: bind a device to a party. Party.AddDevice enforces MAX_DEVICES=10 (business rule);
    // this is its first production call site.
    public Task AddDeviceAsync(string didValue, string deviceId, CancellationToken ct) =>
        Mutate(new DID(didValue), (party, db, c) => { party.AddDevice(deviceId); return Task.CompletedTask; }, ct);

    // Shared load -> mutate -> persist(update) + outbox, in one transaction.
    private Task Mutate(DID did, Func<Party, IDbSession, CancellationToken, Task> mutate, CancellationToken ct) =>
        _uow.ExecuteAsync(async (db, c) =>
        {
            var party = await db.GetByDidAsync(did, c)
                ?? throw new DokandarException(Code("party", "not_found"), "party not found", 404);
            await mutate(party, db, c);
            await db.UpdatePartyAsync(party, c);
            await db.EnqueueOutboxAsync(party.DequeueEvents(), _clock.NowMs, c);
            return true;
        }, ct);

    internal static PartyView ToView(Party p) => new(
        p.Did.Value, p.KycTier.ToString(), p.Status.ToString(), p.Locale,
        Mask(p.PhoneNumber.Value), p.NidHash is not null, p.Bin, p.DeviceIds.Count, p.CreatedAt, p.UpdatedAt);

    private static string Mask(string phone) =>
        phone.Length <= 5 ? "***" : phone[..5] + new string('*', phone.Length - 7) + phone[^2..];

    private static KycTier ParseTier(string s) =>
        Enum.TryParse<KycTier>(s, ignoreCase: true, out var t)
            ? t : throw new ValidationException(Code("validation", "tier_invalid"), $"unknown KYC tier: {s}");

    private static string Code(string category, string reason) =>
        Errors.ErrorCode(ContextSlug.Identity, category, reason);
}
