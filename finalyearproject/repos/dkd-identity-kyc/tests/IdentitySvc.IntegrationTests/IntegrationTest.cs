// Integration tests against a REAL PostgreSQL (CI provides a `postgres` service; locally set
// DKD_TEST_DB_DSN). Boots the full app (migrations, middleware, DI) and exercises the DB write/read
// path + idempotency. When DKD_TEST_DB_DSN is unset the tests no-op so unit runs stay infra-free.
using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.AspNetCore.Mvc.Testing;
using Xunit;

namespace IdentitySvc.IntegrationTests;

public sealed class PostgresFixture : IDisposable
{
    public string? Dsn { get; } = Environment.GetEnvironmentVariable("DKD_TEST_DB_DSN");
    public bool Enabled => !string.IsNullOrWhiteSpace(Dsn);
    public WebApplicationFactory<Program>? Factory { get; }

    public PostgresFixture()
    {
        if (!Enabled) return;
        Environment.SetEnvironmentVariable("DKD_DB_DSN", Dsn);
        Environment.SetEnvironmentVariable("DKD_KAFKA_BROKERS", "localhost:9092"); // brokers absent in CI; publish just retries
        Environment.SetEnvironmentVariable("DKD_DEV_OTP", "000000");
        Factory = new WebApplicationFactory<Program>();
    }

    public void Dispose() => Factory?.Dispose();
}

[Trait("Category", "Integration")]
public sealed class IdentityIntegrationTests(PostgresFixture fx) : IClassFixture<PostgresFixture>
{
    private static string RandomPhone() =>
        "+88017" + (Math.Abs(Guid.NewGuid().GetHashCode()) % 100_000_000).ToString("D8");

    private static HttpRequestMessage Post(string path, object body, string? idemKey)
    {
        var req = new HttpRequestMessage(HttpMethod.Post, path) { Content = JsonContent.Create(body) };
        if (idemKey is not null) req.Headers.Add("Idempotency-Key", idemKey);
        return req;
    }

    [Fact]
    public async Task Register_persists_reads_and_is_idempotent()
    {
        if (!fx.Enabled) return;   // no-op when no DB configured (unit-only runs)
        var c = fx.Factory!.CreateClient();
        var phone = RandomPhone();
        var key = Guid.NewGuid().ToString();
        var body = new { phoneNumber = phone, otpToken = "000000" };

        var r1 = await c.SendAsync(Post("/v1/parties", body, key));
        Assert.Equal(HttpStatusCode.Created, r1.StatusCode);
        var did1 = (await r1.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("data").GetProperty("did").GetString();
        Assert.StartsWith("did:dokandar:", did1);

        // same Idempotency-Key -> replayed, same DID (no duplicate)
        var r2 = await c.SendAsync(Post("/v1/parties", body, key));
        var did2 = (await r2.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("data").GetProperty("did").GetString();
        Assert.Equal(did1, did2);
        Assert.True(r2.Headers.TryGetValues("Idempotency-Replayed", out var v) && string.Join("", v) == "true");

        // read back
        var get = await c.GetAsync($"/v1/parties/{did1}");
        Assert.Equal(HttpStatusCode.OK, get.StatusCode);
        var view = (await get.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("data");
        Assert.Equal("UNVERIFIED", view.GetProperty("kycTier").GetString());
    }

    [Fact]
    public async Task Unsafe_write_without_idempotency_key_is_rejected()
    {
        if (!fx.Enabled) return;
        var c = fx.Factory!.CreateClient();
        var r = await c.SendAsync(Post("/v1/parties", new { phoneNumber = RandomPhone(), otpToken = "000000" }, null));
        Assert.Equal(HttpStatusCode.BadRequest, r.StatusCode);
    }

    [Fact]
    public async Task Health_ok_against_real_db()
    {
        if (!fx.Enabled) return;
        var c = fx.Factory!.CreateClient();
        Assert.Equal(HttpStatusCode.OK, (await c.GetAsync("/health")).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await c.GetAsync("/ready")).StatusCode);
    }
}
