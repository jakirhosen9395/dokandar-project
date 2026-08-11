# DOKANDAR — Developer Onboarding (Docker dev infrastructure)

Get the full local backing-service substrate running in a few minutes. This is the **temporary,
Kubernetes-ready development infrastructure** (ADR-025) — not the production k8s platform.

## Prerequisites
- Docker Engine + Docker Compose v2 (`docker compose version`)
- `make`, `curl`, `python3`
- For RustFS checks: the MinIO client `mc` on `PATH` (or `$HOME/bin/mc`)
- ~6 GB RAM for `core+search+storage`; the observability profile needs ~2 GB more (run it on demand)

## One command
```bash
cd dkd-infra/dev-infra
make dev        # secrets + core+search+storage up + bootstrap + verify
```
`make dev` generates secrets, starts the substrate, creates the 59 Kafka topics / 10 RabbitMQ queues /
13 per-context PostgreSQL databases / RustFS buckets, then runs functional readiness checks.

To include observability (Elastic APM) as well: `make all`. To stop it again: `make obs-down`.

## What you get (service → host port)
| Service | Host port | Connect as (from another container) | Credentials |
|---|---|---|---|
| PostgreSQL 18 | 5432 | `postgres:5432` | `.env` user / `.env.secrets` password; DBs `dkd_<context>` |
| Redis 8 | 6379 | `redis:6379` | password in `.env.secrets` |
| Kafka 4.3 | 9092 (host) | `kafka:29092` (in-network) | PLAINTEXT |
| Kafka UI | 8081 | — | — |
| Schema Registry | 8082 | `schema-registry:8080` | — |
| RabbitMQ | 5672 / 15672 | `dokandar-rabbit:5672` | `.env` user / `.env.secrets` password |
| **OpenSearch** (business search) | 9200 | `opensearch:9200` | none (dev) |
| RustFS (S3) | 9000 / 9001 | `rustfs:9000` | access/secret in `.env.secrets` |
| Elastic APM (observability) | 8200 / 5601 | `apm-server:8200` | secret token in `.env.secrets` |

> **Search vs observability (ADR-026):** business services use **OpenSearch** for search. The Elastic
> APM Elasticsearch is for developer observability only and lives on an isolated network — business
> services cannot reach it. Send traces to `apm-server:8200`, never to the observability Elasticsearch.

## Wiring a business service to the substrate
Run your service container on the **`dokandar_dev`** network and configure it via env (the same vars
become a Kubernetes ConfigMap/Secret later):
```
DKD_DB_DSN=postgres://<user>:<pw>@postgres:5432/dkd_<context>?sslmode=disable
DKD_KAFKA_BROKERS=kafka:29092
DKD_RABBITMQ_URL=amqp://<user>:<pw>@dokandar-rabbit:5672/
DKD_REDIS_URL=redis://:<pw>@redis:6379
DKD_OPENSEARCH_URL=http://opensearch:9200
DKD_OBJECT_STORE_ENDPOINT=http://rustfs:9000
DKD_SCHEMA_REGISTRY_URL=http://schema-registry:8080/apis/registry/v2
DKD_APM_SERVER_URL=http://apm-server:8200
```
Use **service-DNS hostnames only** (never container IPs or host paths) so the move to Kubernetes
Services is mechanical — see `MIGRATION.md`.

## Everyday commands
```bash
make verify        # functional readiness check (use before/after coding)
make health        # container health summary
make logs SVC=kafka
make down          # stop core (data kept in named volumes)
make purge         # stop everything + DELETE all data
```

## Secrets
`make secrets` writes `dev-infra/.env.secrets` (gitignored, chmod 600) with random credentials.
Config lives in `.env` (committed-safe). Never commit `.env` or `.env.secrets`.
