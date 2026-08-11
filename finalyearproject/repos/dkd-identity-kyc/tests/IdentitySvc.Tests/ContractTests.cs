// Consumer-driven contract / fitness tests for the identity event surface.
// Enforces the frozen Published-Language rules: payloads carry canonical IDs only (NO PII, C1/R6),
// topic names conform to <context>.<aggregate>.<EventName>.v<N> and match the SDK constants, and
// KYCSubmitted is RabbitMQ-only (not the Kafka Published Language).
using System.Text.Json;
using System.Text.RegularExpressions;
using Dkd.Platform;
using IdentitySvc.Adapters;
using IdentitySvc.Domain;
using Xunit;

namespace IdentitySvc.Tests;

public sealed class ContractTests
{
    private const string Did = "did:dokandar:019f0000-0000-7000-8000-000000000000";

    // Every emitted event, as the outbox serializes it (Payload = the record, envelope [JsonIgnore]d).
    public static IEnumerable<object[]> AllEvents() => new List<object[]>
    {
        new object[] { new PartyRegisteredV1(Did, "UNVERIFIED", "bn-BD", 1) },
        new object[] { new KycApprovedV1(Did, "BASIC", 1, "did:dokandar:sys") },
        new object[] { new KycTierChangedV1(Did, "BASIC", "FULL", 1, "did:dokandar:sys") },
        new object[] { new KycRejectedV1(Did, "bad docs", 1) },
        new object[] { new PartySuspendedV1(Did, "fraud", 1, "did:dokandar:gov") },
        new object[] { new PartyReactivatedV1(Did, 1, "did:dokandar:gov") },
        new object[] { new KycSubmittedV1(Did, 1, "BASIC") },
    };

    private static readonly string[] PiiForbidden =
        { "phone", "phonenumber", "msisdn", "name", "nid", "nidhash", "address", "email", "selfie", "document", "documenturls", "bin", "tin", "deviceid", "deviceids" };

    [Theory]
    [MemberData(nameof(AllEvents))]
    public void Event_payload_carries_no_pii(IDomainEvent ev)
    {
        var json = JsonSerializer.Serialize(ev.Payload, Json.Options);
        using var doc = JsonDocument.Parse(json);
        foreach (var prop in doc.RootElement.EnumerateObject())
        {
            var name = prop.Name.ToLowerInvariant();
            Assert.DoesNotContain(name, PiiForbidden);
        }
        // envelope infrastructure must never leak into the payload
        Assert.False(json.Contains("\"bus\"", StringComparison.OrdinalIgnoreCase));
        Assert.False(json.Contains("\"destination\"", StringComparison.OrdinalIgnoreCase));
        Assert.False(json.Contains("\"payload\"", StringComparison.OrdinalIgnoreCase));
    }

    [Theory]
    [MemberData(nameof(AllEvents))]
    public void Event_payload_carries_the_did(IDomainEvent ev)
    {
        var json = JsonSerializer.Serialize(ev.Payload, Json.Options);
        using var doc = JsonDocument.Parse(json);
        Assert.True(doc.RootElement.TryGetProperty("did", out _), "every identity event must carry the did");
        Assert.Equal(Did, ev.PartitionKey);   // ordering key = DID
    }

    [Fact]
    public void Kafka_events_use_conforming_topic_names_matching_the_sdk()
    {
        var re = new Regex(@"^identity\.party\.[A-Za-z]+\.v\d+$");
        var expected = new[]
        {
            (typeof(PartyRegisteredV1),  KafkaTopics.IDENTITY_PARTY_PARTY_REGISTERED_V1),
            (typeof(KycApprovedV1),      KafkaTopics.IDENTITY_PARTY_KYCAPPROVED_V1),
            (typeof(KycTierChangedV1),   KafkaTopics.IDENTITY_PARTY_KYCTIER_CHANGED_V1),
            (typeof(KycRejectedV1),      KafkaTopics.IDENTITY_PARTY_KYCREJECTED_V1),
            (typeof(PartySuspendedV1),   KafkaTopics.IDENTITY_PARTY_PARTY_SUSPENDED_V1),
            (typeof(PartyReactivatedV1), KafkaTopics.IDENTITY_PARTY_PARTY_REACTIVATED_V1),
        };
        foreach (var row in AllEvents())
        {
            var ev = (IDomainEvent)row[0];
            if (ev.Bus != "kafka") continue;
            Assert.Matches(re, ev.Destination);
            var match = expected.Single(e => e.Item1 == ev.GetType());
            Assert.Equal(match.Item2, ev.Destination);
        }
    }

    [Fact]
    public void KycSubmitted_is_rabbitmq_only_not_the_kafka_published_language()
    {
        var e = new KycSubmittedV1(Did, 1, "BASIC");
        Assert.Equal("rabbitmq", e.Bus);
        Assert.Equal(RabbitQueues.IDENTITY_KYC_VERIFICATION, e.Destination);
    }

    [Fact]
    public void Error_codes_conform_to_the_dokandar_identity_taxonomy()
    {
        var code = Errors.ErrorCode(ContextSlug.Identity, "validation", "idempotency_key_required");
        Assert.Equal("dokandar.identity.validation.idempotency_key_required", code);
    }
}
