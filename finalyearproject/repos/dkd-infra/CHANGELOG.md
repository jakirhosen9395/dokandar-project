# Changelog
All notable changes to **dkd-infra** are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning: [SemVer](https://semver.org/).

## [Unreleased]

## [0.3.0] — 2026-06-30
### Added
- **Readiness verifier** `dev-infra/verify.sh` — functional probes for every backing service
  (PG write/read, Redis, Kafka produce→consume, Schema Registry, RabbitMQ, OpenSearch index→search,
  RustFS, APM, and the ADR-026 network isolation); exit-coded.
- **One-command developer setup** — `make dev` / `make all` (secrets + up + bootstrap + verify),
  plus `make verify` / `make bootstrap` / `make obs-up`.
- **Developer onboarding** `dev-infra/ONBOARDING.md` (ports, credentials, service-DNS wiring contract).
- **CI for the Docker dev environment** — `dev-infra:compose-invariants` (validates services +
  ADR-026 isolation + healthchecks via `ci-check.py`), `dev-infra:shellcheck`, `dev-infra:contract-counts`
  (59 topics / 10 queues), running on the self-hosted runner.

Trace: ADR-025, ADR-026, R6

## [0.2.0] — 2026-06-30
### Added
- **Search/observability engine separation, structurally enforced** (ADR-026): business search uses
  **OpenSearch** (`dokandar_dev`); developer observability uses **Elasticsearch** (ELK/APM) on an isolated
  **`dokandar_obs`** network bridged only by APM Server. Verified by execution: a business-plane container
  reaches OpenSearch but **cannot** reach the observability Elasticsearch. Documented in ADR-026, the
  dev-infra README/MIGRATION, and docs/architecture.md. Target architecture unchanged.


## [0.1.1] — 2026-06-30
### Fixed
- `dev-infra` apm-server: removed the duplicated `apm-server` token from the Compose `command:`
  (the image entrypoint already invokes `apm-server`). Verified by execution: apm-server `:8200` -> 200.

Trace: ADR-025

## [0.1.0] — 2026-06-30
### Added
- **Development infrastructure (Docker Compose)** under `dev-infra/` — a temporary, Kubernetes-ready
  local backing-service substrate for building the business application before the production k8s
  platform (ADR-025). Reuses the utilities reference (PostgreSQL 18, Redis 8, Kafka 4.3 KRaft,
  RabbitMQ 4, RustFS) + OpenSearch 2.17 (DOKANDAR search standard) + Apicurio schema registry +
  Elastic APM observability; one shared network, Compose profiles, named volumes (PVC-mappable),
  config/secret separation, and a contract-driven bootstrap (59 Kafka topics, 10 RabbitMQ queues,
  per-context PostgreSQL databases, RustFS buckets).
- `platform-k8s/` placeholder for the deferred production Kubernetes platform (Phase 4).
- ADR-025 — temporary Docker-first development execution order (target architecture unchanged).

Trace: ADR-025, R6, R7, EF§11


## [0.0.0] — 2026-06-29
### Added
- Stage 0.1 repository skeleton and governance baseline (README, architecture notes, CODEOWNERS,
  issue/MR templates, shared governance CI, Conventional-Commits + SemVer scaffolding). No business logic.

Trace: ADR-024, EF§2.3
