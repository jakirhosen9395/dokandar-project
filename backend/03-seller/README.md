# `03-seller` — Merchant & Shop service

**PHP 8.5 · Laravel 13 · PostgreSQL · Redis · Kafka · MongoDB · Elasticsearch · Elastic APM**

The merchant side of DOKANDAR: shop registration + the `draft → live ↔ paused → suspended → closed`
lifecycle, operating hours, staff roles, categories, BD seller-tier KYC verdicts (Trade License / TIN /
DBID / BIN), public PII-stripped shop pages, and geo "shops near me". Verify-only (RS256), event-driven
(emits `dokandar.shop.*`, consumes `dokandar.kyc.*`), no gRPC server.

- **Design doc:** [`architecture.md`](architecture.md) — the full build contract (data model, flows, §16 landmines).
- **This README:** copy-paste **native** install (no Docker). Docker path: [`commands.md`](commands.md).

> **Verified deploy.** Ubuntu 26.04 · PHP 8.5 · components host `172.31.13.161` · `/health` all deps `ok` ·
> acceptance: auth-minted JWT → `POST /api/v1/shop/shops` 201, and `dokandar.kyc.approved` → `shopkeeper_kyc_cache` verified.

> **Bounded-context note.** Identity is `03-seller` (logs, metrics `seller_*`, APM, Mongo/ES sinks), but
> the **database stays `dokandar_shop_<env>`** and **routes stay `/api/v1/shop/*`** — do not rename them.

---

## 0. What you need

- A Linux host (Ubuntu 26.04) with network reachability to the components host (PostgreSQL/Redis/Kafka/Mongo/ES/APM).
- **`01-auth` already deployed and reachable** (this service verifies auth-issued JWTs; `init-env.sh` pulls
  auth's public key + `INTERNAL_SERVICE_TOKEN` from it).
- Your **components infra-creds dump** in the `### NN_Service` format (paste it into `env/env.txt`).

## 1. Install OS prerequisites (PHP 8.5 + extensions + Composer)

```bash
sudo apt-get update
sudo apt-get install -y \
  php8.5-cli php8.5-pgsql php8.5-mbstring php8.5-bcmath php8.5-zip \
  php8.5-curl php8.5-xml php8.5-redis php-pear php8.5-dev \
  libpq-dev libssl-dev librdkafka-dev libcurl4-openssl-dev pkg-config \
  unzip git curl jq ca-certificates

# PECL extensions the durable-log + outbox paths need (redis comes from apt above).
sudo pecl install mongodb rdkafka
echo "extension=mongodb.so" | sudo tee /etc/php/8.5/cli/conf.d/30-mongodb.ini
echo "extension=rdkafka.so" | sudo tee /etc/php/8.5/cli/conf.d/30-rdkafka.ini
# Bare-404 hardening: no default Content-Type, no X-Powered-By.
printf 'expose_php=Off\ndefault_mimetype=\ndefault_charset=\n' | sudo tee /etc/php/8.5/cli/conf.d/50-bare-404.ini
php -m | grep -E '^(pdo_pgsql|mongodb|rdkafka|redis)$'   # all four must print

# Composer
curl -fsSL https://getcomposer.org/installer | php
sudo mv composer.phar /usr/local/bin/composer
```

> `grpc` and `elastic_apm` are **optional** natively (the gRPC client degrades to `not_configured`; logs
> still ship without the APM agent). Install them only if you need east-west gRPC / APM auto-instrumentation.

## 2. Get the code

```bash
sudo mkdir -p /opt/dokandar && sudo chown "$USER":"$USER" /opt/dokandar
git clone -b source-code git@gitlab.com:learningdevopstools/backend/03-seller.git /opt/dokandar/03-seller
cd /opt/dokandar/03-seller
```

## 3. Paste creds → render `env/.env.dev`

```bash
cp env/env.txt.example env/env.txt
nano env/env.txt          # paste the real ### NN_Service components dump
chmod 600 env/env.txt

# Render env/.env.dev. init-env.sh maps PostgreSQL → Laravel DB_*, Redis → DB 2,
# wires Kafka/Mongo/ES(:9201)/APM, and auto-pulls auth's PUBLIC key +
# INTERNAL_SERVICE_TOKEN from the deployed 01-auth. If auth runs in Docker at
# /opt/01-auth, point AUTH_ENV_FILE at it (otherwise it tries the native path):
AUTH_ENV_FILE=/opt/01-auth/env/.env.dev ./env/init-env.sh .env.dev
cat env/.env.dev          # sanity-check (SERVICE_NAME=03-seller, DB=dokandar_shop_dev, redis-db=2)
```

## 4. Build + bootstrap the database

```bash
composer install --no-dev --no-security-blocking \
  --ignore-platform-req=ext-mongodb --ignore-platform-req=ext-rdkafka

# Laravel does NOT read a .env file (SkipEnvLoader) — load the rendered env into
# the shell so artisan sees it, then bootstrap the DB (idempotent):
set -a; . env/.env.dev; set +a
php artisan shop:ensure-db          # CREATE DATABASE dokandar_shop_dev (if absent)
php artisan migrate --force         # idempotent DDL (6 tables + cube/earthdistance)
php artisan db:seed --class=BdAdminAreasSeeder --force || true   # best-effort BD geo seed

# /data snapshot (served read-only by GET /data)
chmod +x data/local/collect.sh data/cloud/collect.sh
PUBLIC_IP_LOOKUP=off data/local/collect.sh
data/cloud/collect.sh
```

## 5. Run the service

### 5a. Foreground (quick test)

```bash
cd /opt/dokandar/03-seller
set -a; . env/.env.dev; set +a
# HTTP server on the external port 10003 (native binds it directly):
php -S 0.0.0.0:10003 -t public server.php &
# Outbox relay + KYC consumer (separate processes — need rdkafka):
php artisan shop:relay-outbox --interval=2 &
php artisan shop:consume-kyc-events &
```

### 5b. systemd (persistent, recommended)

Three units — the HTTP server, the outbox relay, the KYC consumer — all sharing the rendered env via
`EnvironmentFile=`. Boot time is stamped once so `uptime_seconds` is real.

```bash
SVC=/opt/dokandar/03-seller
sudo tee /etc/systemd/system/dokandar-seller.service >/dev/null <<EOF
[Unit]
Description=DOKANDAR 03-seller (PHP/Laravel, native php -S)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$SVC
EnvironmentFile=$SVC/env/.env.dev
ExecStartPre=/bin/sh -c 'date +%s > /tmp/dokandar-seller.boot'
ExecStart=/usr/bin/php -S 0.0.0.0:10003 -t public server.php
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/dokandar-seller-relay.service >/dev/null <<EOF
[Unit]
Description=DOKANDAR 03-seller outbox relay (Kafka)
After=network-online.target dokandar-seller.service
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$SVC
EnvironmentFile=$SVC/env/.env.dev
ExecStart=/usr/bin/php artisan shop:relay-outbox --interval=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/dokandar-seller-kyc.service >/dev/null <<EOF
[Unit]
Description=DOKANDAR 03-seller KYC events consumer (Kafka)
After=network-online.target dokandar-seller.service
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$SVC
EnvironmentFile=$SVC/env/.env.dev
ExecStart=/usr/bin/php artisan shop:consume-kyc-events
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now dokandar-seller dokandar-seller-relay dokandar-seller-kyc
sudo systemctl status --no-pager dokandar-seller
```

## Verify

```bash
curl -s http://localhost:10003/ready  | jq .identity         # service_name=03-seller, postgres-only gate
curl -s http://localhost:10003/health | jq '.checks | keys'  # postgres,redis,kafka,mongo_logs,apm (+grpc_* diag)
curl -sI http://localhost:10003/nope                         # bare 404: Content-Length: 0, NO Content-Type
curl -s http://localhost:10003/openapi.json | jq -r .info.title  # DOKANDAR Seller Service
curl -s http://localhost:10003/metrics | grep '^seller_'     # seller_outbox_pending etc.

# Cross-service JWT acceptance (the real gate — /health can't catch a key mismatch):
TOK=$(curl -s -X POST http://<host>:10001/api/v1/auth/login/request -d '{"phone":"01700000000"}' >/dev/null; \
      echo "see smoke_test/test.sh for the full signup/verify mint flow")
# Then: curl -H "Authorization: Bearer $TOK" -X POST http://localhost:10003/api/v1/shop/shops … → 201 (not 401)

# Full contract + cross-service harness (mints via auth, recovers OTP via support):
./smoke_test/test.sh        # PASS / 0 FAIL expected
```

## Operate

```bash
journalctl -u dokandar-seller -f                 # http server logs (uvicorn-style access line)
journalctl -u dokandar-seller-relay -u dokandar-seller-kyc -f   # relay + consumer
sudo systemctl restart dokandar-seller dokandar-seller-relay dokandar-seller-kyc
# Re-render env then restart (e.g. after auth rotates its keypair):
AUTH_ENV_FILE=/opt/01-auth/env/.env.dev ./env/init-env.sh .env.dev && sudo systemctl restart dokandar-seller*
```

Logs land on **stdout (pretty JSON)** + **MongoDB `mongo_db_dokandar_application_logs.03-seller`** +
**Elasticsearch `logs-app-03-seller-*`**; traces under APM service **`03-seller`**.

## Security notes

- `env/.env.dev`, `env/env.txt`, `env/components-creds.txt` are **gitignored** — real secrets never commit.
- Verify-only: this service holds auth's **public** key + `INTERNAL_SERVICE_TOKEN` only — never the private key.
- `SERVICE_NAME` is sourced from env (fail-fast if empty); RS256 verified with an explicit `['RS256']` allowlist.
- Public shop pages strip owner PII (phone/email/owner_id); KYC binaries live admin-only in `12-media`.

## See also

- [`architecture.md`](architecture.md) — the full design + §16 stack-landmine checklist.
- [`commands.md`](commands.md) — the Docker deploy path.
- [`../../architecture.md`](../../architecture.md) §21 — the event + gRPC cross-service anchor.
