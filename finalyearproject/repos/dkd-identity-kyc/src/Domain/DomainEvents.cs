// Identity domain events. Kafka payloads are transcribed VERBATIM from the frozen
// DOKANDAR-Domain-Model.md "Domain Events — Kafka" block (identity.party.*, key=DID).
// PII rule (C1): payloads carry canonical IDs only — never phone/name/NID/address.
// KYCSubmitted is intra-context RabbitMQ ONLY (not Kafka, not the Published Language).
//
// The IDomainEvent envelope members (Bus/Destination/PartitionKey/Payload) are [JsonIgnore]d so a
// record serializes to EXACTLY its data payload (no envelope, no self-referential cycle).
using System.Text.Json.Serialization;
using Dkd.Platform;

namespace IdentitySvc.Domain;

/// <summary>An emitted domain fact, bound to its bus + topic/queue + partition key (DID).</summary>
public interface IDomainEvent
{
    [JsonIgnore] string Bus { get; }          // "kafka" (cross-context PL) | "rabbitmq" (intra-context)
    [JsonIgnore] string Destination { get; }  // Kafka topic name or RabbitMQ queue name
    [JsonIgnore] string PartitionKey { get; } // ordering key — DID for all identity events
    [JsonIgnore] object Payload { get; }       // the record's own data fields (serialized as canonical JSON)
}

// ---- Kafka Published-Language events (identity.party.*, key=DID) ----

public sealed record PartyRegisteredV1(string Did, string KycTier, string Locale, long RegisteredAt) : IDomainEvent
{
    [JsonIgnore] public string Bus => "kafka";
    [JsonIgnore] public string Destination => KafkaTopics.IDENTITY_PARTY_PARTY_REGISTERED_V1;
    [JsonIgnore] public string PartitionKey => Did;
    [JsonIgnore] public object Payload => this;
}

public sealed record KycApprovedV1(string Did, string NewTier, long ApprovedAt, string VerifiedBy) : IDomainEvent
{
    [JsonIgnore] public string Bus => "kafka";
    [JsonIgnore] public string Destination => KafkaTopics.IDENTITY_PARTY_KYCAPPROVED_V1;
    [JsonIgnore] public string PartitionKey => Did;
    [JsonIgnore] public object Payload => this;
}

public sealed record KycTierChangedV1(string Did, string PreviousTier, string NewTier, long ChangedAt, string ChangedBy) : IDomainEvent
{
    [JsonIgnore] public string Bus => "kafka";
    [JsonIgnore] public string Destination => KafkaTopics.IDENTITY_PARTY_KYCTIER_CHANGED_V1;
    [JsonIgnore] public string PartitionKey => Did;
    [JsonIgnore] public object Payload => this;
}

public sealed record KycRejectedV1(string Did, string Reason, long RejectedAt) : IDomainEvent
{
    [JsonIgnore] public string Bus => "kafka";
    [JsonIgnore] public string Destination => KafkaTopics.IDENTITY_PARTY_KYCREJECTED_V1;
    [JsonIgnore] public string PartitionKey => Did;
    [JsonIgnore] public object Payload => this;
}

public sealed record PartySuspendedV1(string Did, string Reason, long SuspendedAt, string By) : IDomainEvent
{
    [JsonIgnore] public string Bus => "kafka";
    [JsonIgnore] public string Destination => KafkaTopics.IDENTITY_PARTY_PARTY_SUSPENDED_V1;
    [JsonIgnore] public string PartitionKey => Did;
    [JsonIgnore] public object Payload => this;
}

public sealed record PartyReactivatedV1(string Did, long ReactivatedAt, string By) : IDomainEvent
{
    [JsonIgnore] public string Bus => "kafka";
    [JsonIgnore] public string Destination => KafkaTopics.IDENTITY_PARTY_PARTY_REACTIVATED_V1;
    [JsonIgnore] public string PartitionKey => Did;
    [JsonIgnore] public object Payload => this;
}

// ---- RabbitMQ intra-context event (NOT the Published Language) ----

public sealed record KycSubmittedV1(string Did, long SubmittedAt, string TierRequested) : IDomainEvent
{
    [JsonIgnore] public string Bus => "rabbitmq";
    [JsonIgnore] public string Destination => RabbitQueues.IDENTITY_KYC_VERIFICATION;
    [JsonIgnore] public string PartitionKey => Did;
    [JsonIgnore] public object Payload => this;
}
