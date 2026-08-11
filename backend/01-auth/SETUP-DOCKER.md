# Setup — Docker (`docker run`, no Compose)

This is the production-equivalent path for `dokandar-auth`. You build a
single multi-stage image with `docker build`, then run it with
`docker run` against the **components host** (PostgreSQL / Redis / Kafka
/ RabbitMQ / MongoDB / RustFS / Elastic APM).

The image is the source of truth: the same image runs `dev`, `stage`,
and `prod` with only the env file changing. The whole flow is **10 steps**.

> If you're new to the codebase, read [README.md](./README.md) first.

---

## 1. Install Docker

### Debian / Ubuntu
```
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg git jq
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release; echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io
sudo usermod -aG docker $USER   # then log out + back in
```

### RHEL / CentOS / Rocky / Fedora
```
sudo dnf install -y dnf-plugins-core git curl jq
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
```

### macOS
Install [Docker Desktop](https://docs.docker.com/desktop/install/mac-install/),
launch it once so the daemon starts, then verify with `docker version`.

---

## 2. Clone the repo

```
git clone git@gitlab.com:dokandar/backend/01-auth.git dokandar-auth
cd dokandar-auth
```

---

## 3. Render the env file from the components paste

The image carries no secrets. Every value is injected at runtime via
`env/.env.<APP_ENV>`. The components team produces a single credential
block via `components/manage-services.sh status` — paste it once, and the
init script does the rest.

```
cp env/components-creds.example.txt env/components-creds.txt
$EDITOR env/components-creds.txt   # paste the real output here
./env/init-env.sh .env.dev
```

The script:

1. Extracts Postgres / Redis / Kafka / RabbitMQ / MongoDB / Elasticsearch / APM-server / RustFS endpoints + credentials from the paste.
2. Generates a fresh RS256 JWT keypair (via `openssl genrsa`) and a 64-hex `INTERNAL_SERVICE_TOKEN`.
3. Writes `env/.env.dev` (chmod 600, gitignored).

The committed `.env.dev.example` is the template the script substitutes
against — never delete it.

> The same script renders `.env.stage` / `.env.prod` — pass the target
> filename: `./env/init-env.sh .env.stage`.

---

## 4. Collect the tenant snapshot

`/data` returns the contents of `data/<TENANT>/result.json`. Generate
the right snapshot for where you're running:

```
# Native + lab boxes
./data/local/collect.sh

# AWS EC2 (uses IMDSv2)
./data/cloud/collect.sh
```

`result.json` is bind-mounted read-only into the container at runtime
(step 7) — no rebuild needed when the snapshot changes.

---

## 5. Build the image

```
docker build --no-cache -t dokandar_auth_service:latest .
docker tag dokandar_auth_service:latest dokandar_auth_service:dev
```

The Dockerfile is multi-stage (`base → build → runtime`):

- `build`: installs deps into `/opt/venv`.
- `runtime`: copies only the venv + app source + `proto/` + `migrations/` + `CODE_VERSION`.
- Runs as **non-root** (`appuser`, UID 10001).
- `EXPOSE 8000 8001` (HTTP + gRPC).
- `HEALTHCHECK` polls `/ready` every 30 s.
- Entrypoint runs `python -m app.lifecycle.ensure_db` before starting uvicorn — creates the DB if missing, runs Alembic, ensures the KYC bucket exists.

---

## 6. Wipe any previous container

If you've already run a previous version, drop the old container and its
PostgreSQL DB so the new bootstrap path runs clean:

```
docker rm -f dokandar_auth_service_dev 2>/dev/null

# DROP DATABASE — note: this wipes any test users on the auth DB.
docker run --rm \
  -e PGPASSWORD=<postgres_user_dokandar_application password> \
  postgres:16-alpine psql \
  -h <components-host-ip> -U postgres_user_dokandar_application \
  -d postgres_db_dokandar_application -v ON_ERROR_STOP=1 \
  -c "DROP DATABASE IF EXISTS dokandar_auth_dev;"
```

Skip this step on a brand-new install.

---

## 7. Run the container (dev)

```
docker run -d --name dokandar_auth_service_dev \
  --env-file env/.env.dev -e TENANT=cloud \
  -v "$(pwd)/data:/app/data:ro" \
  -p 10001:8000 -p 10011:8001 \
  --restart=on-failure:3 \
  dokandar_auth_service:dev
```

Port mapping:

| Env | HTTP external → internal | gRPC external → internal |
|---|---|---|
| dev   | `10001 → 8000` | `10011 → 8001` |
| stage | `10101 → 8000` | `10111 → 8001` |
| prod  | `10201 → 8000` | `10211 → 8001` |

The `-v data:/app/data:ro` bind mount lets `data/<TENANT>/collect.sh`
re-runs surface at `/data` without rebuilding or restarting the
container.

`TENANT` is a runtime override (`local` for laptops, `cloud` for EC2/EKS).
The actual identity (`service_name`, `code_version`, `env_version`,
`env`) comes from `CODE_VERSION` + `.env.dev`.

---

## 8. Verify the boot

Wait ~10 s for `ensure_db` + Alembic + the seed admin, then:

```
curl -s http://localhost:10001/ready | jq .identity
```

Expected:

```jsonc
{
  "service_name":  "auth",
  "code_version":  "1-auth",
  "env_version":   "v1.0.0",
  "tenant":        "cloud",
  "env":           "dev",
  "uptime_seconds": 12
}
```

Then full health (7 dep checks):

```
curl -s http://localhost:10001/health | jq '.checks | to_entries | map({(.key): .value.ok}) | add'
```

Every value should be `true`:

```jsonc
{
  "postgres":   true,
  "redis":      true,
  "kafka":      true,
  "rabbitmq":   true,
  "mongo_logs": true,
  "apm":        true,
  "s3_kyc":     true
}
```

If `s3_kyc` is `false` with `"S3 not configured"`, your `env/.env.dev`
is missing `S3_ENDPOINT` / `S3_ACCESS_KEY` / `S3_SECRET_KEY` — re-run
`./env/init-env.sh .env.dev` after confirming the `=== rustfs ===` block
is present in `env/components-creds.txt`.

---

## 9. End-to-end signup

```
PHONE="01711$(printf '%06d' $((RANDOM*RANDOM % 1000000)))"
curl -s -X POST -H 'content-type: application/json' \
  -d "{\"phone\":\"$PHONE\"}" \
  http://localhost:10001/api/v1/auth/signup/request

# In dev mode, the OTP is logged. Grab it:
OTP=$(docker logs --since 5s dokandar_auth_service_dev 2>&1 \
       | grep -oE 'purpose=signup code=[0-9]{6}' | tail -1 | grep -oE '[0-9]{6}')

curl -s -X POST -H 'content-type: application/json' \
  -d "{\"phone\":\"$PHONE\",\"code\":\"$OTP\",\"name\":\"Karim Uddin\",\"role\":\"customer\",\"lang\":\"bn\"}" \
  http://localhost:10001/api/v1/auth/signup/verify | jq
```

You should get an `access_token` + `refresh_token` + `user` object with
`kyc=unverified` and `lang=bn`. Decode the JWT (`jq -R 'split(".")[1] | @base64d | fromjson'`) — it carries `role`, `lang`, `kyc`, `jti`.

---

## 10. Stage / prod

The same image runs all three. Render the right env, retag, and run on
the right port:

```
./env/init-env.sh .env.stage
docker tag dokandar_auth_service:latest dokandar_auth_service:stage
docker run -d --name dokandar_auth_service_stage \
  --env-file env/.env.stage -e TENANT=cloud \
  -v "$(pwd)/data:/app/data:ro" \
  -p 10101:8000 -p 10111:8001 \
  --restart=on-failure:3 \
  dokandar_auth_service:stage

./env/init-env.sh .env.prod
docker tag dokandar_auth_service:latest dokandar_auth_service:prod
docker run -d --name dokandar_auth_service_prod \
  --env-file env/.env.prod -e TENANT=cloud \
  -v "$(pwd)/data:/app/data:ro" \
  -p 10201:8000 -p 10211:8001 \
  --restart=on-failure:3 \
  dokandar_auth_service:prod
```

In stage/prod the env file is normally rendered from a vaulted secret
store, not a paste — the contract is the same key list.

---

## Operating notes

### Logs

```
docker logs dokandar_auth_service_dev          # tail JSON to stdout
docker logs -f --since 1m dokandar_auth_service_dev   # follow
docker logs dokandar_auth_service_dev 2>&1 | grep DEV-OTP   # OTP codes (dev only)
```

Logs ship to three places:

1. **stdout** (above).
2. **MongoDB** → `mongo_db_dokandar_application_logs.auth`.
3. **Elasticsearch** → `logs-app-auth-default` (Kibana Discover / APM Logs tab).

### Stop / restart

```
docker stop dokandar_auth_service_dev
docker start dokandar_auth_service_dev
docker restart dokandar_auth_service_dev
```

### Code change → redeploy

```
# rebuild
docker build -t dokandar_auth_service:latest .

# re-render env if .env.dev.example changed
./env/init-env.sh .env.dev

# drop + recreate
docker rm -f dokandar_auth_service_dev
docker run -d --name dokandar_auth_service_dev \
  --env-file env/.env.dev -e TENANT=cloud \
  -v "$(pwd)/data:/app/data:ro" \
  -p 10001:8000 -p 10011:8001 --restart=on-failure:3 \
  dokandar_auth_service:latest
```

### Hard wipe (start from zero)

```
docker rm -f dokandar_auth_service_dev
docker rmi -f dokandar_auth_service:latest dokandar_auth_service:dev
rm -f env/.env.dev          # forces re-render on next init
# then drop the DB (step 6) and start at step 3 again
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `/ready` returns 503, `postgres.reachable=false` | Wrong host / password in `POSTGRES_DSN`; components host firewalled | `docker run --rm postgres:16-alpine pg_isready -h <host>`; check `env/.env.dev` |
| `/ready` returns 503, `redis.reachable=false` | Wrong password or OTP_ENABLED=true with no Redis reachable | `redis-cli -h <host> -a <pass> ping` |
| `/health.checks.s3_kyc.ok=false` | `S3_*` env vars empty or wrong | Re-run `./env/init-env.sh .env.dev`; confirm `=== rustfs ===` block in creds |
| `docker logs` shows old version after rebuild | Cached image layer | `docker build --no-cache ...` |
| gRPC `:10011` connection refused | gRPC server failed to start because `_generated/` couldn't be written | Container must run with the default `appuser`; codegen writes to `/tmp/dokandar_auth_grpc_stubs/` |
| Container restart-loop | `ensure_db` can't reach Postgres at boot | Check `POSTGRES_ADMIN_DSN` points at the `postgres` admin DB, not the service DB |

---

## What gets installed

| Layer | What |
|---|---|
| Host | docker, jq |
| Image | python:3.13-slim · libpq · curl (HEALTHCHECK) · CA roots |
| Venv | fastapi, uvicorn, sqlalchemy[asyncio], asyncpg, alembic, redis, aio-pika, confluent-kafka, pymongo, pyjwt[crypto], argon2-cffi, prometheus-fastapi-instrumentator, elastic-apm, python-json-logger, httpx, psycopg2-binary, grpcio, grpcio-tools, protobuf, boto3 |
| Bind mounts | `data/:/app/data:ro` only — no secrets in the image |
| Ports | `8000` (HTTP) + `8001` (gRPC) inside; mapped per env |
| User | `appuser` UID 10001 (non-root) |
| Healthcheck | `curl -fsS http://localhost:${SERVICE_PORT:-8000}/ready` every 30 s |

---

The image is fully self-bootstrapping — DB creation, Alembic
migrations, KYC bucket creation, admin seed all happen on first start.
