// HAND-AUTHORED platform primitive (NOT dkdgen-generated).
// Consumer-inbox half of the effectively-once quartet (SA-CONV-QUARTET / EF-EVT-6). Dedup on
// (consumer, event_id) INSIDE the same transaction as the side effect, so a redelivered event is
// processed at-most-once per consumer. Matches dkd-finance InboxStore / dkd-b2c-order InboxStore.

namespace Dkd.Platform;

/// <summary>
/// Consumer inbox: idempotent-consumer dedup keyed by (consumer, event_id). Canonical SDK schema:
/// <code>inbox(consumer TEXT, event_id TEXT, processed_at TIMESTAMPTZ, PRIMARY KEY(consumer, event_id))</code>
/// Both calls MUST run on the SAME transaction handle as the side effect they guard.
/// </summary>
public static class Inbox
{
    /// <summary>True when this (<paramref name="consumer"/>, <paramref name="eventId"/>) pair has
    /// already been processed — the caller should then skip the side effect.</summary>
    public static bool AlreadyProcessed(IDbExecutor tx, string consumer, string eventId)
    {
        ArgumentNullException.ThrowIfNull(tx);
        Outbox.Require(consumer, nameof(consumer));
        Outbox.Require(eventId, nameof(eventId));
        var rows = tx.Query(
            "SELECT 1 FROM inbox WHERE consumer = $1 AND event_id = $2", consumer, eventId);
        return rows.Count > 0;
    }

    /// <summary>
    /// Record this (<paramref name="consumer"/>, <paramref name="eventId"/>) as processed, in the same
    /// tx as the side effect. Idempotent (<c>ON CONFLICT (consumer, event_id) DO NOTHING</c>); returns
    /// <c>true</c> when a new row was written, <c>false</c> when it was already present.
    /// </summary>
    public static bool MarkProcessed(IDbExecutor tx, string consumer, string eventId)
    {
        ArgumentNullException.ThrowIfNull(tx);
        Outbox.Require(consumer, nameof(consumer));
        Outbox.Require(eventId, nameof(eventId));
        return tx.Execute(
            "INSERT INTO inbox (consumer, event_id, processed_at) VALUES ($1,$2,now()) " +
            "ON CONFLICT (consumer, event_id) DO NOTHING", consumer, eventId) == 1;
    }
}
