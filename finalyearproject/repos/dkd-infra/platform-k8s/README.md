# DOKANDAR — Production Kubernetes Platform (Phase 4) — DEFERRED

> **This directory is intentionally a placeholder.** The production Kubernetes platform (namespaces, RBAC,
> NetworkPolicies, quotas, secrets strategy, the 6 infra + 4 observability components as Helm charts,
> **ArgoCD**, and **GitOps**) is **deferred** per [ADR-025](../docs/adr/ADR-025-docker-first-dev-execution-order.md).

The DOKANDAR target architecture is **unchanged**: Kubernetes-first, GitOps-managed, production-grade. We are
only changing the **execution order** — building and verifying the business application on the temporary
Docker-Compose substrate in [`../dev-infra/`](../dev-infra/) first.

When the business services are functionally complete in Docker, work resumes here to implement the full
Phase 4 platform. The dev-infra was kept Kubernetes-ready precisely so that step is mechanical
(see [`../dev-infra/MIGRATION.md`](../dev-infra/MIGRATION.md)).

_No manifests are committed here yet — by design._
