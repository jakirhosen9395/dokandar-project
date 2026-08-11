# `12-media` — Object Lifecycle

> **Status — specified, NOT yet implemented.** This folder is a **scaffold**: the service code
> (`Dockerfile`, `env/`, `test.sh`, application source) does **not** exist yet. The authoritative spec is
> [`../README.md`](../README.md) (the catalog) + [`../../README.md`](../../README.md) §6/§7/§10 +
> [`../../architecture.md`](../../architecture.md) §9. **On any conflict, the README wins — re-verify.**

## Identity

| Field | Value |
| --- | --- |
| Service | `12-media` |
| Domain | Fulfilment, Engagement, Media & Edge |
| Language · framework | Rust 1.96 · Actix Web 4 |
| Primary datastore(s) | PostgreSQL 18 + MinIO (S3) ² (+ Redis DB12) |
| `SERVICE_PORT` (in-container) | 8080 |
| gRPC port | 50051 |
| External ports | REST `10012` · gRPC `20012` |
| **`/ready` hard-gate** | **PostgreSQL + MinIO/S3** (cannot presign without the object store); never Kafka/RabbitMQ |

## Bounded context

The fleet's binary custodian: it never streams bytes through its own process but brokers **presigned S3 upload/download URLs** for every object class — product images, shop logos, avatars, review photos, proof-of-delivery, and sensitive KYC docs. Owns a lifecycle state machine (`pending → uploaded → scanned → ready → quarantined → deleted`); KYC-doc reads are **admin-only**.

## Data ownership

PostgreSQL `dokandar_media_<env>`: `media_objects` (`object_key` UNIQUE, sha256, owner, `state`, `class`), `media_derivatives`, `media_grants`, `outbox`. Bytes live in MinIO bucket `dokandar-media-<env>` (aws-sdk-v2 S3, path-style). ² *(`12-media` targets the S3 API — backend is MinIO in prod, **RustFS** in the dev/stage utility layer; swap is config-only.)*

## Synchronous API

- **REST:** `/api/v1/media/…`: `POST /upload-url`, `POST /{id}/complete`, `GET /{id}/signed-url`
- **gRPC exposed:** `Media.IssueUploadURL|MarkUploaded|GetSignedURL|GetMedia` @50051
- **gRPC called:** `Auth.GetUserKyc` @50051 (authorize KYC-doc access)

## Events & queues

- **Emits (Kafka):** `dokandar.media.uploaded|deleted`
- **Consumes (Kafka):** none (leaf of the asset DAG)
- **RabbitMQ / NATS:** RabbitMQ → `media.thumbnail` (derivatives), `media.av-scan` (KYC malware scan gating `scanned→ready`), each with a DLQ

## Operational notes

- **Idempotency:** `object_key` UNIQUE + deterministic key derivation make repeated `IssueUploadURL` converge; `complete` idempotent against current `state`.
- **Resilience:** AV-scan failure holds objects in `quarantined`; **S3 outage fails `/ready`** (presign impossible).
- **Security:** KYC docs require an admin grant + AV-scan-passed `ready`; presigned URLs short-TTL + grant-gated; constant-time via the Rust `subtle` crate.

Plus the **universal contract** (all 18): the five endpoints (`/ready`, `/health`, `/data`, `/docs`,
`/metrics`) byte-identical with the identity block; verify-only RS256 + constant-time
`INTERNAL_SERVICE_TOKEN`; transactional outbox; MongoDB + Elasticsearch log sinks + Elastic APM +
Prometheus (non-gating). Full contract: [`../../README.md`](../../README.md) §13–§14 and
[`../../architecture.md`](../../architecture.md) §10.

## Build checklist (when this service is implemented — none of it exists yet)

- [ ] `Dockerfile` — multi-stage distroless/slim, non-root **uid 10001**, `HEALTHCHECK → GET /ready`, `EXPOSE` the idiomatic `SERVICE_PORT` (+ gRPC `50051`/`9090`)
- [ ] `env/init-env.sh` + `.env.<dev|stage|prod>` (12-factor; **fail-fast** on empty `JWT_PUBLIC_KEY_B64` / `INTERNAL_SERVICE_TOKEN` / `SERVICE_NAME` under stage/prod)
- [ ] the **five endpoints** with the byte-identical identity block + the `X-Request-Id`-correlated error envelope
- [ ] `test.sh` — contract smoke test that curls all five endpoints
- [ ] `data/<tenant>/result.json` — the `/data` snapshot (bind-mounted read-only at `/app/data`)
- [ ] per-service docs: `OPERATIONS.md`, `ARCHITECTURE.md`, `BUSINESS_LOGIC.md`, `SECURITY.md`, `docs/adr/`

## See also

- [`../README.md`](../README.md) — the 18-service catalog (identity, ports, the per-service infra matrix).
- [`../../architecture.md`](../../architecture.md) — **§9** this service in full detail; **§21** the event + gRPC cross-service anchor.
- [`../../utility/`](../../utility/README.md) — the backing infrastructure this service connects to (+ its connectivity matrix).
