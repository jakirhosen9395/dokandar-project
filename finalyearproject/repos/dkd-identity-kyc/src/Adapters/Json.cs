// Canonical JSON options for event payloads (camelCase, omit nulls) — used by the outbox and buses.
using System.Text.Json;
using System.Text.Json.Serialization;

namespace IdentitySvc.Adapters;

public static class Json
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static byte[] Bytes(object o) => JsonSerializer.SerializeToUtf8Bytes(o, Options);
    public static string String(object o) => JsonSerializer.Serialize(o, Options);
}
