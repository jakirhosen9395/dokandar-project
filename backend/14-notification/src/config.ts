import * as fs from 'fs';
const E = (k: string, d = '') => process.env[k] ?? d;
const I = (k: string, d: number) => parseInt(process.env[k] || '', 10) || d;
const CSV = (k: string): string[] => E(k, '').split(',').map((s) => s.trim()).filter(Boolean);
function codeVersion(): string {
  for (const p of ['CODE_VERSION', '/app/CODE_VERSION']) { try { return fs.readFileSync(p, 'utf8').trim(); } catch {} }
  return '0-unknown';
}
export const config = {
  // identity
  appEnv: E('APP_ENV', 'dev'),
  serviceName: E('SERVICE_NAME', '14-notification'),
  envVersion: E('ENV_VERSION', 'v1.0.0'),
  tenant: E('TENANT', 'local'),
  servicePort: I('SERVICE_PORT', 3000),
  codeVersion: codeVersion(),

  // MongoDB — the inbox store (NOT Postgres; no outbox)  [the only /ready gate]
  mongoUri: E('MONGO_URI'),
  mongoDb: E('MONGO_DB', 'dokandar_notification_dev'),

  // Redis DB 10 — dedup + WS routing (degradable)
  redisHost: E('REDIS_HOST'),
  redisPort: I('REDIS_PORT', 6379),
  redisPassword: E('REDIS_PASSWORD'),
  redisDb: I('REDIS_DB', 10),
  notifDedupTtl: I('NOTIF_DEDUP_TTL_SECONDS', 86400),

  // NATS JetStream — WS fan-out subjects (NOT a durability path)
  natsUrl: E('NATS_URL'),
  natsSubjectPrefix: E('NATS_WS_SUBJECT_PREFIX', 'dokandar.ws.inbox'),

  // Kafka — consume-only (terminal consumer; emits nothing)
  kafkaBootstrap: E('KAFKA_BOOTSTRAP'),
  kafkaGroup: E('KAFKA_GROUP', 'notification'),
  kafkaTopicUserCreated: E('KAFKA_TOPIC_USER_CREATED', 'dokandar.user.created'),
  kafkaTopicOrderPlaced: E('KAFKA_TOPIC_ORDER_PLACED', 'dokandar.order.placed'),
  kafkaTopicPaymentSettled: E('KAFKA_TOPIC_PAYMENT_SETTLED', 'dokandar.payment.settled'),
  kafkaTopicKycApproved: E('KAFKA_TOPIC_KYC_APPROVED', 'dokandar.kyc.approved'),
  kafkaTopicKycRejected: E('KAFKA_TOPIC_KYC_REJECTED', 'dokandar.kyc.rejected'),
  kafkaTopicWalletCashback: E('KAFKA_TOPIC_WALLET_CASHBACK', 'dokandar.wallet.cashback_granted'),

  // RabbitMQ — channel dispatch queues + OTP drain
  rabbitmqUrl: E('RABBITMQ_URL'),
  rabbitmqQueues: CSV('RABBITMQ_QUEUES'),
  rabbitmqQueueOtp: E('RABBITMQ_QUEUE_OTP', 'notifications.otp.send'),
  // OTP DRAIN — gated. In dev/stage, 00-support is the SMS-carrier MOCK that consumes
  // notifications.otp.send and exposes /otp/latest (the OTP-recovery the whole fleet's
  // smokes depend on). 14 draining the SAME queue would be a COMPETING CONSUMER and
  // steal OTPs from 00-support. So 14 only drains OTP in PROD (where it is the real SMS
  // deliverer and 00-support — which refuses to boot outside dev/stage — is absent).
  // Override with OTP_DRAIN_ENABLED=true|false.
  otpDrainEnabled: (() => {
    const v = process.env.OTP_DRAIN_ENABLED;
    if (v !== undefined && v !== '') return v.toLowerCase() === 'true' || v === '1';
    return (process.env.APP_ENV || 'dev') === 'prod';
  })(),

  // External channel providers (injected at runtime, never committed)
  sslWirelessApiKey: E('SSL_WIRELESS_API_KEY'),
  whatsappCloudToken: E('WHATSAPP_CLOUD_TOKEN'),
  fcmServerKey: E('FCM_SERVER_KEY'),
  awsSesRegion: E('AWS_SES_REGION'),

  // Observability — Mongo forensic log sink + APM-stack Elasticsearch (:9200) + APM traces
  mongoLogUri: E('MONGO_LOG_URI'),
  mongoLogDb: E('MONGO_LOG_DB', 'mongo_db_dokandar_application_logs'),
  esUrl: E('ELASTIC_SEARCH_URL'),
  esUser: E('ELASTIC_SEARCH_USERNAME'),
  esPassword: E('ELASTIC_SEARCH_PASSWORD'),
  apmServerUrl: E('APM_SERVER_URL'),
  apmSecretToken: E('APM_SECRET_TOKEN'),
  apmServiceName: E('APM_SERVICE_NAME', '14-notification'),

  // JWT verify-only (auth's PUBLIC key) + east-west internal token
  jwtPublicKeyB64: E('JWT_PUBLIC_KEY_B64'),
  jwtIssuer: E('JWT_ISSUER', 'dokandar-auth'),
  internalServiceToken: E('INTERNAL_SERVICE_TOKEN'),
};
