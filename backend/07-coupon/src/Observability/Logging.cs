using System.Collections.Concurrent;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Elastic.Apm;
using MongoDB.Bson;
using MongoDB.Driver;

namespace Coupon.Observability;

// Three-sink structured logging mirroring 01-auth: stdout JSON w/ elasticapm_* fields,
// MongoDB forensic collection <service>, Elasticsearch data stream logs-app-07-coupon-*.
// Trace ids read from the Elastic APM .NET agent's CurrentTransaction/CurrentSpan.
public static class Log
{
    static readonly ConcurrentQueue<BsonDocument> _mongoQ = new();
    static readonly ConcurrentQueue<string> _esQ = new();
    static IMongoCollection<BsonDocument>? _mongoColl;
    static volatile bool _mongoUp;
    static readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(6) };
    static readonly JsonSerializerOptions _json = new() { DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.Never };

    public static bool MongoHealthy => _mongoUp;

    static (string? trace, string? tx, string? span) Ids()
    {
        try
        {
            if (!Agent.IsConfigured) return (null, null, null);
            var t = Agent.Tracer.CurrentTransaction;
            var s = Agent.Tracer.CurrentSpan;
            return (t?.TraceId, t?.Id, s?.Id);
        }
        catch { return (null, null, null); }
    }

    static Dictionary<string, object?> ApmFields(string? trace, string? tx, string? span) => new()
    {
        ["elasticapm_service_name"] = Config.ApmServiceName,
        ["elasticapm_service_environment"] = Config.AppEnv,
        ["elasticapm_trace_id"] = trace,
        ["elasticapm_transaction_id"] = tx,
        ["elasticapm_labels"] = new Dictionary<string, object?>
        {
            ["transaction.id"] = tx, ["trace.id"] = trace, ["span.id"] = span,
            ["service.name"] = Config.ApmServiceName, ["service.environment"] = Config.AppEnv,
        },
    };

    public static void Info(string name, string msg) => Emit("INFO", name, msg);
    public static void Warn(string name, string msg) => Emit("WARNING", name, msg);
    public static void Error(string name, string msg) => Emit("ERROR", name, msg);

    static void Emit(string level, string name, string msg)
    {
        var (trace, tx, span) = Ids();
        var af = ApmFields(trace, tx, span);
        var stdout = new Dictionary<string, object?>
        {
            ["asctime"] = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss,fff"),
            ["name"] = name, ["levelname"] = level, ["message"] = msg,
        };
        foreach (var kv in af) stdout[kv.Key] = kv.Value;
        Console.WriteLine(JsonSerializer.Serialize(stdout, _json));

        var doc = new Dictionary<string, object?>
        {
            ["@timestamp"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ"),
            ["log"] = new Dictionary<string, object?> { ["level"] = level.ToLowerInvariant(), ["logger"] = name },
            ["message"] = msg,
            ["service"] = new Dictionary<string, object?> { ["name"] = Config.ServiceName, ["version"] = Config.CodeVersion, ["environment"] = Config.AppEnv },
            ["labels"] = new Dictionary<string, object?> { ["tenant"] = Config.Tenant, ["env_version"] = Config.EnvVersion },
        };
        foreach (var kv in af) doc[kv.Key] = kv.Value;
        if (trace != null) { doc["trace"] = new Dictionary<string, object?> { ["id"] = trace }; doc["transaction"] = new Dictionary<string, object?> { ["id"] = tx }; }
        var jsonDoc = JsonSerializer.Serialize(doc, _json);
        if (!string.IsNullOrEmpty(Config.MongoLogUri)) { if (_mongoQ.Count < 5000) _mongoQ.Enqueue(BsonDocument.Parse(jsonDoc)); }
        if (!string.IsNullOrEmpty(Config.EsUrl)) { if (_esQ.Count < 5000) _esQ.Enqueue(jsonDoc); }
    }

    public static void Access(string ip, string method, string path, int status, string reason)
        => Console.WriteLine($"{DateTime.Now:dd-MM-yyyy HH:mm:ss}    {ip} - \"{method} {path} HTTP/1.1\" {status} {reason}");

    public static void StartSinks()
    {
        if (!string.IsNullOrEmpty(Config.MongoLogUri))
        {
            try { _mongoColl = new MongoClient(Config.MongoLogUri).GetDatabase(Config.MongoLogDb).GetCollection<BsonDocument>(Config.ServiceName); _mongoUp = true; }
            catch (Exception e) { Console.Error.WriteLine($"mongo log sink connect failed: {e.Message}"); }
            _ = Task.Run(async () =>
            {
                while (true)
                {
                    await Task.Delay(2000);
                    if (_mongoColl == null) continue;
                    var batch = new List<BsonDocument>();
                    while (batch.Count < 500 && _mongoQ.TryDequeue(out var d)) batch.Add(d);
                    if (batch.Count == 0) continue;
                    try { await _mongoColl.InsertManyAsync(batch, new InsertManyOptions { IsOrdered = false }); _mongoUp = true; }
                    catch { _mongoUp = false; }
                }
            });
        }
        if (!string.IsNullOrEmpty(Config.EsUrl))
        {
            var ds = $"logs-app-{Config.ServiceName}-default";
            var url = $"{Config.EsUrl.TrimEnd('/')}/{ds}/_bulk";
            AuthenticationHeaderValue? auth = !string.IsNullOrEmpty(Config.EsUser)
                ? new AuthenticationHeaderValue("Basic", Convert.ToBase64String(Encoding.UTF8.GetBytes($"{Config.EsUser}:{Config.EsPassword}")))
                : null;
            _ = Task.Run(async () =>
            {
                while (true)
                {
                    await Task.Delay(2000);
                    var batch = new List<string>();
                    while (batch.Count < 500 && _esQ.TryDequeue(out var d)) batch.Add(d);
                    if (batch.Count == 0) continue;
                    var sb = new StringBuilder();
                    foreach (var d in batch) { sb.Append("{\"create\":{}}\n"); sb.Append(d); sb.Append('\n'); }
                    try
                    {
                        using var req = new HttpRequestMessage(HttpMethod.Post, url) { Content = new StringContent(sb.ToString(), Encoding.UTF8, "application/x-ndjson") };
                        if (auth != null) req.Headers.Authorization = auth;
                        await _http.SendAsync(req);
                    }
                    catch { }
                }
            });
        }
    }
}
