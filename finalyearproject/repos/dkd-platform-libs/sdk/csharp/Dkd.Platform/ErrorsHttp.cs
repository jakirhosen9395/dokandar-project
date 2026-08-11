// HAND-AUTHORED platform primitive (NOT dkdgen-generated).
// PL-06: full error -> HTTP status vocabulary (EF-API-3), extending the coarse 400/409/503 typed
// exceptions in the generated Errors.cs. Splits 400 malformed vs 422 business-validation, adds
// 403 (authz / four-eyes), 409 (state / idempotency mismatch), 423 (Locked = park/fence),
// 429 (rate-limit, + Retry-After), 202 (async escrow/payout accepted), 503 (unavailable).

namespace Dkd.Platform;

/// <summary>Canonical error categories and their HTTP status per EF-API-3.</summary>
public enum ErrorCategory
{
    /// <summary>400 — syntactically malformed / unparseable request.</summary>
    Malformed,

    /// <summary>422 — well-formed but fails a business/domain rule.</summary>
    BusinessValidation,

    /// <summary>403 — authenticated but not authorized (RBAC/ABAC deny).</summary>
    Authz,

    /// <summary>403 — a four-eyes second-approver is required or the two approvers are the same.</summary>
    FourEyes,

    /// <summary>409 — aggregate is in a state that forbids the transition.</summary>
    StateConflict,

    /// <summary>409 — Idempotency-Key reused with a different payload.</summary>
    IdempotencyMismatch,

    /// <summary>423 — resource parked/fenced (poison-message quarantine, custody/finance fence).</summary>
    Locked,

    /// <summary>429 — rate-limited; carries a Retry-After hint.</summary>
    RateLimit,

    /// <summary>202 — accepted for async processing (escrow move / payout settlement in flight).</summary>
    AsyncAccepted,

    /// <summary>503 — a dependency (broker/datastore/downstream) is unavailable.</summary>
    Unavailable,
}

/// <summary>Maps <see cref="ErrorCategory"/> to its canonical HTTP status code.</summary>
public static class HttpStatusMap
{
    public static int StatusFor(ErrorCategory category) => category switch
    {
        ErrorCategory.Malformed => 400,
        ErrorCategory.BusinessValidation => 422,
        ErrorCategory.Authz => 403,
        ErrorCategory.FourEyes => 403,
        ErrorCategory.StateConflict => 409,
        ErrorCategory.IdempotencyMismatch => 409,
        ErrorCategory.Locked => 423,
        ErrorCategory.RateLimit => 429,
        ErrorCategory.AsyncAccepted => 202,
        ErrorCategory.Unavailable => 503,
        _ => throw new ArgumentOutOfRangeException(nameof(category), category, "unknown error category"),
    };
}

// Typed exceptions for the categories the coarse Errors.cs set does not cover. Each carries the
// dokandar.<context>.<category>.<reason> code and its canonical status.
public sealed class MalformedRequestException : DokandarException
{ public MalformedRequestException(string code, string message) : base(code, message, 400) { } }

public sealed class BusinessValidationException : DokandarException
{ public BusinessValidationException(string code, string message) : base(code, message, 422) { } }

public sealed class AuthorizationException : DokandarException
{ public AuthorizationException(string code, string message) : base(code, message, 403) { } }

public sealed class FourEyesRequiredException : DokandarException
{ public FourEyesRequiredException(string code, string message) : base(code, message, 403) { } }

public sealed class StateConflictException : DokandarException
{ public StateConflictException(string code, string message) : base(code, message, 409) { } }

public sealed class IdempotencyMismatchException : DokandarException
{ public IdempotencyMismatchException(string code, string message) : base(code, message, 409) { } }

public sealed class LockedException : DokandarException
{ public LockedException(string code, string message) : base(code, message, 423) { } }

/// <summary>429 rate-limit error carrying the Retry-After hint (seconds) the handler should echo.</summary>
public sealed class RateLimitException : DokandarException
{
    public int RetryAfterSeconds { get; }
    public RateLimitException(string code, string message, int retryAfterSeconds)
        : base(code, message, 429) => RetryAfterSeconds = retryAfterSeconds;
}
