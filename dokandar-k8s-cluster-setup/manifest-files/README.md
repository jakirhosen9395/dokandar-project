# DOKANDAR — Kubernetes Manifests (Amazon EKS)

Production manifest set for the DOKANDAR platform (18 backend services + 1 dev
helper + API gateway + Next.js frontend), adapted from the conventions of
`firsttrip-k8s-cluster-deployment-prod` (labels, `<svc>-config`/`<svc>-secret`
envFrom pairs, stakater Reloader annotations, ALB annotation family,
podAntiAffinity, probe timings, per-service folders).

## Layout

```
manifest-files/
├── namespaces/          # gateway, frontend, backend, support
├── network/             # default-deny + explicit allow NetworkPolicies
├── gateway/15-api-gateway/
├── frontend/frontend/
├── support/00-support/
└── backend/NN-<service>/         # 17 services
```

Reference-repo style: **two files per service**, multi-document YAML:

- `<svc>-deployment.yaml` — ServiceAccount → ConfigMap → Deployment → HPA → PDB
  (dependency order; safe to apply top-to-bottom)
- `<svc>-service.yaml` — Service (+ ALB Ingress for the 3 public entry points:
  api-gateway, frontend, support)

**No ConfigMap or Secret objects live here.** Both are created from the jump
server (`../jump-server/apply-config.sh` + `apply-secrets.sh`) BEFORE these
manifests are applied; every Deployment references its `<service>-config` and
`<service>-secret` via `envFrom`.

## Cluster prerequisites (one-time)

1. **Node pools** — 6 nodes, labeled and (private only) tainted:

```bash
# 2 public nodes for gateway + ingress
kubectl label node <n1> <n2> dokandar.io/node-pool=gateway
# 2 public nodes for frontend + support
kubectl label node <n3> <n4> dokandar.io/node-pool=frontend
# 2 private nodes for all backend services
kubectl label node <n5> <n6> dokandar.io/node-pool=backend
kubectl taint node <n5> <n6> dokandar.io/tier=private:NoSchedule
```

(With managed node groups, set these as node-group labels/taints in Terraform
instead.)

2. **Controllers**: AWS Load Balancer Controller (for `ingressClassName: alb`),
   metrics-server (required by the HPAs), stakater Reloader (optional but
   assumed by the reload annotations).

## Apply order

```bash
kubectl apply -f namespaces/
( cd ../jump-server && ./apply-config.sh && ./apply-secrets.sh )   # config + secrets FIRST
kubectl apply -R -f backend/ -f gateway/ -f frontend/ -f support/
kubectl apply -f network/
```

## Secrets & config contract

- **No secrets are committed anywhere.** Real values live only in
  `../jump-server/secrets/*.env` (gitignored) and are applied by
  `../jump-server/apply-secrets.sh` (same credential flow as the platform's
  `all_components_creds.txt` → `env/init-env.sh` rendering).
- `<IMAGE_REPOSITORY>:<IMAGE_TAG>` in every Deployment is replaced by CI with
  the ECR image (e.g. `<ACCOUNT>.dkr.ecr.ap-southeast-1.amazonaws.com/dokandar/01-auth:<sha>`).
- Databases and message brokers are **outside** the cluster; backend egress is
  intentionally unrestricted (ingress is default-deny + explicit allows).

## Traffic model

Internet → shared ALB (`alb.ingress.kubernetes.io/group.name: dokandar-prod`)
→ `frontend` (Next.js BFF, :3000) → `gateway/dokandar-api-gateway` (:8000)
→ `backend/*` services (REST :8000, gRPC :8001, east-west inside `backend`).
Only the gateway namespace may call backend services (NetworkPolicy-enforced);
`00-support` additionally may (webhook simulation, dev helper).

## TODO before first apply

- [ ] Hostnames: `api.dokandar.example.com`, `shop.dokandar.example.com`,
      `support.dokandar.example.com` → real DNS.
- [ ] `<TLS_CERTIFICATE_ARN>` in all 3 Ingresses → ACM cert.
- [ ] `10.0.0.0/16` in `network/1*-allow-alb.yaml` → actual VPC CIDR.
- [ ] `<OFFICE_CIDR>` on the support Ingress (or delete that Ingress in prod).
- [ ] Secret key lists: reconcile each `../jump-server/secrets/<NN-svc>/*.env.example` with the service's
      `env/init-env.sh` output (marked TODO per file).
- [ ] Gateway ConfigMap: align `*_SERVICE_URL` var names with 15-api-gateway's
      actual env contract.
- [ ] `imagePullSecrets`: remove if ECR is pulled via the node IAM role
      (default on EKS).
- [ ] `/data` endpoint: services serve `data/cloud/result.json` collected on
      EC2; on EKS this mount is absent — verify services tolerate a missing
      `/app/data` or ship a ConfigMap-based equivalent.
- [ ] `runAsNonRoot` is set only for the frontend (image user known: 1001);
      audit each backend image's user before enforcing cluster-wide.
