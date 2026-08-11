# `02-profile` — DOKANDAR Profile & Address Service

Go 1.24+ · chi v5 · pgx v5 · PostgreSQL · Redis (cache-aside) · Kafka
(consumes `dokandar.user.created`) · MongoDB + Elasticsearch (log sinks) · Elastic APM.
Owns the `profiles` + `addresses` tables, auto-creates a profile shell when **01-auth**
emits `user.created`, serves the five operational endpoints, an east-west gRPC
`ProfileQuery` server, three log sinks, and RS256 **verify-only** JWT auth.

- **Design doc:** [`architecture.md`](./architecture.md) (full spec — read for *how it works*).
- **This README:** copy-paste **native** install (no Docker). Docker path: [`SETUP-DOCKER.md`](./SETUP-DOCKER.md).

> **Verified deploy.** Natively deployed + acceptance-passed on Ubuntu 26.04 / Go 1.26 against
> the live components host — `/health` healthy with all deps `ok` (postgres, redis, kafka,
> mongo_logs, apm); the DB + migrations auto-create on boot; a JWT minted by the live **01-auth**
> verifies end-to-end (`GET /api/v1/profile/me` → not `401`).

---

## 0. What you need

- A Linux host (Ubuntu 24.04/26.04 tested) with **Go 1.24+** (1.26 used here) and `sudo`.
- Network reachability to the **components host** (PostgreSQL / Redis / Kafka / MongoDB /
  Elasticsearch / Elastic-APM) — private IP if same-VPC, else its public IP.
- **01-auth already deployed** on this host — profile is verify-only and reads auth's
  `JWT_PUBLIC_KEY_B64` + `INTERNAL_SERVICE_TOKEN` from auth's rendered `env/.env.dev`.
- The infra credentials (the `### NN_Service` status dump) to paste into `env/env.txt`.

---

## 1. Install OS prerequisites

```bash
sudo apt-get update
sudo apt-get install -y golang-go build-essential git rsync openssl curl jq ca-certificates
go version    # must be >= go1.24 (Ubuntu 26.04 ships 1.26)
```

*(If your distro's `golang-go` is older than 1.24, install the official tarball instead:
`curl -fsSL https://go.dev/dl/go1.24.5.linux-amd64.tar.gz | sudo tar -C /usr/local -xz` and add
`/usr/local/go/bin` to `PATH`.)*

---

## 2. Get the code

```bash
sudo mkdir -p /opt/dokandar && sudo chown -R "$USER":"$USER" /opt/dokandar
git clone -b source-code git@gitlab.com:learningdevopstools/backend/02-profile.git /opt/dokandar/02-profile
cd /opt/dokandar/02-profile
```

---

## 3. Paste the infra creds → render `env/.env.dev`

```bash
cp env/env.txt.example env/env.txt
nano env/env.txt        # paste the REAL infra creds (the ### NN_Service blocks)
chmod 600 env/env.txt
./env/init-env.sh .env.dev
```

`init-env.sh` parses `env/env.txt` (blocks `01_PostgreSQL`, `02_MongoDB`, `03_Elasticsearch`,
`04_Redis`, `05_Kafka`, `07_Elastic_APM`) and writes `env/.env.dev` (`chmod 600`,
**gitignored — never commit**). It wires: Postgres → `dokandar_profile_dev`, **Redis DB 1**
(invalidate-only cache), the live Kafka broker, the Mongo log collection
`mongo_db_dokandar_application_logs.02-profile`, the **`:9201`** Elasticsearch log sink (not
the APM ES), and the APM ingest `:8200` + token.

**Auth's public key + token** are *not* in `env.txt`. The script reads them from the deployed
**01-auth** automatically (`/opt/dokandar/01-auth/env/.env.dev`). To point elsewhere, or to
paste them by hand:

```bash
# auto (default): reads /opt/dokandar/01-auth/env/.env.dev
./env/init-env.sh .env.dev
# explicit file:
AUTH_ENV_FILE=/path/to/auth/.env.dev ./env/init-env.sh .env.dev
# or paste the two values directly:
AUTH_PUBLIC_KEY_B64='<auth JWT_PUBLIC_KEY_B64>' AUTH_INTERNAL_TOKEN='<auth INTERNAL_SERVICE_TOKEN>' \
  ./env/init-env.sh .env.dev
```

> Profile **never** holds a private key — it only verifies auth-issued RS256 JWTs.

---

## 4. Build the binary

```bash
go mod download                       # fetch deps (no `go mod tidy` — build against the committed go.sum)
go build -o bin/profile ./cmd/profile
```

The gRPC stubs (`internal/grpcserver/pb/*.pb.go`) are **pre-generated and committed**, so a plain
`go build` works with no `protoc` toolchain on the install host. *(To regenerate them after editing
`proto/profile.proto`: `sudo apt-get install -y protobuf-compiler` + `go install
google.golang.org/protobuf/cmd/protoc-gen-go@v1.35.1 google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.5.1`,
then `protoc --go_out=. --go_opt=module=github.com/dokandar/dokandar-profile --go-grpc_out=.
--go-grpc_opt=module=github.com/dokandar/dokandar-profile proto/profile.proto`.)*

A static-ish Go binary lands at `bin/profile`. No DB bootstrap step is needed — on first boot
the service connects to the admin DB, `CREATE DATABASE dokandar_profile_dev` if missing, and
runs the embedded migrations (`profiles` / `addresses` + the partial-unique default-address
index). Idempotent.

---

## 5. Run the service (REST `10002`, gRPC `20002`)

### 5a. Foreground (quick test)

```bash
set -a && . env/.env.dev && set +a && ./bin/profile
```

### 5b. systemd (persistent, recommended)

```bash
sudo tee /etc/systemd/system/dokandar-profile.service >/dev/null <<UNIT
[Unit]
Description=DOKANDAR 02-profile (native Go)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=/opt/dokandar/02-profile
EnvironmentFile=/opt/dokandar/02-profile/env/.env.dev
ExecStart=/opt/dokandar/02-profile/bin/profile
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now dokandar-profile
sudo systemctl status dokandar-profile --no-pager
```

`WorkingDirectory` matters: the binary reads `CODE_VERSION` and the embedded migrations relative
to it. `EnvironmentFile=env/.env.dev` injects all config.

---

## 6. Verify

```bash
# identity
curl -s localhost:10002/ready | jq .identity

# all dependencies healthy (expect every value true)
curl -s localhost:10002/health | jq '.checks | to_entries | map({(.key): .value.ok}) | add'

# Swagger UI + the contract surface
curl -s -o /dev/null -w "%{http_code}\n" localhost:10002/docs
curl -s localhost:10002/openapi.json | jq -r '.info.title'      # DOKANDAR Profile Service

# CROSS-SERVICE JWT TEST — the real acceptance gate.
# A JWT minted by the live 01-auth must verify here (not 401 => auth's key matches).
PHONE="01711$(printf '%06d' $((RANDOM%1000000)))"
curl -s -X POST -H 'content-type: application/json' -d "{\"phone\":\"$PHONE\"}" \
  localhost:8000/api/v1/auth/signup/request
TOK=$(curl -s -X POST -H 'content-type: application/json' \
  -d "{\"phone\":\"$PHONE\",\"name\":\"Karim Uddin\",\"role\":\"customer\",\"lang\":\"bn\"}" \
  localhost:8000/api/v1/auth/signup/verify | jq -r .access_token)
curl -s -o /dev/null -w "GET /me with auth JWT -> %{http_code}\n" \
  -H "Authorization: Bearer $TOK" localhost:10002/api/v1/profile/me   # 200 (or 404), never 401
```

Externally, replace `localhost` with the host IP (open `10002`/`20002` in the security group as needed).

---

## 7. Operate

```bash
sudo journalctl -u dokandar-profile -f          # live logs
sudo systemctl restart dokandar-profile         # restart
./env/init-env.sh .env.dev && sudo systemctl restart dokandar-profile   # re-render env + reload
```

- **Logs:** stdout (journald) + MongoDB `mongo_db_dokandar_application_logs.02-profile` +
  Elasticsearch `logs-app-02-profile-*` (Kibana → Discover). Traces in Elastic APM under `02-profile`.
- **Endpoints:** `/ready` (LB gate), `/health` (all deps), `/data` (tenant snapshot),
  `/metrics` (Prometheus), `/docs` + `/openapi.json` (Swagger). Business API under
  `/api/v1/profile/*`; east-west gRPC `ProfileQuery` on `:20002`.

---

## The five standard endpoints

| Path | What |
|------|------|
| `GET /ready`  | LB gate — `postgres` (+`redis`, the cache is on the request path). `200`/`503`. |
| `GET /health` | All deps — `postgres / redis / kafka / mongo_logs / apm / grpc_media` + `observability`. |
| `GET /data`   | Identity + tenant snapshot (`404 no_snapshot` if absent). |
| `GET /docs`   | Swagger UI titled `DOKANDAR 02-profile`, Bearer **Authorize** button. |
| `GET /metrics`| Prometheus text exposition (RED + `profile_outbox_pending`). |

Unmapped paths return a **bare HTTP 404, zero-byte body** (no surface leakage).

## Business API (`/api/v1/profile/…`)

`GET/PATCH/PUT /me` · `GET/POST /me/addresses` · `GET/PATCH/DELETE /me/addresses/{id}` ·
`POST /me/addresses/{id}/default` · `POST /me/avatar` (mints a presigned URL via Media gRPC) ·
public `GET /geo/*` (divisions/districts/upazilas/unions). All `/me*` require
`Authorization: Bearer <access-token>` minted by **01-auth** (RS256, verified offline against
`JWT_PUBLIC_KEY_B64`).

## Data model (PostgreSQL — `dokandar_profile_<env>`)

```
profiles  : user_id (PK, == auth.users.id, opaque), name, gender, alt_phone, avatar_key, ...
addresses : id (PK), user_id, label, line1/2, city, district, postal_code, lat, lon, is_default, ...
CREATE UNIQUE INDEX uniq_addresses_user_default ON addresses(user_id) WHERE is_default;
```

No cross-service FK to auth's `users` — consistency is asynchronous via the
`dokandar.user.created` Kafka event (database-per-service).

---

## 8. Security notes

- `env/env.txt` and `env/.env.dev` hold **real secrets** — both **gitignored**; never commit them.
- Profile is **verify-only**: it holds `JWT_PUBLIC_KEY_B64` + `INTERNAL_SERVICE_TOKEN` (the verify
  side), never the RS256 private key — that lives only in **01-auth**.
- East-west gRPC compares `INTERNAL_SERVICE_TOKEN` in constant time.
- `SERVICE_NAME=02-profile` is sourced from the env and propagates to logs, metrics, APM, the
  Mongo collection, and the ES index — change it only via the env file.
