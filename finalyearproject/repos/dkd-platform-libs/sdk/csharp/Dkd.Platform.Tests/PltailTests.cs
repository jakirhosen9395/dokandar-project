// HAND-AUTHORED tests (NOT dkdgen-generated) for the platform-libs tail findings PL-03..PL-08.

namespace Dkd.Platform;

using System.Collections.Generic;
using Microsoft.OpenApi;
using Xunit;

public class PltailTests
{
    // ---- PL-03: Idempotency-Key HTTP helper (three branches, fake store) --------------------

    private sealed class FakeIdemStore : IIdempotencyStore
    {
        private readonly Dictionary<string, IdempotencyRecord> _rows = new();
        public IdempotencyRecord? Find(string key) => _rows.TryGetValue(key, out var r) ? r : null;
        public void Save(IdempotencyRecord record) => _rows[record.Key] = record;
    }

    [Fact]
    public void Idempotency_MissingKey_Is400()
    {
        var d = Idempotency.Evaluate(new FakeIdemStore(), null, "{\"amount\":100}");
        Assert.Equal(IdempotencyOutcome.MissingKey, d.Outcome);
        Assert.Equal(400, d.HttpStatus);
        Assert.Equal(Idempotency.MissingKeyCode, d.Code);
    }

    [Fact]
    public void Idempotency_SameKeySamePayload_ReplaysOriginalResponse()
    {
        var store = new FakeIdemStore();
        const string key = "idem-key-1";
        const string payload = "{\"amount\":100}";

        var first = Idempotency.Evaluate(store, key, payload);
        Assert.Equal(IdempotencyOutcome.Proceed, first.Outcome);

        var original = new IdempotentResponse(201, "{\"orderId\":\"ORD-1\"}");
        Idempotency.Remember(store, key, payload, original);

        var replay = Idempotency.Evaluate(store, key, payload);
        Assert.Equal(IdempotencyOutcome.Replay, replay.Outcome);
        Assert.Equal(original, replay.Response);
        Assert.Equal(201, replay.HttpStatus);
    }

    [Fact]
    public void Idempotency_SameKeyDifferentPayload_Is409()
    {
        var store = new FakeIdemStore();
        const string key = "idem-key-2";
        Idempotency.Remember(store, key, "{\"amount\":100}", new IdempotentResponse(201, "ok"));

        var d = Idempotency.Evaluate(store, key, "{\"amount\":999}");
        Assert.Equal(IdempotencyOutcome.Conflict, d.Outcome);
        Assert.Equal(409, d.HttpStatus);
        Assert.Equal(Idempotency.MismatchCode, d.Code);
    }

    // ---- PL-04: UUID v7 generator + strict validation ---------------------------------------

    [Fact]
    public void Uuid7_Generated_IsValidV7()
    {
        var id = Uuid7.NewId();
        Assert.True(Uuid7.IsValidV7(id));
        Assert.Equal('7', id[14]); // version nibble position in canonical form
        Assert.Contains(id[19], "89ab"); // variant nibble is 8/9/a/b
    }

    [Fact]
    public void Uuid7_V4AndGarbage_Rejected()
    {
        Assert.False(Uuid7.IsValidV7(System.Guid.NewGuid().ToString())); // v4 -> version nibble 4
        Assert.False(Uuid7.IsValidV7("not-a-uuid"));
        Assert.False(Uuid7.IsValidV7("zzzzzzzz-zzzz-7zzz-8zzz-zzzzzzzzzzzz"));
        Assert.False(Uuid7.IsValidV7(null));
    }

    [Fact]
    public void Uuid7_TimestampRoundTrips()
    {
        var now = System.DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var id = Uuid7.NewId(now);
        Assert.Equal(now, Uuid7.TimestampMs(id));
    }

    [Fact]
    public void PrefixedId_V7_PassesAndFails()
    {
        var did = Ids7.NewDid();
        Assert.True(Ids7.IsValidV7(did));
        Assert.StartsWith(DID.Prefix, did.Value);
        Assert.Same(did, Ids7.RequireV7(did));

        var v4Body = new PPID(PPID.Prefix + System.Guid.NewGuid()); // valid prefix, v4 body
        Assert.False(Ids7.IsValidV7(v4Body));
        Assert.Throws<System.ArgumentException>(() => Ids7.RequireV7(v4Body));

        var garbage = new ORD(ORD.Prefix + "not-a-uuid");
        Assert.False(Ids7.IsValidV7(garbage));
    }

    // ---- PL-05: W3C traceparent parse/format/inject/extract ---------------------------------

    [Fact]
    public void Traceparent_ParseFormat_RoundTrips()
    {
        const string wire = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";
        var tp = W3CTrace.Parse(wire);
        Assert.NotNull(tp);
        Assert.Equal(wire, tp!.Format());
        Assert.Equal("4bf92f3577b34da6a3ce929d0e0e4736", tp.TraceId);
        Assert.Equal("00f067aa0ba902b7", tp.SpanId);
    }

    [Theory]
    [InlineData("")]
    [InlineData("00-abc-def-01")]                                             // wrong widths
    [InlineData("00-00000000000000000000000000000000-00f067aa0ba902b7-01")]  // all-zero trace-id
    [InlineData("00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01")]  // all-zero span-id
    [InlineData("ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")]  // forbidden version ff
    [InlineData("00-4BF92F3577B34DA6A3CE929D0E0E4736-00f067aa0ba902b7-01")]  // uppercase hex
    public void Traceparent_Malformed_Rejected(string wire)
    {
        Assert.Null(W3CTrace.Parse(wire));
        Assert.False(W3CTrace.TryParse(wire, out _));
    }

    [Fact]
    public void Traceparent_InjectExtract_AndNewSpan()
    {
        var root = W3CTrace.NewRootSpan();
        var headers = new Dictionary<string, string>();
        W3CTrace.Inject(headers, root);
        Assert.Equal(root.Format(), headers[W3CTrace.HeaderName]);

        var extracted = W3CTrace.Extract(headers);
        Assert.Equal(root, extracted);

        var child = W3CTrace.NewChildSpan(root);
        Assert.Equal(root.TraceId, child.TraceId);
        Assert.NotEqual(root.SpanId, child.SpanId);
    }

    [Fact]
    public void OutboxRelay_Headers_InjectsValidTraceparentOnly()
    {
        var rec = new OutboxRecord(1, "evt-1", "custody.passport.CustodyInitialized.v1", "PP-1", "{}", 0);

        var valid = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";
        var withTrace = OutboxRelay.Headers(rec, "custody", valid);
        Assert.Equal(valid, withTrace["traceparent"]);

        var withGarbage = OutboxRelay.Headers(rec, "custody", "garbage");
        Assert.False(withGarbage.ContainsKey("traceparent")); // malformed dropped, never fabricated
    }

    // ---- PL-06: error -> HTTP status vocabulary (EF-API-3) ----------------------------------

    [Theory]
    [InlineData(ErrorCategory.Malformed, 400)]
    [InlineData(ErrorCategory.BusinessValidation, 422)]
    [InlineData(ErrorCategory.Authz, 403)]
    [InlineData(ErrorCategory.FourEyes, 403)]
    [InlineData(ErrorCategory.StateConflict, 409)]
    [InlineData(ErrorCategory.IdempotencyMismatch, 409)]
    [InlineData(ErrorCategory.Locked, 423)]
    [InlineData(ErrorCategory.RateLimit, 429)]
    [InlineData(ErrorCategory.AsyncAccepted, 202)]
    [InlineData(ErrorCategory.Unavailable, 503)]
    public void HttpStatusMap_MapsEveryCategory(ErrorCategory category, int expected)
        => Assert.Equal(expected, HttpStatusMap.StatusFor(category));

    [Fact]
    public void TypedExceptions_CarryCanonStatus()
    {
        Assert.Equal(422, new BusinessValidationException("dokandar.b2c.validation.bad_qty", "x").HttpStatus);
        Assert.Equal(423, new LockedException("dokandar.finance.locked.fenced", "x").HttpStatus);
        var rl = new RateLimitException("dokandar.edge.rate_limit.too_many", "x", 30);
        Assert.Equal(429, rl.HttpStatus);
        Assert.Equal(30, rl.RetryAfterSeconds);
    }

    // ---- PL-08: OpenAPI version pinned to 3.1.0 ---------------------------------------------

    [Fact]
    public void ApiDocs_OpenApiVersion_Is310()
    {
        Assert.Equal("3.1.0", ApiDocs.OpenApiVersion);
        Assert.Equal(OpenApiSpecVersion.OpenApi3_1, ApiDocs.SpecVersion);
        Assert.StartsWith("3.1", ApiDocs.OpenApiVersion);
    }
}
