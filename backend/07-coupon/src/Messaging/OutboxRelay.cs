using System.Text;
using Confluent.Kafka;
using Microsoft.EntityFrameworkCore;
using Elastic.Apm;
using Elastic.Apm.Api;
using Coupon.Data;
using Coupon.Observability;

namespace Coupon.Messaging;

// Transactional-outbox relay: poll unsent rows (FOR UPDATE SKIP LOCKED), publish to Kafka (acks=all,
// idempotent), mark sent_at. Publish-before-mark ⇒ at-least-once. Wrapped so it never blocks Kestrel.
public class OutboxRelay(IServiceProvider sp) : BackgroundService
{
    private IProducer<string, byte[]>? _producer;
    private int _idle;

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        await Task.Yield(); // return to host immediately — never block startup
        while (!ct.IsCancellationRequested && _producer == null)
        {
            try
            {
                var cfg = new ProducerConfig { BootstrapServers = Config.KafkaBootstrap, Acks = Acks.All, EnableIdempotence = true, ClientId = "07-coupon-outbox", MessageTimeoutMs = 10000 };
                _producer = new ProducerBuilder<string, byte[]>(cfg).Build();
                Log.Info("coupon.outbox", "kafka producer connected");
            }
            catch (Exception e) { Log.Warn("coupon.outbox", $"kafka connect retry: {e.Message}"); await Task.Delay(5000, ct); }
        }
        while (!ct.IsCancellationRequested)
        {
            int n;
            try { n = await TickAsync(ct); }
            catch (Exception e) { Log.Warn("coupon.outbox", $"tick error: {e.Message}"); await Task.Delay(2000, ct); continue; }
            _idle = n > 0 ? 0 : Math.Min(_idle + 1, 5); // back off when idle: 1s..6s (cuts idle DB polls + APM noise)
            await Task.Delay(TimeSpan.FromSeconds(Config.OutboxPollSeconds * (1 + _idle)), ct);
        }
    }

    private async Task<int> TickAsync(CancellationToken ct)
    {
        // Wrap the relay batch in an APM transaction so this BACKGROUND JOB is visible in APM
        // (the EF poll span + the Kafka producer spans nest under it). The .NET agent does NOT
        // auto-instrument Confluent.Kafka, so each produce gets an explicit messaging span with a
        // friendly "kafka" destination → Kafka shows in Dependencies + the service map.
        var apmTx = Agent.Tracer.StartTransaction("OutboxRelay process", "messaging");
        try
        {
        using var scope = sp.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<CouponDbContext>();
        await using var tx = await db.Database.BeginTransactionAsync(ct);
        var rows = await db.Outbox.FromSqlRaw(
            $"SELECT * FROM outbox WHERE sent_at IS NULL ORDER BY id LIMIT {Config.OutboxBatch} FOR UPDATE SKIP LOCKED").ToListAsync(ct);
        if (rows.Count == 0) { await tx.RollbackAsync(ct); return 0; }
        var sent = new List<long>();
        foreach (var r in rows)
        {
            try
            {
                var span = apmTx.StartSpan($"Kafka SEND to {r.Topic}", "messaging", "kafka", "send");
                span.Context.Destination = new Destination { Service = new Destination.DestinationService { Resource = "kafka", Name = "kafka", Type = "messaging" } };
                try { await _producer!.ProduceAsync(r.Topic, new Message<string, byte[]> { Key = r.Key ?? "", Value = Encoding.UTF8.GetBytes(r.Payload) }, ct); }
                finally { span.End(); }
                sent.Add(r.Id);
            }
            catch (Exception e) { Log.Warn("coupon.outbox", $"produce failed id={r.Id}: {e.Message}"); break; } // preserve id order
        }
        if (sent.Count > 0)
        {
            await db.Database.ExecuteSqlRawAsync("UPDATE outbox SET sent_at = now() WHERE id = ANY({0})", new object[] { sent.ToArray() });
            await tx.CommitAsync(ct);
            Metrics.OutboxPublished.WithLabels(Metrics.Svc).Inc(sent.Count);
            Log.Info("coupon.outbox", $"published {sent.Count} event(s)");
            return sent.Count;
        }
        await tx.RollbackAsync(ct);
        return 0;
        }
        finally { apmTx.End(); }
    }
}
