/** DEVOPS operational handbook — static content authored from the spec (overview/README.md +
 *  architecture.md) and the in-repo built services. No live internal URLs are embedded. */

export const API_STATS: Record<string, { endpoints: number; base: string }> = {
  "00-support": { endpoints: 8, base: "(root)" },
  "01-auth": { endpoints: 14, base: "/api/v1/auth" },
  "02-profile": { endpoints: 15, base: "/api/v1/profile" },
  "03-seller": { endpoints: 25, base: "/api/v1/shop" },
  "04-catalog": { endpoints: 11, base: "/api/v1/catalog" },
  "05-search": { endpoints: 6, base: "/api/v1/search" },
  "06-cart": { endpoints: 12, base: "/api/v1/cart" },
  "07-coupon": { endpoints: 9, base: "/api/v1/coupon" },
  "08-review": { endpoints: 13, base: "/api/v1/review" },
  "09-payment": { endpoints: 10, base: "/api/v1/payment" },
  "10-wallet": { endpoints: 7, base: "/api/v1/wallet" },
  "11-reporting": { endpoints: 7, base: "/api/v1/reporting" },
  "12-media": { endpoints: 7, base: "/api/v1/media" },
  "13-order": { endpoints: 6, base: "/api/v1/order" },
  "14-notification": { endpoints: 5, base: "/api/v1/notification" },
  "15-api-gateway": { endpoints: 1, base: "/api/v1/bff" },
  "16-recommendation": { endpoints: 4, base: "/api/v1/recommendation" },
  "17-shipping": { endpoints: 7, base: "/api/v1/shipping" },
  "18-risk-trust": { endpoints: 6, base: "/api/v1/risk" },
};
export const TOTAL_ENDPOINTS = 173;

export const REQUEST_FLOW = [
  "Browser issues a same-origin request to the Next.js BFF (never to a service directly).",
  "BFF (/api/gw/[...path]) injects W3C traceparent + x-request-id and the user's Bearer server-side, then forwards to the API Gateway (15) at the private VPC address.",
  "Gateway verifies the RS256 JWT against auth's JWKS, applies rate-limiting + routing, and forwards to the target service over the internal network.",
  "Service authorizes (verify-only RS256; shared INTERNAL_SERVICE_TOKEN for east-west gRPC), executes, returns. Response flows back Service → Gateway → BFF → browser.",
];

export const EVENT_FLOW = [
  "Kafka (transactional outbox, acks=all, keyed by aggregate id): user.*/kyc.* ←01 · shop.* ←03 · product.changed/stock.low ←04 · review.* ←08 · payment.*/refund.processed ←09 · wallet.* ←10 · order.* ←13 · shipment.* ←17 · risk.* ←18.",
  "RabbitMQ command queues (durable, single-consumer, bound DLQ): payout.execute ←09 · notifications.{email,sms,push,whatsapp}+otp.send (01→14) · media.thumbnail/av-scan ←12.",
  "NATS JetStream: 14-notification realtime WebSocket inbox fan-out.",
  "Consumers commit the Kafka offset only AFTER the handler DB tx; UNIQUE idempotency keys make at-least-once effectively-once.",
];

export const SAGA_STEPS = [
  "06-cart builds an immutable quote via 3 gRPC fan-outs: Catalog.CheckStock (fail-closed), Coupon.ValidateCoupon (fail-open), Risk.ScoreCheckout.",
  "POST /order/orders (Idempotency-Key required) enters the Temporal-orchestrated 13-order saga.",
  "Catalog.ReserveStock → Coupon.ValidateCoupon → Wallet.DebitWallet → create payment intent via internal REST to 09-payment; writes one sub-order per shop.",
  "order.placed choreographs notification / wallet-cashback / reporting / search / recs / shipping.",
  "09-payment settles (provider webhook, HMAC-SHA256, replay-fenced) → emits payment.settled → 13-order advances placed→confirmed.",
  "Any activity failure runs Temporal compensations (ReleaseStock, coupon reversal, CreditWallet with a distinct idempotency key) — a partial checkout never leaves money or stock dangling.",
];

export const BOUNDARIES = [
  "Database-per-service: each owns a private Postgres DB dokandar_<svc>_<env> (seller's is dokandar_shop_<env>).",
  "Cross-service references are opaque IDs, never foreign keys — joins happen via Kafka projections or gRPC, never SQL across boundaries.",
  "Strong consistency is reserved for 4 domains: auth tokens, the wallet ledger (SERIALIZABLE double-entry, debit-XOR-credit), the order state machine, payment intents. Everything else tolerates seconds of staleness (Redis-cached Kafka projections).",
  "CQRS split: 04-catalog write model ↔ 05-search read projection. Money is integer paisa; wallet capped 50,000 BDT/user.",
];

export const INFRASTRUCTURE = [
  { name: "PostgreSQL 18", role: "System of record (database-per-service). Primary /ready gate. Self-bootstrapped (ensure_db → migrate) before the listener binds." },
  { name: "Redis 8", role: "Disjoint logical DBs: auth/support 0, profile 1, seller 2, catalog 3, wallet 4, cart 5, coupon 6, order 7, payment 8, notification 10, gateway 13, recommendation 14." },
  { name: "MongoDB 8.3", role: "06-cart + 14-notification document store; application-log forensic sink (TTL needs a real ts_date BSON Date)." },
  { name: "Elasticsearch 9.4", role: "Business search (:9201) for 05-search + 08-review; application logs (:9200 APM-stack) logs-app-<svc>-* for all 18 services." },
  { name: "ClickHouse", role: "11-reporting OLAP analytics + NBR VAT / BTRC DBID exports." },
  { name: "Neo4j", role: "17-shipping courier routing / rural graph." },
  { name: "Qdrant", role: "16-recommendation + 18-risk-trust vector store." },
  { name: "ScyllaDB", role: "18-risk-trust fraud / COD-refusal feature store." },
  { name: "MinIO (S3)", role: "12-media object storage (presigned URLs, AV scan). Community frozen; config-only exit to Garage/RustFS planned." },
  { name: "Kafka 4.x (KRaft)", role: "Domain events — transactional outbox, acks=all, keyed by aggregate id." },
  { name: "RabbitMQ", role: "Command queues — durable, single-consumer, bound DLQ (payouts, notifications, media workers)." },
  { name: "NATS JetStream", role: "14-notification realtime WebSocket inbox fan-out." },
  { name: "Temporal", role: "13-order checkout saga orchestration + compensations." },
];

export const OBSERVABILITY = {
  traces: "Elastic APM is the outermost wrapper in every service; one short service.name is identical across APM, the Mongo log collection, and the ES index (the join key). Browser → BFF → Gateway → Service via W3C traceparent + x-request-id (honour-or-mint).",
  logs: "Two stdout streams (plain access log — /ready+/metrics excluded — + structured JSON app logs) and three sinks (stdout, MongoDB forensic, Elasticsearch logs-app-<svc>-* on the APM-stack :9200). Fire-and-forget over a bounded queue; drops silently on overflow (only log_drops_total signals loss).",
  metrics: "Each service /metrics (Prometheus text — the one non-JSON endpoint): RED + service counters with closed-set labels only (no UUIDs/path-params); every service exposes <svc>_outbox_pending.",
  dashboards: "Kibana (logs + APM) + Grafana/Prometheus (metrics) on the internal ops network — not browser-reachable; deep-linking needs a BFF reverse-proxy (GAP-22).",
  alerting: "Alert on <svc>_outbox_pending growth (relay stalled), log_drops_total > 0 (log loss), /ready flapping, Kafka consumer lag, RabbitMQ DLQ depth, Temporal workflow failures.",
};

export interface Runbook { id: string; title: string; steps: string[] }
export const RUNBOOKS: Runbook[] = [
  { id: "missing-traces", title: "Missing traces", steps: ["RUM ships only when NEXT_PUBLIC_RUM_SERVER_URL is set at BUILD time (client var is baked at build).", "Verify the BFF injects traceparent: `curl -D- /api/gw/...` shows x-request-id.", "Confirm service.name=dokandar-web (+ per-service short names) reach APM.", "Ensure Elastic APM is the OUTERMOST wrapper (JVM/PHP need the bootstrap agent attached)."] },
  { id: "unhealthy-service", title: "Unhealthy service (/ready 503)", steps: ["curl the service /ready — which traffic-gating dep is down? Gate on Postgres always, Redis/S3 only where a request truly needs them.", "Never gate on Kafka/RabbitMQ/Mongo-logs/APM/gRPC peers — those buffer/degrade and must not evict a pod.", "Distroless images need curl/wget present for the HEALTHCHECK.", "Tail stdout + Mongo forensic logs for the failing dep."] },
  { id: "kafka", title: "Kafka failure", steps: ["Kafka 4.x is KRaft-only (no ZooKeeper).", "Producers use a transactional outbox (acks=all): if the relay stalls, <svc>_outbox_pending grows — check the relay (WHERE sent_at IS NULL … FOR UPDATE SKIP LOCKED).", "Consumers commit the offset only AFTER the handler DB tx; a crash re-delivers, UNIQUE idempotency keys dedupe.", "/ready must NOT gate on Kafka."] },
  { id: "rabbitmq", title: "RabbitMQ failure", steps: ["Queues are durable, single-consumer, with a bound DLQ.", "Check DLQ depth for payout.execute / notifications.* / media.*.", "Re-drive DLQ messages after fixing the consumer; idempotency keys make re-drive safe.", "/ready must NOT gate on RabbitMQ."] },
  { id: "database", title: "Database (Postgres) failure", steps: ["Postgres is the system of record and primary /ready gate — a down DB correctly evicts the pod.", "Each service self-bootstraps (ensure_db create-if-missing → migrate) BEFORE the listener binds.", "Never run destructive boot-migrate (db push) — use additive migrations.", "Cross-service joins are forbidden — data comes via Kafka projections / gRPC."] },
  { id: "temporal", title: "Temporal failure", steps: ["13-order checkout saga is Temporal-orchestrated.", "A stuck workflow blocks placed→confirmed — inspect it in the Temporal UI (internal).", "Activity failures auto-run compensations (ReleaseStock, coupon reversal, CreditWallet with a distinct idempotency key).", "Verify the worker is connected and the task queue drains."] },
  { id: "gateway", title: "Gateway failure", steps: ["15-api-gateway is the only edge ingress (JWKS verify, rate-limit, routing, BFF).", "Frontend /ready 503 → curl the gateway /ready; check GATEWAY_URL (private VPC IP, not public) + SG rules.", "A 401 on a fresh token = JWT_PUBLIC_KEY_B64 drift between a verify-only service and auth (the #1 integration bug).", "Restart the frontend container with a corrected env/.env.dev."] },
  { id: "codegen", title: "Codegen failure (pnpm gen:api)", steps: ["curl http://$SPEC_HOST:100NN/openapi.json — reachable? Wrong SPEC_HOST? App service down?", "Re-run; raw specs persist in generated/openapi/raw/.", "Review drift with git diff --stat generated/ before committing.", "Generated .ts clients + MANIFEST are committed; raw specs are gitignored (reproducible)."] },
  { id: "docker", title: "Docker failure", steps: ["Native build (sharp/unrs) blocked → pnpm-workspace.yaml allowBuilds: {sharp,unrs-resolver: true}.", "Standalone missing a module at runtime → .npmrc node-linker=hoisted, rebuild.", "Container unhealthy → docker logs; HEALTHCHECK hits /health via node fetch.", "Image is immutable per service; all config injected at runtime via --env-file (never baked)."] },
];

export const LOCAL_DEV = {
  startupOrder: "auth (01) first — root of the identity DAG (mints the sole RS256 key + INTERNAL_SERVICE_TOKEN). Then profile/seller → commerce → transaction → intelligence.",
  steps: [
    "Render env: cp env/components-creds.example.txt → fill → ./env/init-env.sh .env.dev (auth generates the keypair; verify-only services pull auth's public key).",
    "Snapshot /data: chmod +x data/*/collect.sh && data/<tenant>/collect.sh.",
    "Build & run per the service's commands.md (Docker is the committed path); each container self-bootstraps its DB before binding the listener.",
    "Test: smoke_test/test.sh (curl+jq contract+smoke; exit 0 ⇔ zero FAILs) — mints real RS256 JWTs via auth :10001 + OTP from 00-support :10099.",
  ],
};
