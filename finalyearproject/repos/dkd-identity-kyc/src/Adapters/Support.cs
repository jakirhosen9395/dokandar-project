// Small adapters: system clock + dev OTP verifier + no-DB fallback unit of work.
using IdentitySvc.Application;

namespace IdentitySvc.Adapters;

/// <summary>Fallback unit of work used only when DKD_DB_DSN is unset (health-only boot / blueprint
/// health tests). Any actual data operation fails fast — party endpoints require a real database.</summary>
public sealed class NullUnitOfWork : IIdentityUnitOfWork
{
    public Task<T> ExecuteAsync<T>(Func<IDbSession, CancellationToken, Task<T>> work, CancellationToken ct) =>
        throw new InvalidOperationException("no database configured (DKD_DB_DSN is empty)");
}

/// <summary>Unix epoch milliseconds, UTC (DM timestamp convention).</summary>
public sealed class SystemClock : IClock
{
    public long NowMs => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
}

/// <summary>Dev OTP verifier. Real OTP issuance/delivery over SMS/IVR is Phase 2 (FR-IDN-010..017);
/// here we validate a fixed dev token (DKD_DEV_OTP, default "000000") so RegisterParty's
/// "OTP verified" precondition is enforced end-to-end without the OTP subsystem.</summary>
public sealed class DevOtpVerifier : IOtpVerifier
{
    private readonly string _devOtp =
        Environment.GetEnvironmentVariable("DKD_DEV_OTP") is { Length: > 0 } v ? v : "000000";

    public Task<bool> VerifyAsync(string phone, string otpToken, CancellationToken ct = default)
        => Task.FromResult(!string.IsNullOrEmpty(otpToken) && otpToken == _devOtp);
}
