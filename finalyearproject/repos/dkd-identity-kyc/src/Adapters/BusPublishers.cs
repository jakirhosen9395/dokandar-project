// Kafka (cross-context Published Language, R6) + RabbitMQ (intra-context) publishers.
using System.Text;
using Confluent.Kafka;
using IdentitySvc.Messaging;
using RabbitMQ.Client;

namespace IdentitySvc.Adapters;

/// <summary>Kafka producer (Confluent.Kafka) — implements the blueprint IPublisher seam.</summary>
public sealed class KafkaBusPublisher : IPublisher
{
    private readonly IProducer<string, byte[]> _producer;

    public KafkaBusPublisher(string bootstrapServers)
    {
        _producer = new ProducerBuilder<string, byte[]>(new ProducerConfig
        {
            BootstrapServers = bootstrapServers,
            Acks = Acks.All,
            EnableIdempotence = true,
            MessageSendMaxRetries = 5,
        }).Build();
    }

    public async Task PublishAsync(string topic, string key, ReadOnlyMemory<byte> payload, CancellationToken ct = default)
    {
        await _producer.ProduceAsync(topic, new Message<string, byte[]> { Key = key, Value = payload.ToArray() }, ct);
    }

    public ValueTask DisposeAsync()
    {
        _producer.Flush(TimeSpan.FromSeconds(5));
        _producer.Dispose();
        return ValueTask.CompletedTask;
    }
}

/// <summary>RabbitMQ publisher for intra-context queues (NOT the Published Language). Lazily connects;
/// declares the target queue durable (idempotent) before publishing.</summary>
public sealed class RabbitBusPublisher(string amqpUrl) : IDisposable
{
    private readonly string _url = amqpUrl;
    private readonly object _lock = new();
    private IConnection? _conn;
    private IModel? _ch;

    public Task PublishAsync(string queue, ReadOnlyMemory<byte> body, CancellationToken ct = default)
    {
        lock (_lock)
        {
            EnsureChannel();
            _ch!.QueueDeclare(queue, durable: true, exclusive: false, autoDelete: false, arguments: null);
            var props = _ch.CreateBasicProperties();
            props.DeliveryMode = 2; // persistent
            props.ContentType = "application/json";
            _ch.BasicPublish(exchange: string.Empty, routingKey: queue, basicProperties: props, body: body);
        }
        return Task.CompletedTask;
    }

    private void EnsureChannel()
    {
        if (_ch is { IsOpen: true }) return;
        var factory = new ConnectionFactory { Uri = new Uri(_url), DispatchConsumersAsync = false };
        _conn = factory.CreateConnection();
        _ch = _conn.CreateModel();
    }

    public void Dispose()
    {
        try { _ch?.Close(); _conn?.Close(); } catch { /* best-effort */ }
        _ch?.Dispose(); _conn?.Dispose();
    }
}
