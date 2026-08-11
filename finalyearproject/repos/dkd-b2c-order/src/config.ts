// 12-factor config from the environment; secrets via env file at deploy time.
export interface Config {
  serviceName: string; context: string; env: string;
  httpPort: number; metricsPort: number; logLevel: string;
  kafkaBrokers: string; rabbitUrl: string; dbDsn: string; otelEndpoint: string; jwtIssuer: string;
  inventoryUrl: string; catalogUrl: string; buildInfoPath: string;
}

function env(k: string, def: string): string {
  const v = process.env[k];
  return v === undefined || v === "" ? def : v;
}

export function load(): Config {
  return {
    serviceName: env("DKD_SERVICE_NAME", "b2c-order-svc"),
    context: env("DKD_CONTEXT", "b2c"),
    env: env("DKD_ENV", "local"),
    httpPort: Number(env("DKD_HTTP_PORT", "8080")),
    metricsPort: 9090,
    logLevel: env("DKD_LOG_LEVEL", "info"),
    kafkaBrokers: env("DKD_KAFKA_BROKERS", "localhost:9092"),
    rabbitUrl: env("DKD_RABBITMQ_URL", ""),
    dbDsn: env("DKD_DB_DSN", ""),
    otelEndpoint: env("DKD_OTEL_ENDPOINT", ""),
    jwtIssuer: env("DKD_JWT_ISSUER", ""),
    inventoryUrl: env("DKD_INVENTORY_URL", "http://172.17.0.1:8094"),
    catalogUrl: env("DKD_CATALOG_URL", "http://172.17.0.1:8088"),
    buildInfoPath: env("DKD_BUILD_INFO_PATH", "/app/build-info.json"),
  };
}

export function validate(c: Config): void { // startup validation — fail fast
  if (!c.serviceName || !c.context) throw new Error("service name and context are required");
  if (!Number.isInteger(c.httpPort) || c.httpPort <= 0) throw new Error(`invalid http port ${c.httpPort}`);
  if (!c.dbDsn) throw new Error("DKD_DB_DSN is required");
}
