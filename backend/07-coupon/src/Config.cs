namespace Coupon;

public static class Config
{
    static string E(string k, string d = "") => Environment.GetEnvironmentVariable(k) ?? d;
    static int I(string k, int d) => int.TryParse(Environment.GetEnvironmentVariable(k), out var v) ? v : d;

    public static readonly string AppEnv = E("APP_ENV", "dev");
    public static readonly string ServiceName = E("SERVICE_NAME", "07-coupon");
    public static readonly string EnvVersion = E("ENV_VERSION", "v1.0.0");
    public static readonly string Tenant = E("TENANT", "local");
    public static readonly int ServicePort = I("SERVICE_PORT", 8080);
    public static readonly int GrpcPort = I("GRPC_PORT", 9090);
    public static readonly string CodeVersion = ReadCode();

    // PostgreSQL (sole writer)
    public static readonly string PgHost = E("POSTGRES_HOST");
    public static readonly int PgPort = I("POSTGRES_PORT", 5432);
    public static readonly string PgUser = E("POSTGRES_USER", "postgres");
    public static readonly string PgPassword = E("POSTGRES_PASSWORD");
    public static readonly string PgDb = E("POSTGRES_DB", "dokandar_coupon_dev");
    public static string PgConn(string? db = null) =>
        $"Host={PgHost};Port={PgPort};Username={PgUser};Password={PgPassword};Database={db ?? PgDb};Pooling=true;Minimum Pool Size=1;Maximum Pool Size=20;Timeout=10";

    // Redis DB6
    public static readonly string RedisHost = E("REDIS_HOST");
    public static readonly int RedisPort = I("REDIS_PORT", 6379);
    public static readonly string RedisPassword = E("REDIS_PASSWORD");
    public static readonly int RedisDb = I("REDIS_DB", 6);

    public static readonly int RedisCacheTtl = I("COUPON_CACHE_TTL_SECONDS", 60);
    public static readonly int RedeemLockTtl = I("REDEEM_LOCK_TTL_SECONDS", 5);

    public static readonly string KafkaBootstrap = E("KAFKA_BOOTSTRAP");
    public static readonly string TopicDrafted = E("KAFKA_TOPIC_COUPON_DRAFTED", "dokandar.coupon.drafted");
    public static readonly string TopicApproved = E("KAFKA_TOPIC_COUPON_APPROVED", "dokandar.coupon.approved");
    public static readonly string TopicRevoked = E("KAFKA_TOPIC_COUPON_REVOKED", "dokandar.coupon.revoked");
    public static readonly double OutboxPollSeconds = double.TryParse(E("OUTBOX_POLL_INTERVAL_SECONDS", "1.0"), out var op) ? op : 1.0;
    public static readonly int OutboxBatch = I("OUTBOX_BATCH_SIZE", 100);

    // log sinks
    public static readonly string MongoLogUri = E("MONGO_LOG_URI");
    public static readonly string MongoLogDb = E("MONGO_LOG_DB", "mongo_db_dokandar_application_logs");
    public static readonly string EsUrl = E("ELASTIC_SEARCH_URL");
    public static readonly string EsUser = E("ELASTIC_SEARCH_USERNAME");
    public static readonly string EsPassword = E("ELASTIC_SEARCH_PASSWORD");

    // APM
    public static readonly string ApmServerUrl = E("APM_SERVER_URL");
    public static readonly string ApmSecretToken = E("APM_SECRET_TOKEN");
    public static readonly string ApmServiceName = E("APM_SERVICE_NAME", "07-coupon");

    // identity (verify-only)
    public static readonly string JwtPublicKeyB64 = E("JWT_PUBLIC_KEY_B64");
    public static readonly string JwtIssuer = E("JWT_ISSUER", "dokandar-auth");
    public static readonly string InternalServiceToken = E("INTERNAL_SERVICE_TOKEN");

    static string ReadCode()
    {
        foreach (var p in new[] { "CODE_VERSION", "/app/CODE_VERSION" })
            try { return File.ReadAllText(p).Trim(); } catch { }
        return "0-unknown";
    }
}
