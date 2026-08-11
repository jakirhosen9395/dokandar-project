/**
 * DEVOPS service catalog (static config, sourced from overview/README.md §6 + CLAUDE.md fleet table).
 * No live URLs here — the DEVOPS portal proxies ops endpoints/docs server-side by `id` (never exposes
 * host:port to the browser). `externalRest`/`externalGrpc` are the platform LB ports for reference only.
 */
export interface ServiceEntry {
  id: string;
  name: string;
  description: string;
  language: string;
  framework: string;
  repoPath: string;
  externalRest: number;
  externalGrpc?: number;
  datastores: string[];
  owner: string; // [config placeholder — owners are not declared in the repo]
}

export const SERVICES: ServiceEntry[] = [
  { id: "00-support", name: "Support", description: "Dev/stage 3rd-party + OTP/webhook simulator (refuses prod)", language: "Python 3.14", framework: "FastAPI + Bash", repoPath: "backend/00-support", externalRest: 10099, datastores: ["Redis (ephemeral)"], owner: "platform" },
  { id: "01-auth", name: "Auth", description: "Identity authority: OTP login, RS256 JWT, JWKS, KYC, RBAC — sole key minter", language: "Python 3.14", framework: "FastAPI + SQLAlchemy 2", repoPath: "backend/01-auth", externalRest: 10001, externalGrpc: 20001, datastores: ["PostgreSQL 18", "Redis DB0"], owner: "identity" },
  { id: "02-profile", name: "Profile", description: "Customer profiles + BD address hierarchy", language: "Go 1.26", framework: "chi + pgx", repoPath: "backend/02-profile", externalRest: 10002, externalGrpc: 20002, datastores: ["PostgreSQL 18", "Redis DB1"], owner: "customer" },
  { id: "03-seller", name: "Seller", description: "Shop lifecycle, staff, seller KYC docs", language: "PHP 8.5", framework: "Laravel 13", repoPath: "backend/03-seller", externalRest: 10003, datastores: ["PostgreSQL 18", "Redis DB2"], owner: "seller" },
  { id: "04-catalog", name: "Catalog", description: "Product graph, variants, stock reservation (write model)", language: "Java 25", framework: "Spring Boot 4", repoPath: "backend/04-catalog", externalRest: 10004, externalGrpc: 20004, datastores: ["PostgreSQL 18", "Redis DB3"], owner: "catalog" },
  { id: "05-search", name: "Search", description: "Bilingual search/facets/geo (read projection, consumer-only)", language: "Rust 1.96", framework: "Axum + sqlx", repoPath: "backend/05-search", externalRest: 10005, datastores: ["Elasticsearch 9.4", "PostgreSQL 18"], owner: "discovery" },
  { id: "06-cart", name: "Cart", description: "Carts, wishlist, immutable checkout quote", language: "Node 24", framework: "NestJS 11 + Prisma 6", repoPath: "backend/06-cart", externalRest: 10006, datastores: ["MongoDB 8.3", "Redis DB5"], owner: "commerce" },
  { id: "07-coupon", name: "Coupon", description: "Discount engine, festival campaigns", language: "C# / .NET 10", framework: "ASP.NET Minimal", repoPath: "backend/07-coupon", externalRest: 10007, externalGrpc: 20007, datastores: ["PostgreSQL 18", "Redis DB6"], owner: "commerce" },
  { id: "08-review", name: "Review", description: "Reviews, Q&A, ratings, moderation", language: "Kotlin 2.4", framework: "Ktor 3.5", repoPath: "backend/08-review", externalRest: 10008, externalGrpc: 20008, datastores: ["PostgreSQL 18", "Elasticsearch 9.4"], owner: "commerce" },
  { id: "09-payment", name: "Payment", description: "Payment intents, refunds, payouts, COD ledger", language: "Elixir 1.20", framework: "Phoenix 1.8", repoPath: "backend/09-payment", externalRest: 10009, datastores: ["PostgreSQL 18", "Redis DB8", "RabbitMQ"], owner: "payments" },
  { id: "10-wallet", name: "Wallet", description: "Double-entry ledger, cashback, loyalty", language: "Go 1.26", framework: "Fiber v3 + GORM", repoPath: "backend/10-wallet", externalRest: 10010, externalGrpc: 20010, datastores: ["PostgreSQL 18", "Redis DB4"], owner: "payments" },
  { id: "11-reporting", name: "Reporting", description: "OLAP analytics, NBR VAT / DBID exports (consumer-only)", language: "Python 3.14", framework: "FastAPI + asyncpg", repoPath: "backend/11-reporting", externalRest: 10011, datastores: ["ClickHouse", "PostgreSQL 18"], owner: "data" },
  { id: "12-media", name: "Media", description: "Presigned URLs, AV scan, media lifecycle", language: "Rust 1.96", framework: "Actix Web 4", repoPath: "backend/12-media", externalRest: 10012, externalGrpc: 20012, datastores: ["PostgreSQL 18", "MinIO (S3)"], owner: "platform" },
  { id: "13-order", name: "Order", description: "Checkout saga orchestration (Temporal)", language: "Java 25", framework: "Spring Boot 4 + Temporal", repoPath: "backend/13-order", externalRest: 10013, externalGrpc: 20013, datastores: ["PostgreSQL 18", "Redis DB7"], owner: "commerce" },
  { id: "14-notification", name: "Notification", description: "Multi-channel fan-out + realtime inbox", language: "Node 24", framework: "Fastify 5", repoPath: "backend/14-notification", externalRest: 10014, datastores: ["MongoDB 8.3", "Redis DB10", "RabbitMQ", "NATS"], owner: "platform" },
  { id: "15-api-gateway", name: "API Gateway", description: "Edge ingress: JWKS verify, rate-limit, routing, BFF", language: "Go 1.26", framework: "Echo v5", repoPath: "backend/15-api-gateway", externalRest: 10015, datastores: ["Redis DB13"], owner: "platform" },
  { id: "16-recommendation", name: "Recommendation", description: "Vector recs, cross-sell, cold-start", language: "Python 3.14", framework: "FastAPI + PyTorch", repoPath: "backend/16-recommendation", externalRest: 10016, externalGrpc: 20016, datastores: ["Qdrant", "Redis DB14", "PostgreSQL"], owner: "data" },
  { id: "17-shipping", name: "Shipping", description: "Courier orchestration, rural routing", language: "Ruby 4.0", framework: "Rails 8.1", repoPath: "backend/17-shipping", externalRest: 10017, externalGrpc: 20017, datastores: ["PostgreSQL 18", "Neo4j"], owner: "logistics" },
  { id: "18-risk-trust", name: "Risk & Trust", description: "Fraud / COD-refusal scoring", language: "Python 3.14", framework: "FastAPI + vLLM/sklearn", repoPath: "backend/18-risk-trust", externalRest: 10018, externalGrpc: 20018, datastores: ["ScyllaDB", "Qdrant", "PostgreSQL"], owner: "trust" },
];

/** The six contract endpoints every service exposes (probed via the DEVOPS server-side proxy). */
export const OPS_ENDPOINTS = ["/health", "/ready", "/metrics", "/data", "/docs", "/openapi.json"] as const;

export const DEVOPS_SECTIONS = [
  { slug: "architecture", title: "Architecture", desc: "Service boundaries, event flows, saga workflows, dependency maps" },
  { slug: "catalog", title: "Service Catalog", desc: "All 18 services: language, framework, ports, datastores, env" },
  { slug: "api-explorer", title: "API Explorer", desc: "Per-service Swagger UI (server-proxied) + base path + auth" },
  { slug: "ops-endpoints", title: "Operational Endpoints", desc: "/health /ready /metrics /data /docs /openapi.json status grid" },
  { slug: "infrastructure", title: "Infrastructure", desc: "Kafka topics, RabbitMQ, NATS, Temporal, datastores, object storage" },
  { slug: "observability", title: "Observability", desc: "Kibana, APM, Elasticsearch, logs, metrics, traces, dashboards" },
  { slug: "local-dev", title: "Local Development", desc: "Startup order, docker commands, seed data, smoke tests" },
  { slug: "runbooks", title: "Runbooks", desc: "Kafka/DB/trace/health/Temporal failure recovery" },
  { slug: "docs", title: "Documentation", desc: "Render overview/*.md with TOC + search" },
] as const;
