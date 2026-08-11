---
id: ADR-025
title: Docker-first development execution order (temporary)
status: Accepted
date: 2026-06-30
supersedes: none
superseded-by: none
relates-to: [ADR-019, ADR-024, Engineering-Execution-Roadmap W0-W7]
---

# ADR-025 — Docker-first development execution order (temporary)

## Status
Accepted — **temporary execution-order change. The target architecture is unchanged.**

## Context
The Engineering Execution Roadmap sequences **Platform Infrastructure (the Kubernetes platform — Phase 4)
before the business application**. In practice, standing up the full production-grade Kubernetes platform
(kind/k8s + ArgoCD + GitOps + the 6 infra + 4 observability components, all running) requires substantially
more compute than the current single development host provides, and — more importantly — it front-loads
operational platform work ahead of validating that the business services actually function.

The reference utilities repository (`learningdevopstools/utilities`) already provides a **Docker-Compose
development substrate** for the same backing services, and its own documentation notes the full fleet does
not fit a single small host.

## Decision
**Postpone the Kubernetes platform (Phase 4) and build/verify the business application first on a Docker /
Docker-Compose development substrate.** Specifically:

1. The backing services (PostgreSQL, Redis, Kafka, RabbitMQ, OpenSearch, RustFS, schema registry, Elastic
   APM observability) are provided as **Docker Compose** under `dkd-infra/dev-infra/`, reusing the utilities
   reference implementation and extending it only for DOKANDAR (shared network, schema registry, bootstrap).
2. Business services are developed and tested against this substrate using the completed Phase 0–3 outputs
   (frozen contracts, platform SDKs, golden service template).
3. **Kubernetes, ArgoCD, GitOps, and the original Phase 4 remain the long-term target.** They are deferred,
   not cancelled.

## Constraints (so the deferral costs nothing later)
Everything in `dev-infra/` is kept **Kubernetes-ready**:
- configuration is **environment variables only** (`.env` → ConfigMap);
- **secrets are a separate file** (`.env.secrets` → Secret), never mixed into config;
- **container images, ports, health endpoints, metrics, and logging are unchanged** between Docker and k8s;
- networking uses **service-DNS names only** (→ Kubernetes Service names);
- persistence uses **named volumes** (→ PersistentVolumeClaims), not host-specific bind mounts;
- no Docker-only assumptions that would complicate the migration.

The repository keeps **`dev-infra/` (temporary, Docker)** strictly separate from **`platform-k8s/` (the
future production Kubernetes platform)**.

## Consequences
- **Positive:** the application can be built and verified immediately on modest hardware; infrastructure is
  reused, not reinvented; the eventual k8s migration is mechanical (documented in `dev-infra/MIGRATION.md`).
- **Negative / risk:** the dev substrate is single-node, non-HA, security-relaxed (e.g. plaintext Kafka,
  OpenSearch security plugin disabled) — acceptable for development only, **never** for production.
- **Exit:** when the business services are functionally complete in Docker, resume the roadmap and build the
  full Kubernetes platform (Phase 4) + ArgoCD + GitOps; this ADR is then superseded.
