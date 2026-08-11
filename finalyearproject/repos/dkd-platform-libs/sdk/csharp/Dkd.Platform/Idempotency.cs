// HAND-AUTHORED platform primitive (NOT dkdgen-generated).
// PL-03: Idempotency-Key enforcement for unsafe / money / custody writes (EF-API-6). The helper is
// driver-agnostic: it reaches persistence through IIdempotencyStore, which a service backs with the
// PL-02 inbox table or a dedicated idem table — the SDK never hard-wires a DB. Three canon branches:
//   * MISSING key on an unsafe write            -> 400 (reject)
//   * SAME key + SAME request payload (replay)  -> return the ORIGINAL stored response
//   * SAME key + DIFFERENT request payload       -> 409 (key reuse mismatch)

namespace Dkd.Platform;

using System.Security.Cryptography;
using System.Text;

/// <summary>The captured HTTP response the platform replays for a repeated idempotency key.</summary>
public sealed record IdempotentResponse(int Status, string Body, string ContentType = "application/json");

/// <summary>One persisted idempotency row: the key, a fingerprint of the original request, its response.</summary>
public sealed record IdempotencyRecord(string Key, string RequestFingerprint, IdempotentResponse Response);

/// <summary>
/// Pluggable idempotency store. Back it with the PL-02 inbox (<see cref="Inbox"/>) or a dedicated
/// <c>idempotency</c> table — the SDK stays DB-agnostic. Implementations MUST persist and look up by
/// the exact <c>Idempotency-Key</c> string.
/// </summary>
public interface IIdempotencyStore
{
    /// <summary>Return the stored record for <paramref name="key"/>, or null when the key is unseen.</summary>
    IdempotencyRecord? Find(string key);

    /// <summary>Persist the first-seen record (key + request fingerprint + captured response).</summary>
    void Save(IdempotencyRecord record);
}

/// <summary>What the caller must do next after evaluating an idempotency key.</summary>
public enum IdempotencyOutcome
{
    /// <summary>No key supplied on an unsafe write — reject with 400.</summary>
    MissingKey,

    /// <summary>Key + payload match a prior request — return <see cref="IdempotencyDecision.Response"/> verbatim.</summary>
    Replay,

    /// <summary>Key reused with a different payload — reject with 409.</summary>
    Conflict,

    /// <summary>First use of this key — run the handler, then call <see cref="Idempotency.Remember"/>.</summary>
    Proceed,
}

/// <summary>The evaluation result. <see cref="HttpStatus"/> is 0 for <see cref="IdempotencyOutcome.Proceed"/>.</summary>
public sealed record IdempotencyDecision(
    IdempotencyOutcome Outcome, int HttpStatus, string? Code, IdempotentResponse? Response);

/// <summary>
/// Stateless idempotency policy. Wrap the three unsafe-write branches of EF-API-6 around a
/// pluggable <see cref="IIdempotencyStore"/>. Typical use:
/// <code>
/// var d = Idempotency.Evaluate(store, req.Header("Idempotency-Key"), rawBody);
/// switch (d.Outcome) {
///   case IdempotencyOutcome.MissingKey: return Problem(400, d.Code);
///   case IdempotencyOutcome.Conflict:   return Problem(409, d.Code);
///   case IdempotencyOutcome.Replay:     return Replay(d.Response!);
///   case IdempotencyOutcome.Proceed:
///     var resp = Handle();
///     Idempotency.Remember(store, key, rawBody, resp);
///     return resp;
/// }
/// </code>
/// </summary>
public static class Idempotency
{
    public const string HeaderName = "Idempotency-Key";
    public const string MissingKeyCode = "dokandar.platform.idempotency.missing_key";
    public const string MismatchCode = "dokandar.platform.idempotency.key_reuse_mismatch";

    /// <summary>SHA-256 (lowercase hex) fingerprint of the raw request payload — the "same payload" key.</summary>
    public static string Fingerprint(string? requestPayload) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(requestPayload ?? string.Empty)))
               .ToLowerInvariant();

    /// <summary>Classify an unsafe write against the store per EF-API-6 (does not mutate the store).</summary>
    public static IdempotencyDecision Evaluate(IIdempotencyStore store, string? idempotencyKey, string? requestPayload)
    {
        ArgumentNullException.ThrowIfNull(store);

        if (string.IsNullOrWhiteSpace(idempotencyKey))
            return new IdempotencyDecision(IdempotencyOutcome.MissingKey, 400, MissingKeyCode, null);

        var existing = store.Find(idempotencyKey);
        if (existing is null)
            return new IdempotencyDecision(IdempotencyOutcome.Proceed, 0, null, null);

        if (existing.RequestFingerprint == Fingerprint(requestPayload))
            return new IdempotencyDecision(IdempotencyOutcome.Replay, existing.Response.Status, null, existing.Response);

        return new IdempotencyDecision(IdempotencyOutcome.Conflict, 409, MismatchCode, null);
    }

    /// <summary>Persist the first-seen key + payload fingerprint + response, so later replays return it.</summary>
    public static void Remember(IIdempotencyStore store, string idempotencyKey, string? requestPayload,
        IdempotentResponse response)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(response);
        Outbox.Require(idempotencyKey, nameof(idempotencyKey));
        store.Save(new IdempotencyRecord(idempotencyKey, Fingerprint(requestPayload), response));
    }
}
