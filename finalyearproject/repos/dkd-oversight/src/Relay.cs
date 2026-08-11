// gov-outbox-relay: at-least-once, ordered, stop-on-first-failure. Headers carry event_id +
// producer_context=government (fleet R6 convention).
using System.Text;
using Confluent.Kafka;
using Npgsql;

namespace OversightSvc;

public sealed class OutboxRelay(NpgsqlDataSource ds, Config cfg, ILogger<OutboxRelay> log)
    : BackgroundService
{
    // ct in Task.Run guards start only; the loop cancels cooperatively via ct checks.
    protected override Task ExecuteAsync(CancellationToken ct) => Task.Run(async () =>
    {
        using var producer = new ProducerBuilder<string, string>(new ProducerConfig
        {
            BootstrapServers = cfg.KafkaBrokers,
            Acks = Acks.All,
            EnableIdempotence = true,
            CompressionType = CompressionType.Snappy,
            AllowAutoCreateTopics = false,
        }).Build();
        while (!ct.IsCancellationRequested)
        {
            try
            {
                await DrainOnce(producer, ct);
            }
            catch (OperationCanceledException) { break; }
            catch (Exception e)
            {
                log.LogError(e, "relay drain failed; retrying");
            }
            try { await Task.Delay(500, ct); } catch (OperationCanceledException) { break; }
        }
        producer.Flush(TimeSpan.FromSeconds(5));
    }, ct);

    private async Task DrainOnce(IProducer<string, string> producer, CancellationToken ct)
    {
        List<Stores.OutboxRow> rows;
        await using (var cx = await ds.OpenConnectionAsync(ct))
            rows = await Stores.FetchUnpublished(cx, 200);
        foreach (var row in rows)
        {
            var msg = new Message<string, string>
            {
                Key = row.Key,
                Value = row.Payload,
                Headers = new Headers
                {
                    { "event_id", Encoding.UTF8.GetBytes(row.EventId) },
                    { "producer_context", "government"u8.ToArray() },
                },
            };
            try
            {
                await producer.ProduceAsync(row.Topic, msg, ct);
            }
            catch (ProduceException<string, string> e)
            {
                log.LogError(e, "publish failed for {topic} — stopping this drain (ordering)", row.Topic);
                break;
            }
            await using var cx = await ds.OpenConnectionAsync(ct);
            await Stores.MarkPublished(cx, row.Id, Domain.NowMs());
        }
    }
}
