// HAND-AUTHORED platform primitive (NOT dkdgen-generated).
// Transactional-outbox half of the effectively-once quartet (outbox + inbox + DLQ + idempotency).
// Canon: EF §21.1 / EF-EVT-6 / SA-CONV-QUARTET (outbox+inbox = effectively-once),
// SA-MSG-09/10 (DLQ + per-aggregate-key park-and-freeze). One of five byte-compatible SDK
// implementations (Go/Java/Node/Python/C#) exposing the SAME contract, so no service hand-rolls
// these helpers (PL-02). Matches the semantics of dkd-custody-ledger/internal/outbox/relay.go.

namespace Dkd.Platform;

/// <summary>
/// Minimal, driver-agnostic DB-execution seam. The service supplies the concrete transaction or
/// connection handle (Npgsql / Dapper / EF Core...) as a thin adapter; the SDK helpers never bind a
/// driver so they stay UNIT-TESTABLE without a live database. Positional <paramref name="args"/> map
/// to <c>$1..$N</c> placeholders in <paramref name="sql"/> (Npgsql/pg style).
/// </summary>
public interface IDbExecutor
{
    /// <summary>Run a non-query statement; returns the number of rows affected.</summary>
    int Execute(string sql, params object?[] args);

    /// <summary>Run a query; returns rows as ordered column-value lists (in SELECT order).</summary>
    IReadOnlyList<IReadOnlyList<object?>> Query(string sql, params object?[] args);
}

/// <summary>One unpublished outbox row drained by the relay loop.</summary>
public sealed record OutboxRecord(
    long Id, string EventId, string Topic, string Key, string Payload, long OccurredAtMs);

/// <summary>
/// Transactional outbox writer. <see cref="Enqueue"/> inserts the event row using the CALLER-PROVIDED
/// transaction handle so the aggregate mutation and the event row commit atomically (SA-CONV-QUARTET).
/// Canonical SDK schema (already used by custody):
/// <code>
/// outbox(id BIGSERIAL PK, event_id TEXT NOT NULL UNIQUE, topic TEXT, key TEXT, payload JSONB,
///        occurred_at_ms BIGINT, created_at TIMESTAMPTZ default now(), published_at TIMESTAMPTZ NULL)
/// -- partial index outbox_unpublished_idx ON (id) WHERE published_at IS NULL
/// </code>
/// </summary>
public static class Outbox
{
    private const string InsertSql =
        "INSERT INTO outbox (event_id, topic, key, payload, occurred_at_ms) " +
        "VALUES ($1,$2,$3,$4::jsonb,$5) ON CONFLICT (event_id) DO NOTHING";

    /// <summary>
    /// Insert one outbox row inside the caller's transaction. Idempotent: a duplicate
    /// <paramref name="eventId"/> is a no-op (<c>ON CONFLICT (event_id) DO NOTHING</c>).
    /// Returns <c>true</c> when a new row was written, <c>false</c> on a duplicate.
    /// </summary>
    public static bool Enqueue(IDbExecutor tx, string eventId, string topic, string key,
        string payload, long occurredAtMs)
    {
        ArgumentNullException.ThrowIfNull(tx);
        Require(eventId, nameof(eventId));
        Require(topic, nameof(topic));
        return tx.Execute(InsertSql, eventId, topic, key, payload, occurredAtMs) == 1;
    }

    internal static void Require(string value, string name)
    {
        if (string.IsNullOrEmpty(value))
        {
            throw new ArgumentException($"outbox: {name} is required", name);
        }
    }
}

/// <summary>
/// Publisher-loop side of the outbox: drains committed rows and marks them published only after the
/// broker acks (at-least-once; consumers dedup via the inbox on <c>event_id</c>). The relay stamps
/// each produced record with <c>event_id</c> + <c>producer_context</c> headers plus a W3C
/// <c>traceparent</c> (stub-safe: passed through when present, never fabricated).
/// </summary>
public static class OutboxRelay
{
    private const int MaxBatch = 500;

    private const string FetchSql =
        "SELECT id, event_id, topic, key, payload::text, occurred_at_ms " +
        "FROM outbox WHERE published_at IS NULL ORDER BY id LIMIT $1";

    /// <summary>Fetch up to <paramref name="limit"/> (1..500) unpublished rows, oldest first.</summary>
    public static IReadOnlyList<OutboxRecord> FetchUnpublished(IDbExecutor db, int limit)
    {
        ArgumentNullException.ThrowIfNull(db);
        var capped = Math.Max(1, Math.Min(limit, MaxBatch));
        var rows = db.Query(FetchSql, capped);
        var result = new List<OutboxRecord>(rows.Count);
        foreach (var r in rows)
        {
            result.Add(new OutboxRecord(
                Convert.ToInt64(r[0]),
                (string)r[1]!,
                (string)r[2]!,
                (string)r[3]!,
                (string)r[4]!,
                Convert.ToInt64(r[5])));
        }

        return result;
    }

    /// <summary>Mark the given outbox ids published (after broker acks). No-op on an empty set.</summary>
    public static void MarkPublished(IDbExecutor db, IReadOnlyList<long> ids)
    {
        ArgumentNullException.ThrowIfNull(db);
        if (ids is null || ids.Count == 0)
        {
            return;
        }

        db.Execute("UPDATE outbox SET published_at = now() WHERE id = ANY($1)", ids.ToArray());
    }

    /// <summary>
    /// Build the wire headers the relay injects on every produced record: <c>event_id</c> +
    /// <c>producer_context</c> (dedup + provenance), plus a W3C <c>traceparent</c> (PL-05). The
    /// caller's traceparent is parsed/validated via <see cref="W3CTrace"/> and injected only when
    /// well-formed — a malformed value is dropped, and no trace is ever fabricated.
    /// </summary>
    public static IReadOnlyDictionary<string, string> Headers(OutboxRecord record,
        string producerContext, string? traceparent = null)
    {
        ArgumentNullException.ThrowIfNull(record);
        var headers = new Dictionary<string, string>
        {
            ["event_id"] = record.EventId,
            ["producer_context"] = producerContext,
        };
        if (W3CTrace.TryParse(traceparent, out var tp))
        {
            W3CTrace.Inject(headers, tp!);
        }

        return headers;
    }
}
