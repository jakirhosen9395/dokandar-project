import * as fs from 'fs';
const E = (k: string, d = '') => process.env[k] ?? d;
const I = (k: string, d: number) => parseInt(process.env[k] || '', 10) || d;
function codeVersion(): string {
  for (const p of ['CODE_VERSION', '/app/CODE_VERSION']) { try { return fs.readFileSync(p, 'utf8').trim(); } catch {} }
  return '0-unknown';
}
export const config = {
  appEnv: E('APP_ENV', 'dev'),
  serviceName: E('SERVICE_NAME', '06-cart'),
  envVersion: E('ENV_VERSION', 'v1.0.0'),
  tenant: E('TENANT', 'local'),
  servicePort: I('SERVICE_PORT', 3000),
  codeVersion: codeVersion(),
  mongoUrl: E('MONGO_URL'),
  mongoDb: E('MONGO_DB', 'dokandar_cart_dev'),
  redisHost: E('REDIS_HOST'),
  redisPort: I('REDIS_PORT', 6379),
  redisPassword: E('REDIS_PASSWORD'),
  redisDb: I('REDIS_DB', 5),
  guestCartTtlDays: I('GUEST_CART_TTL_DAYS', 7),
  idempotencyTtlHours: I('IDEMPOTENCY_TTL_HOURS', 24),
  checkoutLockTtlSeconds: I('CHECKOUT_LOCK_TTL_SECONDS', 5),
  kafkaBootstrap: E('KAFKA_BOOTSTRAP'),
  kafkaGroupPrefix: E('KAFKA_GROUP_PREFIX', 'cart'),
  kafkaTopicProductChanged: E('KAFKA_TOPIC_PRODUCT_CHANGED', 'dokandar.product.changed'),
  kafkaTopicOrderPlaced: E('KAFKA_TOPIC_ORDER_PLACED', 'dokandar.order.placed'),
  mongoLogUri: E('MONGO_LOG_URI'),
  mongoLogDb: E('MONGO_LOG_DB', 'mongo_db_dokandar_application_logs'),
  esUrl: E('ELASTIC_SEARCH_URL'),
  esUser: E('ELASTIC_SEARCH_USERNAME'),
  esPassword: E('ELASTIC_SEARCH_PASSWORD'),
  apmServerUrl: E('APM_SERVER_URL'),
  apmSecretToken: E('APM_SECRET_TOKEN'),
  apmServiceName: E('APM_SERVICE_NAME', '06-cart'),
  jwtPublicKeyB64: E('JWT_PUBLIC_KEY_B64'),
  jwtIssuer: E('JWT_ISSUER', 'dokandar-auth'),
  internalServiceToken: E('INTERNAL_SERVICE_TOKEN'),
  catalogHttpUrl: E('CATALOG_HTTP_URL'),
  couponHttpUrl: E('COUPON_HTTP_URL'),
  riskHttpUrl: E('RISK_HTTP_URL'),
  grpcDeadlineCatalog: I('GRPC_DEADLINE_MS_CATALOG', 2000),
  grpcDeadlineCoupon: I('GRPC_DEADLINE_MS_COUPON', 1000),
  grpcDeadlineRisk: I('GRPC_DEADLINE_MS_RISK', 1000),
  defaultTaxPercent: parseFloat(E('DEFAULT_TAX_PERCENT', '0')) || 0,
  mongoDatabaseUrl: '',
};
// Prisma DATABASE_URL = MONGO_URL with the db name path
(() => {
  const u = config.mongoUrl;
  if (!u) return;
  try {
    const q = u.indexOf('?');
    const base = q >= 0 ? u.slice(0, q) : u;
    const query = q >= 0 ? u.slice(q) : '';
    const withDb = base.replace(/\/?$/, '') + '/' + config.mongoDb;
    config.mongoDatabaseUrl = withDb + query;
  } catch { config.mongoDatabaseUrl = u; }
})();

// Prisma reads DATABASE_URL from the env at client construction
if (config.mongoDatabaseUrl) process.env.DATABASE_URL = config.mongoDatabaseUrl;
