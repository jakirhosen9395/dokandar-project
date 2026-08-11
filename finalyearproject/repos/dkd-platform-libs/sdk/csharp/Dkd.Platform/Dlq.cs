// HAND-AUTHORED platform primitive (NOT dkdgen-generated).
// Dead-letter / park-and-freeze half of the messaging quartet (SA-MSG-09/10). A poison
// money/custody/inventory event is PARKED under its own aggregate key — that single key freezes
// (later events on it must not progress) while every other key keeps flowing. Poison messages are
// NEVER silently dropped; they are replayable from the dlq table.

namespace Dkd.Platform;

/// <summary>A poison event parked for later replay, tagged with the aggregate key it froze.</summary>
public sealed record DlqEntry(
    string EventId, string Topic, string Key, string Payload, string Error, string AggregateKey);

/// <summary>
/// Dead-letter store with per-aggregate-key park-and-freeze. Canonical SDK schema:
/// <code>dlq(id, event_id, topic, key, payload, error, parked_at, aggregate_key)</code>
/// </summary>
public static class Dlq
{
    private const string InsertSql =
        "INSERT INTO dlq (event_id, topic, key, payload, error, aggregate_key, parked_at) " +
        "VALUES ($1,$2,$3,$4::jsonb,$5,$6,now())";

    /// <summary>Park a poison event, freezing only its <see cref="DlqEntry.AggregateKey"/>.</summary>
    public static void Park(IDbExecutor db, DlqEntry entry)
    {
        ArgumentNullException.ThrowIfNull(db);
        ArgumentNullException.ThrowIfNull(entry);
        Outbox.Require(entry.EventId, nameof(entry.EventId));
        Outbox.Require(entry.AggregateKey, nameof(entry.AggregateKey));
        db.Execute(InsertSql, entry.EventId, entry.Topic, entry.Key, entry.Payload,
            entry.Error, entry.AggregateKey);
    }

    /// <summary>
    /// True when <paramref name="aggregateKey"/> is frozen (has at least one parked event). Callers
    /// consult this before processing the next event on a key so a frozen key does not progress.
    /// </summary>
    public static bool IsKeyParked(IDbExecutor db, string aggregateKey)
    {
        ArgumentNullException.ThrowIfNull(db);
        Outbox.Require(aggregateKey, nameof(aggregateKey));
        var rows = db.Query("SELECT 1 FROM dlq WHERE aggregate_key = $1 LIMIT 1", aggregateKey);
        return rows.Count > 0;
    }
}
