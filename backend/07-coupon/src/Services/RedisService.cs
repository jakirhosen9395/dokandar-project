using StackExchange.Redis;
using Elastic.Apm.StackExchange.Redis;

namespace Coupon.Services;

// Redis DB6 — degradable: never throws into the request path; /ready does NOT gate on it.
public class RedisService
{
    private readonly IConnectionMultiplexer? _mux;
    private readonly IDatabase? _db;
    public RedisService()
    {
        try
        {
            var opt = new ConfigurationOptions
            {
                EndPoints = { { Config.RedisHost, Config.RedisPort } },
                Password = string.IsNullOrEmpty(Config.RedisPassword) ? null : Config.RedisPassword,
                DefaultDatabase = Config.RedisDb,
                AbortOnConnectFail = false,
                ConnectTimeout = 4000,
                ConnectRetry = 2,
            };
            _mux = ConnectionMultiplexer.Connect(opt);
            _mux.UseElasticApm(); // register the StackExchange.Redis profiler → redis spans in APM
            _db = _mux.GetDatabase(Config.RedisDb);
        }
        catch { _mux = null; _db = null; }
    }
    public bool Connected => _db != null && (_mux?.IsConnected ?? false);
    public async Task<bool> PingAsync()
    {
        try { if (_db == null) return false; await _db.PingAsync(); return true; }
        catch { return false; }
    }
    public async Task BustShopAsync(Guid? shopId)
    {
        try { if (_db != null && shopId.HasValue) await _db.KeyDeleteAsync($"coupon:active:shop:{shopId}"); }
        catch { }
    }
}
