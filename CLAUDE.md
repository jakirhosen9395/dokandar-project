# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this workspace is

DOKANDAR — a learning/portfolio e-commerce marketplace platform (Bangladesh market: bn/en, phone-OTP auth, COD-heavy). This directory is **not itself a git repo**; it is a workspace of independent GitLab repos under `gitlab.com/learningdevopstools/`:

- `backend/NN-<name>/` — 18 microservices + 1 dev helper (`00-support`), **all implemented**, each its own git repo on the **`source-code` branch** (`main` is a placeholder README). Deliberately polyglot — one stack per service (see table below).
- `ui/frontend/` — Next.js 16 frontend + BFF (branch `source-code`). All 8 phases complete.
- `utilities/utilities/` — orchestrator scripts that stand up the 16 backing-infrastructure tools and print all credentials.
- `infra/01-vpn-setup/` — OpenVPN via Terraform + Ansible (flattened terraform/ + ansible/; GitLab repo name is still `openvpn-cloud-lab`). 02-platform-setup **reuses** its Ansible playbook and writes an inventory into it.
- `infra/02-platform-setup/` — Terraform + Ansible for the platform pair: GitLab runner (public subnet, IAM ECR-push) + utilities host (private subnet, NAT). Consumes 01-vpn-setup's VPC via terraform_remote_state; `ansible/deploy.yml` provisions both hosts **in parallel** (strategy: free) and triggers all pipelines with the PAT (branch `main`; GitLab repo name is still `dokandar-platform`).
- `infra/03-eks-setup/` — **implemented** private-only EKS: Terraform (2 × m7i-flex.xlarge workers + 1 t3.small jump server, all in private subnets; only the EKS API endpoint is public so `kubectl` works without the VPN) + `ansible/setup.yml` (add-ons: ALB controller, metrics-server, Reloader, ArgoCD; renders envs from utilities creds → jump-server secrets; `--tags deploy` does the first rollout, then ArgoCD owns it). K8s manifests + jump-server secret flow live in the separate repo `infra/dokandar-k8s-cluster-setup` (local checkout: `dokandar-k8s-cluster-setup/` at workspace root — `manifest-files/` 20 workloads + namespaces + NetworkPolicies + internal ALB ingresses, no secrets committed; `jump-server/` gitignored real config/secrets + apply scripts run from the jump server; `argocd/dokandar-platform-app.yaml`).

**CI/CD is GitOps**: every service repo and the frontend has a `.gitlab-ci.yml` with build → push to ECR → `update_manifest` (clones `dokandar-k8s-cluster-setup` with `MANIFEST_PUSH_TOKEN` and bumps that service's deployment image tag) — ArgoCD then syncs the cluster. Shell runner tagged `dokandar-runner`; ECR auth via runner instance-profile IAM, no AWS keys in CI variables. The old EC2 deploy-via-SSM stage is gone.

Root files: `instruction.md` (complete user/platform guide + current deployment IPs — source of truth for endpoints), `backend/commands.md` (19-service deploy runbook), `backend/all_components_creds.txt` (central creds file, never commit), `.gitlab_token` (PAT read by Ansible), `infra/site.yml` (one-command full-platform rollout), `infra/commands.md` (master runbook: prerequisites + manual per-stage equivalents).

## Service map (REST `:100NN` / gRPC `:200NN` on the app host)

| NN | Service | Stack | NN | Service | Stack |
|----|---------|-------|----|---------|-------|
| 00 | support (dev helper, :10099) | Python/FastAPI | 10 | wallet | Go/Fiber+GORM |
| 01 | auth | Python/FastAPI | 11 | reporting | Python (ClickHouse) |
| 02 | profile | Go/chi | 12 | media | Rust (RustFS/S3, Neo4j) |
| 03 | seller/shop | PHP/Laravel | 13 | order | Java/Spring (Temporal saga) |
| 04 | catalog | Java/Spring Boot | 14 | notification | Node (RabbitMQ) |
| 05 | search | Rust/Axum (ES :9201) | 15 | api-gateway | Go/Echo (the single edge, :10015) |
| 06 | cart | Node/NestJS+Prisma | 16 | recommendation | Python (Qdrant) |
| 07 | coupon | C#/.NET | 17 | shipping | Ruby/Rails |
| 08 | review | Kotlin/Ktor | 18 | risk-trust | Python (Neo4j, ClickHouse) |
| 09 | payment | Elixir/Phoenix | | | |

Each service uses an exclusive Redis DB number; migration tooling varies per language (Alembic / golang-migrate / etc.).

## Platform invariants (apply to every service)

- Single edge: `15-api-gateway`. Browser → Next.js BFF → gateway → services; east-west is gRPC + `INTERNAL_SERVICE_TOKEN`.
- 5-endpoint ops contract everywhere: `/ready`, `/health`, `/data`, `/metrics`, `/docs` + `/openapi.json`.
- Error envelope: `{error: {code, message, request_id, details}}` with snake_case codes.
- Money is **integer paisa**. Content is bn/en UTF-8.
- Two Elasticsearch clusters: `:9200` APM/logs, `:9201` business search (05-search, 08-review) — don't mix them.
- `01-auth` is the sole holder of the RS256 private key; everyone else verifies with `JWT_PUBLIC_KEY_B64`. Roles: `customer, shopkeeper, shop_staff, platform_staff, admin`.
- In-container ports are `8000` (REST) / `8001` (gRPC) regardless of the spec's 50051; host mapping is `100NN`/`200NN`.

## Per-service workflow (uniform across all 19)

Every service has the same skeleton: `architecture.md` (full spec), `README.md` (native setup), `commands.md` (Docker walkthrough), `CODE_VERSION`, `Dockerfile`, `env/`, `data/cloud/collect.sh`, `smoke_test/test.sh`, `migrations/`, `proto/`.

```bash
cd backend/NN-name
cp env/components-creds.example.txt env/components-creds.txt   # paste real infra creds (### NN_Block format)
./env/init-env.sh .env.dev            # renders gitignored env/.env.dev (auth also mints RS256 keypair + internal token)
./data/cloud/collect.sh               # EC2/machine metadata → data/cloud/result.json (served by /data)

docker build -t dokandar_<name>_service:dev .
docker run -d --name dokandar_<name>_service_dev --env-file env/.env.dev \
  -e TENANT=cloud -v "$(pwd)/data:/app/data:ro" -p 100NN:8000 -p 200NN:8001 \
  --restart=on-failure:3 dokandar_<name>_service:dev

# Test: full contract smoke test against a running instance (every endpoint,
# status-code assertions; recovers dev OTP from container logs / 00-support).
AUTH_URL=http://127.0.0.1:100NN ./smoke_test/test.sh   # env var name varies; see smoke_test/test_command.md
```

01-auth specifics: deps are PINNED (`fastapi 0.115.6` / `starlette 0.41.3` — elastic-apm breaks on starlette ≥0.42; do not loosen); `APP_ENV=dev python -m app.lifecycle.ensure_db` creates the DB + runs alembic (idempotent; the Docker entrypoint does it itself); `app/` splits into `api/ domain/ db/ grpc/ messaging/` (transactional outbox) `observability/ lifecycle/ storage/`.

**Fleet deploy order** (`backend/commands.md`): fill infra blocks in `all_components_creds.txt` → deploy **01-auth first** → copy its `JWT_PUBLIC_KEY_B64` + `INTERNAL_SERVICE_TOKEN` from `01-auth/env/.env.dev` into the `### Auth_Identity` block → distribute the file to every service's `env/components-creds.txt` → render/build/run the rest → verify `curl :100NN/ready` per service.

## ui/frontend (Next.js 16 / React 19 / TS / Tailwind 4 / pnpm)

Docs: `FRONTEND_ARCHITECTURE.md` (source of truth), `GAP_REGISTER.md` (22 backend-gap mitigations), `COMMAND.md` (full runbook), `commands.md` (deploy quickstart), `docs/adr/`.

```bash
cd ui/frontend
cp .env.example .env.local
pnpm install
pnpm gen:api        # fetch 19 service OpenAPI specs from SPEC_HOST:100NN → generated/ (typed clients)
pnpm dev            # :3000
pnpm build && pnpm start
pnpm lint           # ESLint (no test suite configured)
```

- `generated/` is committed and **read-only** — re-run `pnpm gen:api` when a backend API changes; never hand-edit. The gateway does not expose specs; `/ready` checks `generated/openapi/MANIFEST.json` against the gateway.
- Env model: `GATEWAY_URL`, `SPEC_HOST`, `SESSION_COOKIE_SECRET` are server-only, read at **runtime**; `NEXT_PUBLIC_*` are inlined at **build time**.
- BFF pattern: browser calls go through `/api/gw/[...path]` (single proxy: request-id + traceparent minting) and `/api/auth/*`; session = encrypted httpOnly cookie (jose JWE, BFF-owned refresh); access token in-memory only; `middleware.ts` enforces route RBAC (`/admin`, `/devops`, `/seller`, `/account`).
- State split: TanStack Query for server reads (RSC/SSR initial), Zustand narrow (UI state, access token, guest cart), RHF + Zod for write forms.
- Docker: multi-stage Node 22-alpine, standalone output, non-root, healthcheck `/health`; build args `CODE_VERSION/BUILD_TIME/GIT_COMMIT`.

## utilities/utilities (backing infra, 16 tools)

```bash
bash setup.sh                   # all 16 tools on one host (03_docker_single default)
bash setup.sh creds             # print every credential + endpoint
bash setup.sh status | down | purge    # down preserves data; purge deletes it
# Two-host split: 01_utility_setup.sh (Server A, 6 tools) / 02_utility_setup.sh (Server B, 10 tools)
```

Server A: PostgreSQL, Redis, Elastic APM (ES :9200 + Kibana), Prometheus, ClickHouse, ScyllaDB. Server B: MongoDB (pinned 7.0), Elasticsearch :9201, Kafka, RabbitMQ, OpenBao, RustFS (:9002), Qdrant, Neo4j, NATS, Temporal. Each tool dir has variants `01_native_single` / `03_docker_single` / `04_docker_cluster` (RAM guardrail; `UTIL_FORCE=1` overrides), idempotent `setup.sh` (auto-generates secrets into gitignored `.env`), `README.md`, `test.sh`. Env knobs: `UTIL_SKIP` (default `"prometheus openbao"`), `UTIL_ONLY`, `UTIL_SLEEP`, `DATA_ROOT`.

## infra rollout (3 stages)

One command stands up everything (each stage idempotent and re-runnable alone):

```bash
cd infra
ansible-playbook site.yml -K            # -K = sudo once (starts the OpenVPN client daemon)
ansible-playbook site.yml -K --tags vpn|platform|eks    # re-run a single stage
```

Order matters: **01 (vpn) → VPN up → 02 (platform) → 03 (eks)** — private hosts answer only over the tunnel; the runner is the single public machine. Terraform state for all three stages lives in an **S3 backend** (`use_lockfile`, region `ap-southeast-1`); 02/03 read 01's VPC via `terraform_remote_state` from S3. Local `terraform.tfstate` files in the repos are empty leftovers — don't trust them. Manual per-stage commands (for learning/debugging): `infra/commands.md`.

- Stage 2 `deploy.yml` play 2 uses `strategy: free`: the utilities host installs Docker + the 16-tool data tier while the runner host installs/registers the GitLab runner, then (delegated to the control node) triggers every service pipeline with the PAT. Partials: `utilities.yml`, `runner.yml`.
- Stage 3: `terraform apply` (~15 min) → `ansible-playbook setup.yml` (add-ons + envs + secrets) → `setup.yml --tags deploy` (first rollout; ArgoCD owns it afterwards). **Teardown order matters**: `kubectl delete ingress -A --all` first (k8s-created ALBs are in no tf state), then `terraform destroy`.

Day-2 is fully automatic: git push → CI → ECR → manifest bump in `dokandar-k8s-cluster-setup` → ArgoCD sync.

## Current deployment endpoints (EKS, VPN required)

Service NN → `http://<node-ip>:300NN` (NodePort mirrors the old `100NN` convention; same 5-endpoint contract + `/docs`). Frontend `:30020`, ArgoCD `:30080`. Discover live URLs with `infra/03-eks-setup/service-urls.sh` and `argocd-info.sh`; jump-server SSH via `terraform output jump_ssh_command` (key in `03-eks-setup/keys/`). `instruction.md` still documents the older EC2-era endpoints/IPs — treat it as the user-facing platform guide, not as the current endpoint source.

## Git conventions here

- Run git commands **inside** the specific sub-repo, not at this workspace root.
- Backend + frontend repos: work against the `source-code` branch, not `main`; `dokandar-platform` uses `main`.
- Conventional commits (feat:, fix:, chore:, docs:).
- Never commit: `env/components-creds.txt`, `env/.env.*`, `all_components_creds.txt`, `.gitlab_token`, `*.pem`.
