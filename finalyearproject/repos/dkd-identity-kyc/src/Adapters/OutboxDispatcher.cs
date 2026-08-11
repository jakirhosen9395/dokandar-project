// Transactional-outbox dispatcher (BackgroundService). Polls unsent rows and publishes each to Kafka
// or RabbitMQ, then marks it sent. At-least-once delivery (consumers dedup via inbox on event_id).
// Single-dispatcher assumption for the dev substrate; a poison message keeps its row (retried) rather
// than being silently dropped. DLQ/park-and-freeze is Phase 2.
using System.Text;
using IdentitySvc.Messaging;
using Npgsql;

namespace IdentitySvc.Adapters;

public sealed class OutboxDispatcher(
    NpgsqlDataSource ds, IPublisher kafka, RabbitBusPublisher rabbit, ILogger<OutboxDispatcher> log)
    : BackgroundService
{
    private const int BatchSize = 100;
    private const int MaxAttempts = 10;   // after this a poison row is parked (frozen), not retried, not dropped
    private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(500);

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        log.LogInformation("outbox dispatcher started (poll {Ms}ms)", PollInterval.TotalMilliseconds);
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var dispatched = await PumpAsync(ct);
                if (dispatched == 0) await Task.Delay(PollInterval, ct);
            }
            catch (OperationCanceledException) { break; }
            catch (Exception ex)
            {
                log.LogError(ex, "outbox pump error");
                await Task.Delay(PollInterval, ct);
            }
        }
    }

    private async Task<int> PumpAsync(CancellationToken ct)
    {
        await using var conn = await ds.OpenConnectionAsync(ct);
        var rows = new List<(long Id, string Bus, string Dest, string Key, string Payload)>();
        await using (var q = new NpgsqlCommand(
            @"SELECT id, bus, destination, partition_key, payload::text FROM outbox
              WHERE sent_at IS NULL AND attempts < @max ORDER BY id LIMIT @n", conn))
        {
            q.Parameters.AddWithValue("max", MaxAttempts);
            q.Parameters.AddWithValue("n", BatchSize);
            await using var r = await q.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
                rows.Add((r.GetInt64(0), r.GetString(1), r.GetString(2), r.GetString(3), r.GetString(4)));
        }

        var sent = 0;
        foreach (var row in rows)
        {
            var body = Encoding.UTF8.GetBytes(row.Payload);
            try
            {
                if (row.Bus == "kafka") await kafka.PublishAsync(row.Dest, row.Key, body, ct);
                else if (row.Bus == "rabbitmq") await rabbit.PublishAsync(row.Dest, body, ct);
                else { log.LogWarning("unknown bus {Bus} for outbox {Id}", row.Bus, row.Id); continue; }

                await using var upd = new NpgsqlCommand(
                    "UPDATE outbox SET sent_at = @t, attempts = attempts + 1 WHERE id = @id", conn);
                upd.Parameters.AddWithValue("t", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
                upd.Parameters.AddWithValue("id", row.Id);
                await upd.ExecuteNonQueryAsync(ct);
                sent++;
            }
            catch (Exception ex)
            {
                await using var bump = new NpgsqlCommand(
                    "UPDATE outbox SET attempts = attempts + 1 WHERE id = @id RETURNING attempts", conn);
                bump.Parameters.AddWithValue("id", row.Id);
                var attempts = Convert.ToInt32(await bump.ExecuteScalarAsync(ct));
                if (attempts >= MaxAttempts)
                    log.LogError(ex, "outbox {Id} ({Dest}) PARKED after {Attempts} attempts — frozen for manual replay, not dropped",
                        row.Id, row.Dest, attempts);
                else
                    log.LogWarning(ex, "publish failed for outbox {Id} ({Dest}), attempt {Attempts}; will retry",
                        row.Id, row.Dest, attempts);
            }
        }
        return sent;
    }
}
