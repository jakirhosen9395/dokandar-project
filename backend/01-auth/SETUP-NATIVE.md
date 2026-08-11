# Setup — Native (Python + uvicorn, no Docker)

This guide runs `dokandar-auth` directly on the host — a Python venv +
uvicorn against the **components host** (PostgreSQL / Redis / Kafka /
RabbitMQ / MongoDB / RustFS / Elastic APM). Fastest inner loop for
development; production-equivalent path lives in
[SETUP-DOCKER.md](./SETUP-DOCKER.md).

The whole flow is **10 steps**.

> Read [README.md](./README.md) first if you're new to the codebase.

---

## 1. Install OS prerequisites

You need a C toolchain (for Python C-extension deps), `libpq` (Postgres
client), OpenSSL (for `init-env.sh`'s `openssl genrsa`), plus `curl` and
`jq` for testing.

### Debian / Ubuntu
```
sudo apt-get update
sudo apt-get install -y build-essential libpq-dev libssl-dev libffi-dev \
                        openssl curl jq ca-certificates git
```

### RHEL / CentOS / Rocky / Fedora
```
sudo dnf install -y gcc gcc-c++ make libpq-devel openssl-devel libffi-devel \
                    openssl curl jq ca-certificates git
```

### macOS

Install [Homebrew](https://brew.sh) first if you don't have it, then:
```
brew install libpq openssl@3 libffi curl jq git
```

If `libpq` isn't on your default `PATH`:
```
echo 'export PATH="/opt/homebrew/opt/libpq/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

---

## 2. Install `uv` (Python toolchain)

`uv` downloads a standalone CPython 3.13 build and isolates the venv —
no system Python clutter. Single-binary installer:

```
curl -LsSf https://astral.sh/uv/install.sh | sh
exec "$SHELL"        # reload your PATH
uv --version
```

(If you prefer `pyenv` / system Python 3.13, that works too — see step 4
for the venv shape `uv` produces.)

---

## 3. Clone the repo

```
git clone git@gitlab.com:dokandar/backend/01-auth.git dokandar-auth
cd dokandar-auth
```

---

## 4. Create the venv + install deps

```
uv venv --python 3.13       # creates .venv/ with CPython 3.13
source .venv/bin/activate
uv pip install -e ".[dev]"  # editable install + ruff, pytest, etc.
```

The `[dev]` extra pulls `pytest`, `pytest-asyncio`, and `ruff` — drop it
in production setups.

---

## 5. Render `env/.env.dev`

```
cp env/components-creds.example.txt env/components-creds.txt
$EDITOR env/components-creds.txt   # paste the real output of
                                   # components/manage-services.sh status
./env/init-env.sh .env.dev
```

`init-env.sh`:

1. Extracts Postgres / Redis / Kafka / RabbitMQ / MongoDB / Elasticsearch / APM-server / RustFS endpoints + credentials from the paste.
2. Generates a fresh RS256 JWT keypair (`openssl genrsa`) + a 64-hex `INTERNAL_SERVICE_TOKEN`.
3. Writes `env/.env.dev` (chmod 600, gitignored).

Re-running rotates the keypair + token. The template
`env/.env.dev.example` is the source of variable names — never delete
it. The same script renders `.env.stage` / `.env.prod` — pass the
target name: `./env/init-env.sh .env.stage`.

---

## 6. Collect the tenant snapshot

`/data` returns `data/<TENANT>/result.json`. Generate the right one:

```
./data/local/collect.sh       # native + lab boxes
./data/cloud/collect.sh       # AWS EC2 — uses IMDSv2
```

`TENANT` is decided by the env file (`TENANT=local` for `.env.dev`,
`cloud` for `.env.stage` / `.env.prod`), so `/data` reads
`data/local/result.json` or `data/cloud/result.json` accordingly.

---

## 7. Bootstrap the database

The service can do this itself at startup (entrypoint runs
`python -m app.lifecycle.ensure_db`), but for native runs it's cleaner
to do it explicitly the first time so you see any error directly.

```
APP_ENV=dev python -m app.lifecycle.ensure_db
```

What it does:

1. Connects to `POSTGRES_ADMIN_DSN` (the `postgres` admin DB).
2. `CREATE DATABASE dokandar_auth_dev` if missing.
3. Runs `alembic upgrade head` against `dokandar_auth_dev`:
   - `0001_init` — `users`, `refresh_tokens`, `outbox`, enums.
   - `0002_kyc` — `kyc_submissions`, `users.kyc`, `users.lang`; promotes any admin row to `kyc='verified'`.
4. Calls `app.storage.s3.ensure_bucket()` — creates the `dokandar-kyc-dev` bucket on RustFS if missing.

If you need to drop the DB (e.g. to test fresh-bootstrap), use the same
postgres credentials your `.env.dev` has:

```
APP_ENV=dev python -c "
import os, asyncio, asyncpg
from urllib.parse import urlparse
admin = os.environ['POSTGRES_ADMIN_DSN'].replace('postgresql+asyncpg://','postgresql://')
asyncio.run((lambda: (lambda c: c.execute('DROP DATABASE IF EXISTS dokandar_auth_dev'))(asyncpg.connect(admin)))())
"
```

---

## 8. Run the service

Foreground (Ctrl+C to stop):

```
APP_ENV=dev uvicorn app.main:app --host 0.0.0.0 --port 8000
```

That starts the FastAPI app on `:8000`, the gRPC `Auth` server on
`:8001` (as a sibling asyncio task in the lifespan), the outbox-relay
loop (every 2 s), the in-process MongoDB + Elasticsearch log sinks, and
the seed-admin step.

For a backgrounded native run (e.g. on a lab box):

```
APP_ENV=dev nohup uvicorn app.main:app --host 0.0.0.0 --port 8000 \
  > /tmp/dokandar-auth.log 2>&1 &
echo $! > /tmp/dokandar-auth.pid
```

Stop with `kill $(cat /tmp/dokandar-auth.pid)`.

---

## 9. Verify the boot

```
curl -s http://localhost:8000/ready | jq .identity
```

Expected:

```jsonc
{
  "service_name":  "auth",
  "code_version":  "1-auth",
  "env_version":   "v1.0.0",
  "tenant":        "local",
  "env":           "dev",
  "uptime_seconds": 4
}
```

Then full health (7 dep checks):

```
curl -s http://localhost:8000/health | jq '.checks | to_entries | map({(.key): .value.ok}) | add'
```

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

End-to-end signup:

```
PHONE="01711$(printf '%06d' $((RANDOM*RANDOM % 1000000)))"
curl -s -X POST -H 'content-type: application/json' \
  -d "{\"phone\":\"$PHONE\"}" \
  http://localhost:8000/api/v1/auth/signup/request

# Dev mode logs the OTP to stdout — pull it from your nohup log or the
# foreground uvicorn output:
OTP=$(tail -50 /tmp/dokandar-auth.log | grep -oE 'purpose=signup code=[0-9]{6}' | tail -1 | grep -oE '[0-9]{6}')

curl -s -X POST -H 'content-type: application/json' \
  -d "{\"phone\":\"$PHONE\",\"code\":\"$OTP\",\"name\":\"Karim Uddin\",\"role\":\"customer\",\"lang\":\"bn\"}" \
  http://localhost:8000/api/v1/auth/signup/verify | jq
```

Decode the JWT to confirm it carries `role`, `lang`, `kyc`, `jti`:

```
TOK=$(curl ... | jq -r .access_token)
echo "$TOK" | cut -d. -f2 | base64 -d 2>/dev/null | jq
```

---

## 10. systemd unit (persistent native runs)

For a dev / lab box where you want the service to come back after a
reboot, install a unit file. **Do not** use this in production — use
SETUP-DOCKER.md and Kubernetes for that.

```
sudo tee /etc/systemd/system/dokandar-auth.service > /dev/null <<'UNIT'
[Unit]
Description=DOKANDAR Auth service (native uvicorn)
After=network.target

[Service]
Type=simple
User=dokandar
WorkingDirectory=/opt/dokandar-auth
ExecStart=/opt/dokandar-auth/.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000
Environment=APP_ENV=dev
EnvironmentFile=/opt/dokandar-auth/env/.env.dev
Restart=on-failure
RestartSec=5
StandardOutput=append:/var/log/dokandar-auth/stdout.log
StandardError=append:/var/log/dokandar-auth/stderr.log

[Install]
WantedBy=multi-user.target
UNIT

sudo mkdir -p /var/log/dokandar-auth
sudo chown -R dokandar:dokandar /var/log/dokandar-auth

sudo systemctl daemon-reload
sudo systemctl enable --now dokandar-auth
sudo systemctl status dokandar-auth
```

`journalctl -u dokandar-auth -f` follows the log; `systemctl restart
dokandar-auth` for a clean cycle.

---

## Operating notes

### Code change → reload

uvicorn supports auto-reload for development:

```
APP_ENV=dev uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

`--reload` watches `app/` for changes. Don't use it in stage/prod.

### Database changes (Alembic)

```
APP_ENV=dev alembic revision -m "add new column"
$EDITOR migrations/versions/<new>.py
APP_ENV=dev alembic upgrade head
```

Migrations run automatically on next boot via `ensure_db`, so once the
revision is committed, deploying the new code re-runs Alembic during the
service's startup.

### Tests

```
APP_ENV=dev pytest -q                          # unit tests
APP_ENV=dev pytest -q tests/integration/       # spins up testcontainers (Docker required)
ruff check .                                    # lint
ruff format .                                   # format
```

### Multi-env

The same code runs all three. Render the right env, point at it via
`APP_ENV`, and pick a free port:

```
./env/init-env.sh .env.stage
APP_ENV=stage uvicorn app.main:app --host 0.0.0.0 --port 8100

./env/init-env.sh .env.prod
APP_ENV=prod  uvicorn app.main:app --host 0.0.0.0 --port 8200
```

(The port scheme `10101 / 10201` is the **external** mapping for
the Docker path. Native runs are typically on the canonical service port
`8000`; pick anything that doesn't clash with another service.)

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `ImportError: No module named 'app'` | not inside repo root or venv not active | `cd dokandar-auth && source .venv/bin/activate` |
| `psycopg2.OperationalError: connection refused` at `ensure_db` | wrong host / firewall / Postgres down | `psql "$POSTGRES_ADMIN_DSN"` — does it connect? |
| `alembic.util.exc.CommandError: Can't locate revision identified by '0002…'` | DB was set up with a different revision; mismatch with migrations dir | Drop DB and re-run `ensure_db` |
| `/health.checks.s3_kyc.ok=false` with `"S3 not configured"` | `S3_*` env vars empty | re-run `./env/init-env.sh .env.dev` after confirming `=== rustfs ===` block in creds |
| `/health.checks.apm.ok=false` | wrong `APM_SERVER_URL` or APM-server down | `curl http://<host>:8200/` from this machine |
| gRPC port refuses connections | `GRPC_ENABLED=false` in env, or codegen failed | check stdout for `grpc Auth listening on 0.0.0.0:8001` |
| Logs missing from Mongo | `MONGO_LOG_DB` wrong | should be `mongo_db_dokandar_application_logs`; re-render env |

---

## What gets installed

| Layer | What |
|---|---|
| OS | build-essential, libpq-dev, libssl-dev, libffi-dev, openssl, curl, jq, git |
| Python | CPython 3.13 (via `uv venv --python 3.13`) |
| Venv | fastapi, uvicorn, sqlalchemy[asyncio], asyncpg, alembic, redis, aio-pika, confluent-kafka, pymongo, pyjwt[crypto], argon2-cffi, prometheus-fastapi-instrumentator, elastic-apm, python-json-logger, httpx, psycopg2-binary, grpcio, grpcio-tools, protobuf, boto3 (plus pytest, pytest-asyncio, ruff under `[dev]`) |
| Service DB | `dokandar_auth_dev` on the components host's Postgres |
| KYC bucket | `dokandar-kyc-dev` on the components host's RustFS |
| systemd unit | `/etc/systemd/system/dokandar-auth.service` (optional) |

---

For the production-equivalent deployment path, see
[SETUP-DOCKER.md](./SETUP-DOCKER.md).
