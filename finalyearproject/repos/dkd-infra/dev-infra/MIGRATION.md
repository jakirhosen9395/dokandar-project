# dev-infra → Kubernetes migration map

This Docker-Compose substrate is deliberately built so the future production Kubernetes platform (Phase 4)
is a mechanical translation, not a redesign. Nothing here uses a Docker-only assumption that would block k8s.

| Docker-Compose concept (here) | Kubernetes equivalent (Phase 4) |
|---|---|
| `compose.yaml` service | `Deployment`/`StatefulSet` (StatefulSet for stateful: postgres, kafka, opensearch, rustfs) |
| service name on `dokandar_dev` network (`postgres`, `kafka`) | `Service` DNS name (`postgres.<ns>.svc`) — **unchanged hostnames** |
| `.env` (config) | `ConfigMap` |
| `.env.secrets` (secrets) | `Secret` |
| `healthcheck:` | `readinessProbe` / `livenessProbe` (same command/HTTP) |
| named volume (`pg_data`, …) | `PersistentVolumeClaim` |
| published `ports:` | `Service` ports / `Ingress` |
| Compose `profiles` | per-component Helm values / Argo `Application` toggles |
| `apm-server` ingest endpoint | same endpoint, exposed via `Service` |
| two networks (`dokandar_dev` business / `dokandar_obs` observability) | namespaces + **NetworkPolicy** isolating business search (OpenSearch) from observability Elasticsearch (ADR-026) |

What stays **identical** across Docker and k8s (the contract from ADR-025): container **images**, **ports**,
**health endpoints**, **metrics**, **logging format**, and **service hostnames**. Only the orchestration
wrapper changes.

Known dev-only relaxations to harden during the k8s migration: Kafka `PLAINTEXT` (→ SASL/mTLS), OpenSearch
security plugin disabled (→ enabled + TLS), single replicas (→ HA), APM Elasticsearch security off.
