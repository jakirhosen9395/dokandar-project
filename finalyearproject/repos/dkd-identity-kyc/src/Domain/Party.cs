// Party aggregate root (Context #1). Root ID = DID (immutable). Encodes the DM command table,
// state machine, and invariants. Emits the frozen identity.party.* events. No PII in events (C1).
using Dkd.Platform;

namespace IdentitySvc.Domain;

public sealed class Party
{
    public const int MaxDevices = 10;   // DM: deviceIds MAX_DEVICES = 10
    public const int BinMaxLen = 15;    // DM: bin <= 15 chars, required for BUSINESS
    public const int TinMaxLen = 12;    // DM: tin <= 12 chars, optional

    public DID Did { get; }
    public Phone PhoneNumber { get; private set; }
    public NidHash? NidHash { get; private set; }
    public KycTier KycTier { get; private set; }
    public string? Bin { get; private set; }
    public string? Tin { get; private set; }
    public string Locale { get; private set; }
    public IReadOnlyList<string> DeviceIds => _deviceIds;
    public PartyStatus Status { get; private set; }
    public long CreatedAt { get; private set; }
    public long UpdatedAt { get; private set; }

    private readonly List<string> _deviceIds = new();
    private readonly List<IDomainEvent> _events = new();

    private Party(DID did, Phone phone, string locale, long nowMs)
    {
        Did = did; PhoneNumber = phone; Locale = locale;
        KycTier = KycTier.UNVERIFIED; Status = PartyStatus.ACTIVE;
        CreatedAt = nowMs; UpdatedAt = nowMs;
    }

    /// <summary>Drain and return uncommitted domain events (called by the application service).</summary>
    public IReadOnlyList<IDomainEvent> DequeueEvents()
    {
        var copy = _events.ToArray();
        _events.Clear();
        return copy;
    }

    // ---- RegisterParty (OTP verified + phone-uniqueness enforced by the application service) ----
    public static Party Register(Phone phone, string deviceId, string locale, long nowMs)
    {
        var did = new DID(DID.Prefix + Guid.CreateVersion7().ToString());   // did:dokandar:{uuid7}
        var p = new Party(did, phone, string.IsNullOrWhiteSpace(locale) ? "bn-BD" : locale, nowMs);
        if (!string.IsNullOrWhiteSpace(deviceId)) p._deviceIds.Add(deviceId);
        p.Raise(new PartyRegisteredV1(did.Value, nameof(KycTier.UNVERIFIED), p.Locale, nowMs));
        return p;
    }

    // ---- SubmitKYC (RabbitMQ intra-context) — pre: Party UNVERIFIED or BASIC ----
    public void SubmitKyc(NidHash nidHash, KycTier tierRequested, long nowMs)
    {
        RequireActive();
        if (KycTier is not (KycTier.UNVERIFIED or KycTier.BASIC))
            throw Business("kyc", "invalid_state", "SubmitKYC requires the party to be UNVERIFIED or BASIC");
        NidHash = nidHash;
        Touch(nowMs);
        Raise(new KycSubmittedV1(Did.Value, nowMs, tierRequested.ToString()));
    }

    // ---- ApproveKYC — pre: Party UNVERIFIED; verifier SYSTEM role; -> BASIC ----
    public void ApproveKyc(IReadOnlySet<VerifierRole> callerRoles, string verifierDid, long nowMs)
    {
        RequireRole(callerRoles, VerifierRole.SYSTEM);
        if (KycTier != KycTier.UNVERIFIED)
            throw Business("kyc", "invalid_state", "ApproveKYC requires the party to be UNVERIFIED");
        RequireActive();
        KycTier = KycTier.BASIC;
        Touch(nowMs);
        Raise(new KycApprovedV1(Did.Value, nameof(KycTier.BASIC), nowMs, verifierDid));
    }

    // ---- UpgradeKYCTier — pre: ACTIVE; target in {FULL,BUSINESS}; target>current; SYSTEM role ----
    public void UpgradeKycTier(KycTier target, IReadOnlySet<VerifierRole> callerRoles, string verifierDid,
                               string? bin, string? tin, long nowMs)
    {
        RequireRole(callerRoles, VerifierRole.SYSTEM);
        RequireActive();
        if (target is not (KycTier.FULL or KycTier.BUSINESS))
            throw Business("kyc", "invalid_target_tier", "targetTier must be FULL or BUSINESS");
        if (target <= KycTier)
            throw Business("kyc", "non_monotonic_tier", "targetTier must be greater than the current tier");
        if (target == KycTier.BUSINESS)
        {
            var effectiveBin = bin ?? Bin;
            if (string.IsNullOrWhiteSpace(effectiveBin))
                throw Business("kyc", "bin_required", "BUSINESS tier requires a BIN");
            SetBusinessIds(effectiveBin, tin ?? Tin);
        }
        var previous = KycTier;
        KycTier = target;
        Touch(nowMs);
        Raise(new KycTierChangedV1(Did.Value, previous.ToString(), target.ToString(), nowMs, verifierDid));
    }

    // ---- RejectKYC — pre: verifier SYSTEM role ----
    public void RejectKyc(string reason, IReadOnlySet<VerifierRole> callerRoles, long nowMs)
    {
        RequireRole(callerRoles, VerifierRole.SYSTEM);
        if (string.IsNullOrWhiteSpace(reason))
            throw Validation("reason_required", "rejection reason is required");
        Touch(nowMs);
        Raise(new KycRejectedV1(Did.Value, reason, nowMs));
    }

    // ---- SuspendParty — pre: caller ENFORCEMENT role ----
    public void Suspend(string reason, IReadOnlySet<VerifierRole> callerRoles, string byDid, long nowMs)
    {
        RequireRole(callerRoles, VerifierRole.ENFORCEMENT);
        if (Status != PartyStatus.ACTIVE)
            throw Business("party", "not_active", "only an ACTIVE party can be suspended");
        Status = PartyStatus.SUSPENDED;
        Touch(nowMs);
        Raise(new PartySuspendedV1(Did.Value, reason, nowMs, byDid));
    }

    // ---- ReactivateParty — pre: Party SUSPENDED ----
    public void Reactivate(string byDid, long nowMs)
    {
        if (Status != PartyStatus.SUSPENDED)
            throw Business("party", "not_suspended", "only a SUSPENDED party can be reactivated");
        Status = PartyStatus.ACTIVE;
        Touch(nowMs);
        Raise(new PartyReactivatedV1(Did.Value, nowMs, byDid));
    }

    public void AddDevice(string deviceId)
    {
        if (string.IsNullOrWhiteSpace(deviceId)) return;
        if (_deviceIds.Contains(deviceId)) return;
        if (_deviceIds.Count >= MaxDevices)
            throw Business("party", "device_limit", $"a party may bind at most {MaxDevices} devices");
        _deviceIds.Add(deviceId);
    }

    private void SetBusinessIds(string bin, string? tin)
    {
        if (bin.Length > BinMaxLen) throw Validation("bin_invalid", $"BIN must be <= {BinMaxLen} chars");
        if (tin is { Length: > TinMaxLen }) throw Validation("tin_invalid", $"TIN must be <= {TinMaxLen} chars");
        Bin = bin; Tin = tin;
    }

    private void RequireActive()
    {
        if (Status != PartyStatus.ACTIVE)
            throw Business("party", "not_active", "the party is not ACTIVE");
    }

    private static void RequireRole(IReadOnlySet<VerifierRole> roles, VerifierRole required)
    {
        if (roles is null || !roles.Contains(required))
            throw new DokandarException(
                Errors.ErrorCode(ContextSlug.Identity, "authz", "role_required"),
                $"caller must hold the {required} role", 403);
    }

    private void Touch(long nowMs) => UpdatedAt = nowMs;
    private void Raise(IDomainEvent e) => _events.Add(e);

    private static BusinessException Business(string category, string reason, string msg) =>
        new(Errors.ErrorCode(ContextSlug.Identity, category, reason), msg);
    private static ValidationException Validation(string reason, string msg) =>
        new(Errors.ErrorCode(ContextSlug.Identity, "validation", reason), msg);

    /// <summary>Rehydrate an aggregate from persisted state (no events raised).</summary>
    public static Party Rehydrate(DID did, Phone phone, NidHash? nidHash, KycTier tier, string? bin, string? tin,
                                  string locale, IEnumerable<string> deviceIds, PartyStatus status,
                                  long createdAt, long updatedAt)
    {
        var p = new Party(did, phone, locale, createdAt)
        { NidHash = nidHash, KycTier = tier, Bin = bin, Tin = tin, Status = status, UpdatedAt = updatedAt };
        p._deviceIds.AddRange(deviceIds ?? Array.Empty<string>());
        return p;
    }
}
