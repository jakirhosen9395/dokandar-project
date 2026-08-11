# `01-auth` — DOKANDAR Identity & Auth Service

Python 3.14 · FastAPI · PostgreSQL · Redis · Kafka · RabbitMQ · MongoDB · Elasticsearch · Elastic APM · RustFS(S3).
RS256-JWT identity authority: phone-OTP login, JWKS, KYC tiers, RBAC, the five operational endpoints, a
transactional outbox, three log sinks, and an east-west gRPC server.

- **Design doc:** [`architecture.md`](./architecture.md) (full spec — read for *how it works*).
- **This README:** copy-paste **native** install (no Docker). Docker path: [`SETUP-DOCKER.md`](./SETUP-DOCKER.md).

> **Verified deploy.** Natively deployed + acceptance-passed on Ubuntu 26.04 / Python 3.14.4 against the live
> components host — `/health` healthy with all 7 deps `ok` (postgres, redis, kafka, rabbitmq, mongo_logs, apm,
> s3_kyc); signup → RS256 JWT works end-to-end.

---

## 0. What you need

- A Linux host (Ubuntu 24.04/26.04 tested) with **Python 3.12+** (3.14 used here) and `sudo`.
- Network reachability to the **components host** (PostgreSQL / MongoDB / Elasticsearch / Redis / Kafka /
  RabbitMQ / Elastic-APM / RustFS) — private IP if same-VPC, else its public IP.
- The infra credentials (the `### NN_Service` status dump) to paste into `env/env.txt`.

---

## 1. Install OS prerequisites

```bash
sudo apt-get update
sudo apt-get install -y python3-venv python3-pip build-essential libpq-dev \
  libssl-dev libffi-dev librdkafka-dev openssl curl jq ca-certificates git rsync
```

*(`librdkafka-dev` is for `confluent-kafka`; `libpq-dev` for Postgres; `openssl` for the JWT keypair.)*

---

## 2. Get the code

```bash
sudo mkdir -p /opt/dokandar && sudo chown -R "$USER":"$USER" /opt/dokandar
git clone -b source-code git@gitlab.com:learningdevopstools/backend/01-auth.git /opt/dokandar/01-auth
cd /opt/dokandar/01-auth
```

---

## 3. Create the venv + install dependencies

```bash
python3 -m venv .venv
source .venv/bin/activate          # keep this shell ACTIVATED through step 5
pip install -U pip wheel
pip install -e .
```

All C-extension deps (grpcio, confluent-kafka, asyncpg, …) install from binary wheels on Python 3.12–3.14.
The `fastapi`/`starlette`/`prometheus-fastapi-instrumentator` versions are **pinned** in `pyproject.toml`
(elastic-apm needs Starlette `<0.42`) — don't loosen them.

---

## 4. Paste the infra creds → render `env/.env.dev`

```bash
cp env/env.txt.example env/env.txt
nano env/env.txt        # paste the REAL infra creds (the ### NN_Service blocks)
chmod 600 env/env.txt
./env/init-env.sh .env.dev
```

`init-env.sh` parses `env/env.txt`, generates a **fresh RS256 JWT keypair + `INTERNAL_SERVICE_TOKEN`** (auth is
the sole holder of the private key), and writes `env/.env.dev` (`chmod 600`, **gitignored — never commit**).
It wires: Postgres → `dokandar_auth_dev`, Redis DB 0, the live Kafka broker, RabbitMQ, the Mongo log collection
`mongo_db_dokandar_application_logs.01-auth`, the **`:9201`** Elasticsearch log sink (not the APM ES), the APM
ingest `:8200` + bearer, and RustFS `:9002` for KYC docs. Re-run anytime to rotate the keypair.

> Render a staging/prod env the same way: `./env/init-env.sh .env.prod` (TENANT becomes `cloud`).

---

## 5. Bootstrap the database

> Keep the venv **activated** — `ensure_db` shells out to `alembic`, which must be on `PATH`.

```bash
APP_ENV=dev python -m app.lifecycle.ensure_db
```

This connects to the admin DB, `CREATE DATABASE dokandar_auth_dev` if missing, runs `alembic upgrade head`
(`users` / `refresh_tokens` / `kyc_submissions` / `outbox` / enums), and ensures the `dokandar-kyc-dev` RustFS
bucket. Idempotent — safe to re-run.

---

## 6. Run the service

### 6a. Foreground (quick test)

```bash
APP_ENV=dev uvicorn app.main:app --host 0.0.0.0 --port 8000
```

Starts FastAPI on `:8000`, the gRPC `Auth` server on `:8001`, the outbox relay (every 2 s), the Mongo + ES log
sinks, and the seed-admin step.

### 6b. systemd (persistent, recommended)

```bash
sudo tee /etc/systemd/system/dokandar-auth.service >/dev/null <<UNIT
[Unit]
Description=DOKANDAR 01-auth (native uvicorn)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=/opt/dokandar/01-auth
Environment=APP_ENV=dev
ExecStart=/opt/dokandar/01-auth/.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now dokandar-auth
sudo systemctl status dokandar-auth --no-pager
```

The app reads `env/.env.dev` itself (via `APP_ENV` + `WorkingDirectory`), so no `EnvironmentFile` is needed.

---

## 6c. Docker — alternative to steps 5–6 (no venv, no systemd)

Prereq: Docker (`curl -fsSL https://get.docker.com | sudo sh`). You still do **steps 1–4** (prereqs are only
`git`/`openssl`/`jq` for the host; the build brings its own toolchain) — i.e. clone + render `env/.env.dev`
with `init-env.sh`. The image's entrypoint runs **`ensure_db` (DB + migrations) then uvicorn**, so you don't
run step 5 yourself.

```bash
# build — reads the PINNED pyproject, so the image gets the same compatible deps as native
docker build -t dokandar_auth_service:dev .

# run — config injected at runtime via --env-file; the /data snapshot bind-mounted read-only
docker run -d --name dokandar_auth_service_dev \
  --env-file env/.env.dev \
  -e TENANT=cloud \
  -v "$(pwd)/data:/app/data:ro" \
  -p 10001:8000 -p 20001:8001 \
  --restart=on-failure:3 \
  dokandar_auth_service:dev

docker logs -f dokandar_auth_service_dev          # watch boot: ensure_db → migrations → uvicorn
curl -s localhost:10001/health | jq '.checks|to_entries|map({(.key):.value.ok})|add'
```

REST is published on host **`:10001`**, gRPC on **`:20001`** (the platform's external port map for `01-auth`).
Secrets are **never baked into the image** — `.dockerignore` excludes `env/*`, and config arrives only via
`--env-file` at run time. (Run `./data/cloud/collect.sh` first so `TENANT=cloud` has a `/data` snapshot.)

---

## 7. Generate the `/data` tenant snapshot (optional)

```bash
bash data/local/collect.sh      # native/lab box  (TENANT=local → data/local/result.json)
# bash data/cloud/collect.sh    # AWS EC2         (TENANT=cloud → data/cloud/result.json)
```

Without it, `GET /data` correctly returns `404 no_snapshot`.

---

## 8. Verify

```bash
# identity
curl -s localhost:8000/ready | jq .identity

# all dependencies healthy (expect every value true)
curl -s localhost:8000/health | jq '.checks | to_entries | map({(.key): .value.ok}) | add'

# Swagger UI + the contract surface
curl -s -o /dev/null -w "%{http_code}\n" localhost:8000/docs
curl -s localhost:8000/openapi.json | jq -r '.info.title, .info.version'   # DOKANDAR Auth Service / 01-auth

# end-to-end signup → RS256 JWT (OTP is bypassed in dev: OTP_ENABLED=false)
PHONE="01711$(printf '%06d' $((RANDOM%1000000)))"
curl -s -X POST -H 'content-type: application/json' -d "{\"phone\":\"$PHONE\"}" \
  localhost:8000/api/v1/auth/signup/request
TOK=$(curl -s -X POST -H 'content-type: application/json' \
  -d "{\"phone\":\"$PHONE\",\"name\":\"Karim Uddin\",\"role\":\"customer\",\"lang\":\"bn\"}" \
  localhost:8000/api/v1/auth/signup/verify | jq -r .access_token)
echo "$TOK" | cut -d. -f2 | base64 -d 2>/dev/null | jq   # role / lang / kyc / iss=dokandar-auth
```

Externally, replace `localhost` with the host IP (open `8000`/`8001` in the security group as needed).

---

## 9. Operate

```bash
sudo journalctl -u dokandar-auth -f          # live logs
sudo systemctl restart dokandar-auth         # restart
./env/init-env.sh .env.dev && sudo systemctl restart dokandar-auth   # rotate the JWT keypair + reload
```

- **Logs:** stdout (journald) + MongoDB `mongo_db_dokandar_application_logs.01-auth` + Elasticsearch
  `logs-app-01-auth-*` (Kibana → Discover). Traces in Elastic APM under service `01-auth`.
- **Endpoints:** `/ready` (LB gate — postgres), `/health` (all deps), `/data` (tenant snapshot), `/metrics`
  (Prometheus), `/docs` + `/openapi.json` (Swagger). Business API under `/api/v1/auth/*`.

---

## 10. Security notes

- `env/env.txt` and `env/.env.dev` hold **real secrets** — both are **gitignored**; never commit them.
- Auth is the **sole holder** of the RS256 private key (generated by `init-env.sh`); every other service gets
  only `JWT_PUBLIC_KEY_B64` + `INTERNAL_SERVICE_TOKEN` (the verify side).
- `SERVICE_NAME=01-auth` is sourced from the env and propagates to logs, metrics, APM, the Mongo collection,
  and the ES index — change it only via the env file.
