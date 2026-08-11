// Application ports (hexagonal). Implemented by the adapters ring (Npgsql, system clock, OTP).
using Dkd.Platform;
using IdentitySvc.Domain;

namespace IdentitySvc.Application;

/// <summary>Caller identity + roles resolved from the verified JWT (the PDP integration point).</summary>
public sealed record CallerContext(string? CallerDid, IReadOnlySet<VerifierRole> Roles)
{
    public static readonly CallerContext Anonymous = new(null, new HashSet<VerifierRole>());
}

/// <summary>Monotonic wall clock — Unix epoch milliseconds, UTC (DM timestamp convention).</summary>
public interface IClock { long NowMs { get; } }

/// <summary>OTP verification port. Real SMS/IVR OTP issuance+delivery is Phase 2 (FR-IDN-010+);
/// the MVP adapter validates a dev token so RegisterParty's "OTP verified" precondition is modelled.</summary>
public interface IOtpVerifier
{
    Task<bool> VerifyAsync(string phone, string otpToken, CancellationToken ct = default);
}

/// <summary>One database connection + transaction. Repository reads/writes and outbox enqueue share
/// this single transaction so state change + event are committed atomically (transactional outbox).</summary>
public interface IDbSession
{
    Task<Party?> GetByDidAsync(DID did, CancellationToken ct);
    Task<bool> ExistsByPhoneAsync(string phone, CancellationToken ct);
    Task<bool> NidHashBoundToVerifiedPartyAsync(string nidHash, string exceptDid, CancellationToken ct);
    Task InsertPartyAsync(Party p, CancellationToken ct);
    Task UpdatePartyAsync(Party p, CancellationToken ct);
    Task EnqueueOutboxAsync(IEnumerable<IDomainEvent> events, long nowMs, CancellationToken ct);
}

/// <summary>Runs a unit of work inside a single DB transaction; commits on success, rolls back on error.</summary>
public interface IIdentityUnitOfWork
{
    Task<T> ExecuteAsync<T>(Func<IDbSession, CancellationToken, Task<T>> work, CancellationToken ct);
}
