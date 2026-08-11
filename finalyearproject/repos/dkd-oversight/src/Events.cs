// The three government.oversight.* directives (frozen registry, producer 11). These are the
// ONLY way Government touches operational state (R5/BR-038 — Kafka, never direct DB writes).
// Payloads per DM §#11, IDs only, never PII.
using System.Text.Json;
using Dkd.Platform;
using Npgsql;

namespace OversightSvc;

public static class Events
{
    private const int GovernmentContext = 11;

    public static Task<string> RecallDirectiveIssued(NpgsqlConnection cx, NpgsqlTransaction tx,
        string recallId, IReadOnlyList<string> gpids, string reason, string authority,
        string issuedBy, long now) =>
        Emit(cx, tx, KafkaTopics.GOVERNMENT_OVERSIGHT_RECALL_DIRECTIVE_ISSUED_V1, recallId, new()
        {
            ["recallId"] = recallId, ["gpids"] = gpids, ["reason"] = reason,
            ["authority"] = authority, ["issuedBy"] = issuedBy, ["issuedAt"] = now,
        }, now);

    public static Task<string> TradeFreezeDirective(NpgsqlConnection cx, NpgsqlTransaction tx,
        string directiveId, string trd, string reason, string authority, string issuedBy,
        long now) =>
        Emit(cx, tx, KafkaTopics.GOVERNMENT_OVERSIGHT_TRADE_FREEZE_DIRECTIVE_V1, directiveId, new()
        {
            ["directiveId"] = directiveId, ["trd"] = trd, ["reason"] = reason,
            ["authority"] = authority, ["issuedBy"] = issuedBy, ["issuedAt"] = now,
        }, now);

    /// <summary>M-NEW-1: the payload carries ownerDid — Government never learns the WLT.</summary>
    public static Task<string> WalletFreezeDirective(NpgsqlConnection cx, NpgsqlTransaction tx,
        string directiveId, string ownerDid, string reason, string authority, string issuedBy,
        long now) =>
        Emit(cx, tx, KafkaTopics.GOVERNMENT_OVERSIGHT_WALLET_FREEZE_DIRECTIVE_V1, directiveId, new()
        {
            ["directiveId"] = directiveId, ["ownerDid"] = ownerDid, ["reason"] = reason,
            ["authority"] = authority, ["issuedBy"] = issuedBy, ["issuedAt"] = now,
        }, now);

    private static async Task<string> Emit(NpgsqlConnection cx, NpgsqlTransaction tx, string topic,
        string key, Dictionary<string, object?> fields, long now)
    {
        var meta = Topics.Meta[topic];
        if (meta.Producer != GovernmentContext)
            throw new DomainException(500, "dokandar.government.internal.r6_violation",
                $"government may not produce {topic}");
        var eventId = Domain.NewEventId();
        var payload = new Dictionary<string, object?> { ["eventId"] = eventId, ["occurredAt"] = now };
        foreach (var (k, v) in fields) payload[k] = v;
        await Stores.OutboxInsert(cx, tx, eventId, topic, key, JsonSerializer.Serialize(payload), now);
        return eventId;
    }
}
