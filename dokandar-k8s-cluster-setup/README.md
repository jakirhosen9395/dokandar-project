# DOKANDAR — Kubernetes Cluster Setup (Amazon EKS)

Two halves, applied in this order:

| Folder | What it holds | Secrets? |
|--------|---------------|----------|
| [`jump-server/`](jump-server/README.md) | Per-service `config/` env files + `secrets/` templates, `apply-config.sh`, `apply-secrets.sh`. Run **from the jump server**. | Real values live ONLY here (gitignored) |
| [`manifest-files/`](manifest-files/README.md) | All Kubernetes manifests: 20 workloads (17 backend + gateway + frontend + support), namespaces, NetworkPolicies, ALB Ingresses. | None — no ConfigMap/Secret objects committed |

## Quick start

```bash
# 0. one-time: label/taint the 6 nodes  (see manifest-files/README.md)
kubectl apply -f manifest-files/namespaces/
( cd jump-server && ./apply-config.sh && ./apply-secrets.sh )
kubectl apply -R -f manifest-files/backend/ -f manifest-files/gateway/ \
              -f manifest-files/frontend/ -f manifest-files/support/
kubectl apply -f manifest-files/network/
```

CI/CD injects `<IMAGE_REPOSITORY>:<IMAGE_TAG>` per service before applying.
Open TODOs (hosts, ACM cert ARN, VPC CIDR, secret key reconciliation) are
listed at the end of `manifest-files/README.md`.
