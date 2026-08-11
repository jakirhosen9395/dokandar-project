# DOKANDAR — Development Infrastructure (Docker Compose)

> ⚠️ **Temporary, development-only.** This is **not** the production Kubernetes platform (that is the
> deferred Phase 4 — see [`../platform-k8s/`](../platform-k8s/) and [ADR-025](../docs/adr/ADR-025-docker-first-dev-execution-order.md)).
> It is the local backing-service substrate for building/testing the DOKANDAR business application.

## What runs here

| Service | Image | Profile | Port(s) | Role |
|---|---|---|---|---|
| PostgreSQL | `postgres:18` | core | 5432 | per-context relational store |
| Redis | `redis:8` | core | 6379 | cache |
| Kafka (KRaft) | `apache/kafka:4.3.0` | core | 9092 | R6 event spine |
| Kafka UI | `provectuslabs/kafka-ui` | core | 8081 | topic browser |
| Schema Registry | `apicurio/apicurio-registry-mem` | core | 8082 | R6 Published-Language schemas |
| RabbitMQ | `rabbitmq:4-management` | core | 5672 / 15672 | intra-context queues |
| OpenSearch | `opensearchproject/opensearch:2.17.1` | search | 9200 | business search (DOKANDAR standard) |
| RustFS | `rustfs/rustfs` | storage | 9000 / 9001 | S3 object storage (replaces MinIO) |
| Elastic APM (ES+APM+Kibana) | `docker.elastic.co/...:9.2.0` | observability | 8200 / 5601 | traces/metrics/logs (observability only) |

## Quick start
```bash
cd dev-infra
make secrets                 # generate .env.secrets (gitignored)
make up PROFILE=core         # start the core backing services
make health PROFILE=core     # show container health
make up PROFILE=search       # add OpenSearch when a service needs it
make up PROFILE=storage      # add RustFS
make up PROFILE=observability# add Elastic APM
make down PROFILE=core        # stop (data kept in named volumes)
make purge                    # stop ALL + delete volumes (DESTROYS data)
```
Profiles let a small host run only what a given development step needs (you do not have to run everything
at once).

## Search vs Observability — two isolated engines (ADR-026)

DOKANDAR uses **two different Elasticsearch-family engines for two different purposes — never mix them**:

| Engine | Purpose | Used by | Network | Profile |
|---|---|---|---|---|
| **OpenSearch** | **Business search** (canonical DOKANDAR search platform) | business services | `dokandar_dev` | `search` |
| **Elasticsearch** | **Developer observability only** (ELK/APM: traces/metrics/logs) | APM Server + Kibana | `dokandar_obs` | `observability` |

- **All business search uses OpenSearch.** Business services must **never** use the observability
  Elasticsearch for application search.
- Enforced structurally: the observability Elasticsearch lives on the isolated **`dokandar_obs`** network
  (no host port); only **APM Server** bridges the two planes (services → `apm-server:8200` → Elasticsearch).
  A business container cannot even reach `apm-elasticsearch`. → future Kubernetes **NetworkPolicy**.

## Reuse & extensions
- **Reused** from `learningdevopstools/utilities` (`03_docker_single`): PostgreSQL, Redis, Kafka(+UI),
  RabbitMQ, RustFS service definitions (images, env, healthchecks). Observability reused from
  `jakirhosen9395/elastic-apm-stack`.
- **DOKANDAR extensions:** one shared `dokandar_dev` network, Compose profiles, the Apicurio **schema
  registry** (R6), **OpenSearch** in place of the utilities' Elasticsearch for business search, named
  volumes (PVC-mappable), and `bootstrap/` (topics + databases + buckets).

## Config vs secrets
- `.env` (from `.env.example`) — **configuration only**, committed-safe. → Kubernetes **ConfigMap**.
- `.env.secrets` (from `./gen-secrets.sh`) — **secrets only**, gitignored. → Kubernetes **Secret**.

See [`MIGRATION.md`](./MIGRATION.md) for the dev→Kubernetes mapping.
