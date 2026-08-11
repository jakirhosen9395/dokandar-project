# `04-catalog` — Product Graph (CQRS write side) + multi-level stock

**Java 25 · Spring Boot 4.0 · PostgreSQL · Redis · Kafka · MongoDB · Elasticsearch · Elastic APM · gRPC**

The CQRS **write model** and source of truth for the product graph + the authoritative stock ledger:
products, variants, per-shop listings, categories (tree), multi-level stock (`shared` / `per_shop_copy`),
and **idempotent gRPC stock reservation/release** for the checkout saga. Verify-only (RS256), emit-only
events (`dokandar.product.changed` / `.category.changed` / `.stock.low` via a transactional outbox).
gRPC-first: `Catalog.GetProduct | CheckStock | ReserveStock | ReleaseStock @ 9090`.

- **Design doc:** [`architecture.md`](architecture.md) — the full build contract (data model, stock flows, §16 landmines).
- **This README:** copy-paste **native** install (no Docker). Docker path: [`commands.md`](commands.md).

> **Verified deploy.** Ubuntu 26.04 · JDK 25 · components host `172.31.13.161` · `/health` all deps `ok` ·
> acceptance: auth-minted JWT → `POST /api/v1/catalog/products` 201, a customer token → `403 insufficient_role`,
> `dokandar.product.changed` published via the outbox relay, gRPC `ReserveStock` idempotent.

> **Build notes.** Schema is applied by `DbBootstrap` as **idempotent raw DDL** (`CREATE … IF NOT EXISTS`) — the
> proven Java-fleet pattern (13-order), not Flyway. The Elastic APM agent attaches via `-javaagent` (Family B).

---

## 0. What you need

- A Linux host (Ubuntu 26.04) reachable to the components host (PostgreSQL/Redis/Kafka/Mongo/ES/APM).
- **`01-auth` already deployed and reachable** (catalog verifies auth-issued JWTs; `init-env.sh` pulls auth's
  public key + `INTERNAL_SERVICE_TOKEN` from it).
- Your **components infra-creds dump** in the `### NN_Service` format (paste into `env/components-creds.txt`).

## 1. Install OS prerequisites (JDK 25 + Maven)

```bash
sudo apt-get update
sudo apt-get install -y openjdk-25-jdk-headless maven curl jq git ca-certificates
sudo update-alternatives --set java  "$(ls -d /usr/lib/jvm/java-25-openjdk-*/bin/java  | head -1)" || true
sudo update-alternatives --set javac "$(ls -d /usr/lib/jvm/java-25-openjdk-*/bin/javac | head -1)" || true
java -version    # openjdk 25.x
mvn -version
```

## 2. Get the code

```bash
sudo mkdir -p /opt/dokandar && sudo chown "$USER":"$USER" /opt/dokandar
git clone -b source-code git@gitlab.com:learningdevopstools/backend/04-catalog.git /opt/dokandar/04-catalog
cd /opt/dokandar/04-catalog
```

## 3. Paste creds → render `env/.env.dev`

```bash
cp env/components-creds.example.txt env/components-creds.txt
nano env/components-creds.txt        # paste the real ### NN_Service components dump
chmod 600 env/components-creds.txt

# Render env/.env.dev. init-env.sh maps PostgreSQL → discrete POSTGRES_*, Redis → DB 3,
# wires Kafka/Mongo/ES(:9201)/APM (+ the elastic-apm ELASTIC_APM_* set), and auto-pulls
# auth's PUBLIC key + INTERNAL_SERVICE_TOKEN from the deployed 01-auth. If auth runs in
# Docker at /opt/01-auth, point AUTH_ENV_FILE at it (otherwise it tries the native path):
AUTH_ENV_FILE=/opt/01-auth/env/.env.dev ./env/init-env.sh .env.dev
cat env/.env.dev          # sanity: SERVICE_NAME=04-catalog, POSTGRES_DB=dokandar_catalog_dev, redis-db=3
```

## 4. Build + the APM agent + /data snapshot

```bash
mvn -B -ntp -DskipTests clean package        # builds target/catalog.jar (runs gRPC codegen)

# Elastic APM Java agent (attached via -javaagent so traces always finalize, §11.3):
curl -fsSL -o /opt/dokandar/04-catalog/elastic-apm-agent.jar \
  https://repo1.maven.org/maven2/co/elastic/apm/elastic-apm-agent/1.55.6/elastic-apm-agent-1.55.6.jar

# /data snapshot (served read-only by GET /data)
chmod +x data/local/collect.sh data/cloud/collect.sh
PUBLIC_IP_LOOKUP=off data/local/collect.sh
data/cloud/collect.sh
```

## 5. Run the service (systemd — one JVM: REST + gRPC + outbox relay + sweeper)

`DbBootstrap` creates `dokandar_catalog_dev` and applies the schema on first boot. The app reads `.env.dev` via
`EnvironmentFile=`; the boot time is stamped so `uptime_seconds` is real.

```bash
SVC=/opt/dokandar/04-catalog
sudo tee /etc/systemd/system/dokandar-catalog.service >/dev/null <<EOF
[Unit]
Description=DOKANDAR 04-catalog (Java 25 / Spring Boot 4, REST + gRPC + outbox relay)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$SVC
EnvironmentFile=$SVC/env/.env.dev
ExecStart=/usr/bin/java -javaagent:$SVC/elastic-apm-agent.jar -jar $SVC/target/catalog.jar
Restart=on-failure
RestartSec=5
SuccessExitStatus=143

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now dokandar-catalog
sudo systemctl status --no-pager dokandar-catalog
```

## Verify

```bash
curl -s http://localhost:10004/ready  | jq .identity            # service_name=04-catalog, postgres-only gate
curl -s http://localhost:10004/health | jq '.checks | keys'     # postgres,redis,kafka,mongo_logs,apm (+grpc_media diag)
curl -sI http://localhost:10004/nope                            # bare 404: Content-Length: 0, NO Content-Type
curl -s http://localhost:10004/openapi.json | jq -r .info.title # DOKANDAR Catalog Service
curl -s http://localhost:10004/metrics | grep '^catalog_'       # catalog_* + catalog_outbox_pending
ss -ltnp | grep -E '10004|20004'                                # REST 10004 + gRPC 20004 listening

# Cross-service contract + acceptance harness (mints via auth :10001, recovers OTP via support :10099):
./smoke_test/test.sh        # PASS / 0 FAIL expected
```

## Operate

```bash
journalctl -u dokandar-catalog -f
sudo systemctl restart dokandar-catalog
# Re-render env then restart (e.g. after auth rotates its keypair):
AUTH_ENV_FILE=/opt/01-auth/env/.env.dev ./env/init-env.sh .env.dev && sudo systemctl restart dokandar-catalog
```

Logs land on **stdout (pretty JSON)** + **MongoDB `mongo_db_dokandar_application_logs.04-catalog`** +
**Elasticsearch `logs-app-04-catalog-*`**; traces under APM service **`04-catalog`** (version from `CODE_VERSION`).

## Security notes

- `env/.env.dev`, `env/components-creds.txt`, `env/env.txt` are **gitignored** — real secrets never commit.
- Verify-only: this service holds auth's **public** key + `INTERNAL_SERVICE_TOKEN` only — never the private key.
- `SERVICE_NAME` is sourced from env (fail-fast if empty); RS256 verified with an explicit `RS256` allowlist, `iss`
  checked, `aud` **not** enforced (the deployed auth mints none). gRPC `x-internal-token` is compared constant-time.
- Money is integer minor units; a value above `INT4` max is rejected `422` before it can overflow.

## See also

- [`architecture.md`](architecture.md) — the full design + §16 stack-landmine checklist.
- [`commands.md`](commands.md) — the Docker deploy path.
- [`../architecture.md`](../architecture.md) §21 — the event + gRPC cross-service anchor.
