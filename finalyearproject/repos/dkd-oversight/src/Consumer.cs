// gov-projection-workers: the 20 registry topics with consumer=11 materialize the four DM
// read models. Inbox dedup + projection write happen in ONE transaction; business-final
// payload gaps are ack+skip (logged); infra errors leave the offset uncommitted (replay).
using System.Text;
using System.Text.Json;
using Confluent.Kafka;
using Dkd.Platform;
using Npgsql;

namespace OversightSvc;

public sealed class ProjectionWorker(NpgsqlDataSource ds, Config cfg, ILogger<ProjectionWorker> log)
    : BackgroundService
{
    private static readonly string[] ConsumedTopics =
    [
        KafkaTopics.IDENTITY_PARTY_KYCAPPROVED_V1,
        KafkaTopics.IDENTITY_PARTY_KYCTIER_CHANGED_V1,
        KafkaTopics.IDENTITY_PARTY_PARTY_SUSPENDED_V1,
        KafkaTopics.CUSTODY_PASSPORT_CUSTODY_INITIALIZED_V1,
        KafkaTopics.CUSTODY_PASSPORT_CUSTODY_TRANSFERRED_V1,
        KafkaTopics.CUSTODY_PASSPORT_PRODUCT_RECALLED_V1,
        KafkaTopics.B2C_ORDER_ORDER_PLACED_V1,
        KafkaTopics.B2B_TRADEORDER_TRADE_ORDER_CREATED_V1,
        KafkaTopics.B2B_TRADEORDER_TRADE_SETTLED_V1,
        KafkaTopics.B2B_TRADEORDER_TRADE_DISPUTED_V1,
        KafkaTopics.FINANCE_WALLET_WALLET_CREDITED_V1,
        KafkaTopics.FINANCE_WALLET_WALLET_DEBITED_V1,
        KafkaTopics.FINANCE_WALLET_WALLET_FROZEN_V1,
        KafkaTopics.FINANCE_ESCROW_ESCROW_RELEASED_V1,
        KafkaTopics.FINANCE_ESCROW_SETTLEMENT_HOLD_RELEASED_V1,
        KafkaTopics.FINANCE_ESCROW_ESCROW_REVERSED_V1,
        KafkaTopics.FRAUD_ENFORCEMENT_FRAUD_SIGNAL_RAISED_V1,
        KafkaTopics.FRAUD_ENFORCEMENT_ACCOUNT_HELD_V1,
        KafkaTopics.FRAUD_ENFORCEMENT_ACCOUNT_HOLD_RELEASED_V1,
    ];

    // ct in Task.Run guards start only; the loop cancels cooperatively via ct checks.
    protected override Task ExecuteAsync(CancellationToken ct) => Task.Run(async () =>
    {
        using var consumer = new ConsumerBuilder<string, string>(new ConsumerConfig
        {
            BootstrapServers = cfg.KafkaBrokers,
            GroupId = "oversight-svc",
            EnableAutoCommit = false,
            AutoOffsetReset = AutoOffsetReset.Earliest,
            AllowAutoCreateTopics = false,
        }).Build();
        consumer.Subscribe(ConsumedTopics);
        log.LogInformation("projection worker consuming {n} topics", ConsumedTopics.Length);
        while (!ct.IsCancellationRequested)
        {
            ConsumeResult<string, string>? cr = null;
            try
            {
                cr = consumer.Consume(TimeSpan.FromSeconds(1));
                if (cr is null) continue;
                await Handle(cr, ct);
                consumer.Commit(cr);
            }
            catch (OperationCanceledException) { break; }
            catch (Exception e)
            {
                // GOV-09: the offset was never committed, but Consume() already advanced the in-memory
                // position — so without a rewind the failed record is silently SKIPPED in-process (read
                // model drifts). Seek back to it so it re-delivers on the next Consume (no silent drop).
                log.LogError(e, "projection handler failed — rewinding to replay the record (GOV-09)");
                if (cr is not null)
                {
                    try { consumer.Seek(cr.TopicPartitionOffset); }
                    catch (Exception se) { log.LogError(se, "seek-to-replay failed"); }
                }
                await Task.Delay(2000, ct);
            }
        }
        consumer.Close();
    }, ct);

    private async Task Handle(ConsumeResult<string, string> cr, CancellationToken ct)
    {
        using var doc = Parse(cr.Message.Value);
        var p = doc.RootElement;
        var eventId = EventId(cr, p);
        var asOf = Long(p, "occurredAt") ?? Domain.NowMs();
        await using var cx = await ds.OpenConnectionAsync(ct);
        await using var tx = await cx.BeginTransactionAsync(ct);
        if (!await Stores.InboxTryMark(cx, tx, eventId, cr.Topic, Domain.NowMs()))
        {
            await tx.CommitAsync(ct);
            return; // duplicate
        }
        await Project(cr.Topic, p, cx, tx, asOf);
        await tx.CommitAsync(ct);
    }

    private async Task Project(string topic, JsonElement p, NpgsqlConnection cx,
        NpgsqlTransaction tx, long asOf)
    {
        switch (topic)
        {
            case KafkaTopics.IDENTITY_PARTY_KYCAPPROVED_V1:
            case KafkaTopics.IDENTITY_PARTY_KYCTIER_CHANGED_V1:
            {
                var did = Str(p, "did", "Did", "partyDid");
                var tier = Str(p, "newTier", "NewTier", "tier", "Tier");
                if (did is null) { Skip(topic, "no did"); return; }
                await Stores.UpsertCompliance(cx, tx, did, tier, null, null, null, asOf);
                break;
            }
            case KafkaTopics.IDENTITY_PARTY_PARTY_SUSPENDED_V1:
            {
                var did = Str(p, "did", "Did", "partyDid");
                if (did is null) { Skip(topic, "no did"); return; }
                await Stores.UpsertCompliance(cx, tx, did, null, "SUSPENDED",
                    $"SUSPENDED@{asOf}", null, asOf);
                break;
            }
            case KafkaTopics.CUSTODY_PASSPORT_CUSTODY_INITIALIZED_V1:
            {
                var gpid = Str(p, "gpid", "GPID");
                var qty = Long(p, "quantity") ?? 0;
                if (gpid is null || qty <= 0) { Skip(topic, "no gpid/quantity"); return; }
                await Stores.BumpInventory(cx, tx, gpid, qty, Str(p, "unit") ?? "unit", asOf);
                break;
            }
            case KafkaTopics.CUSTODY_PASSPORT_CUSTODY_TRANSFERRED_V1:
                // National totals are custody-neutral on transfer (holder changes, stock does not).
                break;
            case KafkaTopics.CUSTODY_PASSPORT_PRODUCT_RECALLED_V1:
            {
                var gpid = Str(p, "gpid", "GPID");
                var qty = Long(p, "quantity");
                if (gpid is not null && qty is > 0)
                    await Stores.BumpInventory(cx, tx, gpid, -qty.Value, Str(p, "unit") ?? "unit", asOf);
                break;
            }
            case KafkaTopics.B2C_ORDER_ORDER_PLACED_V1:
                // ORD-level flow is Analytics' concern; the national TRADE view tracks B2B.
                break;
            case KafkaTopics.B2B_TRADEORDER_TRADE_ORDER_CREATED_V1:
            {
                var trd = Str(p, "trd");
                if (trd is null) { Skip(topic, "no trd"); return; }
                await Stores.UpsertTrade(cx, tx, trd, Str(p, "sellerDid"), Str(p, "buyerDid"),
                    Long(p, "totalAmountPoisha") ?? 0, "MARGIN_PENDING", asOf, asOf);
                break;
            }
            case KafkaTopics.B2B_TRADEORDER_TRADE_SETTLED_V1:
            {
                var trd = Str(p, "trd");
                if (trd is null) { Skip(topic, "no trd"); return; }
                await Stores.UpsertTrade(cx, tx, trd, null, null, 0, "SETTLED", asOf, asOf);
                break;
            }
            case KafkaTopics.B2B_TRADEORDER_TRADE_DISPUTED_V1:
            {
                var trd = Str(p, "trd");
                if (trd is null) { Skip(topic, "no trd"); return; }
                await Stores.UpsertTrade(cx, tx, trd, null, null, 0, "DISPUTED", asOf, asOf);
                break;
            }
            case KafkaTopics.FINANCE_ESCROW_ESCROW_RELEASED_V1:
            case KafkaTopics.FINANCE_ESCROW_SETTLEMENT_HOLD_RELEASED_V1:
            case KafkaTopics.FINANCE_ESCROW_ESCROW_REVERSED_V1:
            {
                var esc = Str(p, "esc", "escrowId");
                if (esc is null) { Skip(topic, "no esc"); return; }
                var status = topic switch
                {
                    KafkaTopics.FINANCE_ESCROW_ESCROW_RELEASED_V1 => "SETTLEMENT_HELD",
                    KafkaTopics.FINANCE_ESCROW_SETTLEMENT_HOLD_RELEASED_V1 => "RELEASED",
                    _ => "REVERSED",
                };
                await Stores.UpsertEscrow(cx, tx, esc, Long(p, "amountPoisha") ?? 0, status,
                    Str(p, "referenceId") ?? "", asOf);
                break;
            }
            case KafkaTopics.FINANCE_WALLET_WALLET_FROZEN_V1:
                // WLT-keyed; the DID owner is not in the payload (no PII/linkage) — audit sink
                // already mirrors it. Compliance view freezes arrive via fraud AccountHeld.
                break;
            case KafkaTopics.FINANCE_WALLET_WALLET_CREDITED_V1:
            case KafkaTopics.FINANCE_WALLET_WALLET_DEBITED_V1:
                break; // volumes belong to Analytics; oversight keeps escrow-level money views
            case KafkaTopics.FRAUD_ENFORCEMENT_FRAUD_SIGNAL_RAISED_V1:
            {
                var did = Str(p, "subjectDid", "did");
                if (did is null) { Skip(topic, "no subjectDid"); return; }
                await Stores.UpsertCompliance(cx, tx, did, null, null, null,
                    $"SIGNAL:{Str(p, "reason") ?? "?"}@{asOf}", asOf);
                break;
            }
            case KafkaTopics.FRAUD_ENFORCEMENT_ACCOUNT_HELD_V1:
            {
                var did = Str(p, "subjectDid", "did");
                if (did is null) { Skip(topic, "no subjectDid"); return; }
                await Stores.UpsertCompliance(cx, tx, did, null, "HELD", null,
                    $"HELD@{asOf}", asOf);
                break;
            }
            case KafkaTopics.FRAUD_ENFORCEMENT_ACCOUNT_HOLD_RELEASED_V1:
            {
                var did = Str(p, "subjectDid", "did");
                if (did is null) { Skip(topic, "no subjectDid"); return; }
                await Stores.UpsertCompliance(cx, tx, did, null, "ACTIVE", null,
                    $"HOLD_RELEASED@{asOf}", asOf);
                break;
            }
            default:
                Skip(topic, "mapping NEEDS-INFO");
                break;
        }
    }

    private void Skip(string topic, string why) => log.LogInformation("skip {t}: {w}", topic, why);

    private static string EventId(ConsumeResult<string, string> cr, JsonElement p)
    {
        var h = cr.Message.Headers?.TryGetLastBytes("event_id", out var raw) == true ? raw : null;
        if (h is not null) return Encoding.UTF8.GetString(h);
        var fromPayload = Str(p, "eventId", "event_id");
        return fromPayload ?? $"{cr.Topic}/{cr.Partition.Value}/{cr.Offset.Value}";
    }

    private static JsonDocument Parse(string? value)
    {
        try { return JsonDocument.Parse(string.IsNullOrEmpty(value) ? "{}" : value); }
        catch (JsonException) { return JsonDocument.Parse("{}"); }
    }

    private static string? Str(JsonElement p, params string[] names)
    {
        foreach (var n in names)
            if (p.ValueKind == JsonValueKind.Object && p.TryGetProperty(n, out var v)
                && v.ValueKind == JsonValueKind.String && !string.IsNullOrEmpty(v.GetString()))
                return v.GetString();
        return null;
    }

    private static long? Long(JsonElement p, params string[] names)
    {
        foreach (var n in names)
            if (p.ValueKind == JsonValueKind.Object && p.TryGetProperty(n, out var v)
                && v.ValueKind == JsonValueKind.Number && v.TryGetInt64(out var l))
                return l;
        return null;
    }
}
