#!/usr/bin/env bash
# env/init-env.sh — render env/.env.<env> for 13-order from the components dump
#
# 13-order (Java 25 / Spring Boot 4 + Temporal) is VERIFY-ONLY: it needs auth's
# PUBLIC key + the shared INTERNAL_SERVICE_TOKEN (NEVER a private key). This script:
#   1. parses infra creds from env/components-creds.txt in the '### NN_Service'
#      format (paste your "components" status dump there),
#   2. emits discrete POSTGRES_* (DbBootstrap + the Spring JDBC url read them),
#      Redis DB 7 (arbitration locks), the Temporal saga client (block 16),
#      Kafka, the Mongo+ES log sinks, and BOTH the app APM vars and the
#      elastic-apm -javaagent ELASTIC_APM_* vars (incl. SERVICE_VERSION),
#   3. pulls JWT_PUBLIC_KEY_B64 + INTERNAL_SERVICE_TOKEN from the
#      '### Auth_Identity' block of components-creds.txt, falling back to the
#      already-deployed 01-auth via $AUTH_ENV_FILE / $AUTH_PUBLIC_KEY_B64,
#   4. writes env/.env.<env> (chmod 600, gitignored).
#
# Reads infra blocks: 01_PostgreSQL 02_MongoDB 04_Redis 05_Kafka 07_Elastic_APM 16_Temporal.
# The application LOG-SINK Elasticsearch is the APM-stack ES (block 07,
# `elasticsearch` :9200 line + `elastic-pass`) — NOT block 03 (:9201), which is
# the search/review business ES used ONLY by 05-search + 08-review. Other blocks
# may be present; they are ignored.
#
# Usage:  ./env/init-env.sh                          # -> env/.env.dev
#         ./env/init-env.sh .env.stage
#         AUTH_PUBLIC_KEY_B64=… AUTH_INTERNAL_TOKEN=… ./env/init-env.sh .env.dev
#         AUTH_ENV_FILE=/opt/01-auth/env/.env.dev ./env/init-env.sh .env.dev
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-.env.dev}"; TARGET="${TARGET##*/}"
case "$TARGET" in .env.*) ;; *) echo "ERROR: target must be .env.<env>" >&2; exit 2;; esac
SUF="${TARGET#.env.}"; [ "$SUF" = "dev" ] && TENANT="local" || TENANT="cloud"

ENVTXT="${CREDS_FILE:-}"
if [ -z "$ENVTXT" ]; then
  for f in "$HERE/components-creds.txt"; do [ -f "$f" ] && { ENVTXT="$f"; break; }; done
fi
[ -n "$ENVTXT" ] && [ -f "$ENVTXT" ] || { echo "ERROR: no creds file (env/components-creds.txt). See env/components-creds.example.txt." >&2; exit 2; }

gv(){ awk -v hdr="$1" -v key="$2" '
  $0 ~ "^###[[:space:]]+"hdr"([[:space:]]|$)" { on=1; next }
  on && /^###/ { exit }
  on && $1==key { print $2; exit }
' "$ENVTXT"; }
port_of(){ printf '%s' "${1##*:}"; }; host_of(){ printf '%s' "${1%:*}"; }

echo "→ parsing $ENVTXT" >&2

PG_HP=$(gv 01_PostgreSQL host:port); PG_USER=$(gv 01_PostgreSQL user); PG_PASS=$(gv 01_PostgreSQL password)
INFRA=$(host_of "$PG_HP"); PG_PORT=$(port_of "$PG_HP")
# Peer host for the checkout saga's east-west calls — the docker-bridge gateway reaches
# host-published 100NN/200NN peer ports on a single-host deploy. Override PEER_HOST/APP_HOST
# for split-host/mesh topologies. (NOT a hardcoded peer address — the app reads the env.)
PEER_HOST="${PEER_HOST:-${APP_HOST:-172.17.0.1}}"
MO_URI=$(gv 02_MongoDB endpoint)
RE_HP=$(gv 04_Redis host:port); RE_PASS=$(gv 04_Redis password); RE_PORT=$(port_of "$RE_HP")
KAFKA=$(gv 05_Kafka bootstrap)
TEMPORAL_HP=$(gv 16_Temporal grpc)                   # <host>:7233 (saga state)

# ---- Elastic-APM (block 07) — APM ingest/bearer + the APM-stack Elasticsearch -
# The application log sink ships into the APM-stack ES (:9200 — the block-07
# `elasticsearch` line + `elastic-pass`). Block 03 (:9201) is NOT read here.
APM_URL=$(gv 07_Elastic_APM apm-ingest); APM_BEARER=$(gv 07_Elastic_APM apm-token)
ES_RAW=$(gv 07_Elastic_APM elasticsearch)            # http://elastic:<pass>@<host>:9200
ES_PASS=$(gv 07_Elastic_APM elastic-pass)
ES_HP="${ES_RAW##*@}"                                # <host>:9200
_es_user_tmp="${ES_RAW#*://}"; ES_USER="${_es_user_tmp%%:*}"   # elastic
ES_URL="http://${ES_HP}"

for v in PG_HP PG_USER PG_PASS INFRA PG_PORT MO_URI RE_PASS RE_PORT KAFKA TEMPORAL_HP ES_URL ES_USER ES_PASS APM_URL APM_BEARER; do
  eval "x=\${$v:-}"; [ -n "$x" ] || { echo "ERROR: could not parse $v from $ENVTXT" >&2; exit 3; }
done

# ---- auth's PUBLIC key + shared INTERNAL_SERVICE_TOKEN (verify-only) ---------
# Primary source: the '### Auth_Identity' block of components-creds.txt.
# Fallback: $AUTH_PUBLIC_KEY_B64 / $AUTH_INTERNAL_TOKEN env vars, else the
# deployed 01-auth's rendered .env.dev via $AUTH_ENV_FILE (auto-discovery).
JWT_PUB="${AUTH_PUBLIC_KEY_B64:-}"
INT_TOK="${AUTH_INTERNAL_TOKEN:-}"
[ -n "$JWT_PUB" ] || JWT_PUB=$(gv Auth_Identity auth_service_public_key)
[ -n "$INT_TOK" ] || INT_TOK=$(gv Auth_Identity internal_service_token)
case "$JWT_PUB" in "<"*">"|"") JWT_PUB="";; esac          # ignore placeholder
case "$INT_TOK" in "<"*">"|"") INT_TOK="";; esac
AUTH_ENV_FILE="${AUTH_ENV_FILE:-}"
if { [ -z "$JWT_PUB" ] || [ -z "$INT_TOK" ]; } && [ -z "$AUTH_ENV_FILE" ]; then
  for f in /opt/dokandar/01-auth/env/.env.dev /opt/01-auth/env/.env.dev; do
    [ -f "$f" ] && { AUTH_ENV_FILE="$f"; break; }
  done
fi
if [ -z "$JWT_PUB" ] && [ -n "$AUTH_ENV_FILE" ] && [ -f "$AUTH_ENV_FILE" ]; then
  JWT_PUB=$(grep -E '^JWT_PUBLIC_KEY_B64=' "$AUTH_ENV_FILE" | head -1 | cut -d= -f2-)   # PUBLIC only — never the private key
fi
if [ -z "$INT_TOK" ] && [ -n "$AUTH_ENV_FILE" ] && [ -f "$AUTH_ENV_FILE" ]; then
  INT_TOK=$(grep -E '^INTERNAL_SERVICE_TOKEN=' "$AUTH_ENV_FILE" | head -1 | cut -d= -f2-)
fi
[ -n "$JWT_PUB" ] || { echo "ERROR: no JWT public key. Paste auth's JWT_PUBLIC_KEY_B64 into the '### Auth_Identity' block of components-creds.txt, set AUTH_PUBLIC_KEY_B64=…, or AUTH_ENV_FILE=path to auth's rendered .env.dev." >&2; exit 3; }
[ -n "$INT_TOK" ] || { echo "ERROR: no INTERNAL_SERVICE_TOKEN. Paste auth's value into the '### Auth_Identity' block of components-creds.txt, set AUTH_INTERNAL_TOKEN=…, or AUTH_ENV_FILE." >&2; exit 3; }

DB="dokandar_order_${SUF}"
CODE_VERSION="$(cat "$HERE/../CODE_VERSION" 2>/dev/null | tr -d ' \n\r' || echo 13-order)"
OUT="$HERE/$TARGET"; umask 077
cat > "$OUT" <<EOF
# ============================================================================
#  env/${TARGET}  —  rendered by env/init-env.sh  from  env/components-creds.txt
#  REAL SECRETS · gitignored · never commit · re-run init-env.sh to refresh from auth
#  legend —  get: copied from a components-creds.txt  "### NN_block"
#            gen: generated locally on every run (one-line command shown)
# ============================================================================

# -- Application / identity --------------------------------------------------
# get: static; APP_ENV from the .env.<env> target, TENANT=local(dev)/cloud(stage|prod)
# note: SERVICE_PORT/GRPC_PORT are the INTERNAL bind ports (Tomcat 8080 / gRPC 9090);
#       docker publishes them as -p 10013:8080 -p 20013:9090
APP_ENV=${SUF}
SERVICE_NAME=13-order
ENV_VERSION=v1.0.0
TENANT=${TENANT}
SERVICE_PORT=8080
GRPC_PORT=9090
GRPC_ENABLED=true
LOG_LEVEL=info

# -- PostgreSQL (DbBootstrap + Spring JDBC read discrete POSTGRES_* vars) ----
# get: components-creds.txt  ### 01_PostgreSQL  (host:port / user / password)
# note: POSTGRES_DB = dokandar_order_<env>; the *_DSN is built from the block + DB name
POSTGRES_HOST=${INFRA}
POSTGRES_PORT=${PG_PORT}
POSTGRES_USER=${PG_USER}
POSTGRES_PASSWORD=${PG_PASS}
POSTGRES_DB=${DB}
POSTGRES_ADMIN_DSN=postgresql://${PG_USER}:${PG_PASS}@${INFRA}:${PG_PORT}/postgres

# -- Redis DB 7 (arbitration locks; degradable — does NOT gate /ready) -------
# get: components-creds.txt  ### 04_Redis  (host:port / password)
REDIS_HOST=${INFRA}
REDIS_PORT=${RE_PORT}
REDIS_PASSWORD=${RE_PASS}
REDIS_DB=7
REDIS_URL=redis://default:${RE_PASS}@${INFRA}:${RE_PORT}/7

# -- Temporal (saga state; reported on /health, NOT a /ready gate) -----------
# get: components-creds.txt  ### 16_Temporal  (grpc)
# TEMPORAL_TARGET is the canonical var (the app prefers it, then TEMPORAL_HOST, then a safe
# local default); TEMPORAL_HOST is kept for back-compat. Both = the endpoint from block 16_Temporal.
TEMPORAL_TARGET=${TEMPORAL_HP}
TEMPORAL_HOST=${TEMPORAL_HP}
TEMPORAL_NAMESPACE=dokandar-order
TEMPORAL_TASK_QUEUE=checkout-saga

# -- Kafka (emit via outbox relay, acks=all; consume payment.settled) --------
# get: components-creds.txt  ### 05_Kafka  (bootstrap);  topic names below are fixed
KAFKA_BOOTSTRAP=${KAFKA}
KAFKA_CONSUMER_GROUP=order
KAFKA_TOPIC_ORDER_PLACED=dokandar.order.placed
KAFKA_TOPIC_ORDER_CONFIRMED=dokandar.order.confirmed
KAFKA_TOPIC_ORDER_STATUS_CHANGED=dokandar.order.status_changed
KAFKA_TOPIC_ORDER_DELIVERED=dokandar.order.delivered
KAFKA_TOPIC_ORDER_REFUNDED=dokandar.order.refunded
KAFKA_TOPIC_ORDER_CANCELLED=dokandar.order.cancelled
KAFKA_TOPIC_PAYMENT_SETTLED=dokandar.payment.settled

# -- East-west: the saga gRPC clients + internal REST to payment -------------
# get: PEER_HOST (docker-bridge default, overridable) + the fleet-constant ext ports
# (catalog gRPC 20004 · coupon gRPC 20007 · wallet gRPC 20010 · payment REST 10009)
CATALOG_GRPC_ADDR=${PEER_HOST}:20004
COUPON_GRPC_ADDR=${PEER_HOST}:20007
WALLET_GRPC_ADDR=${PEER_HOST}:20010
PAYMENT_REST_URL=http://${PEER_HOST}:10009

# -- Log sinks: Mongo + Elasticsearch log sink: APM-stack ES (:9200) ---------
# get: components-creds.txt  ### 02_MongoDB (endpoint) + ### 07_Elastic_APM (elasticsearch :9200 + elastic-pass)
# note: NOT block 03 (:9201) — that ES is the search/review business store
MONGO_LOG_URI=${MO_URI}
MONGO_LOG_DB=mongo_db_dokandar_application_logs
ELASTIC_SEARCH_URL=${ES_URL}
ELASTIC_SEARCH_USERNAME=${ES_USER}
ELASTIC_SEARCH_PASSWORD=${ES_PASS}

# -- Elastic APM (traces; -javaagent reads the ELASTIC_APM_* set) ------------
# get: components-creds.txt  ### 07_Elastic_APM  (apm-ingest :8200 + apm-token)
# note: SERVICE_VERSION wired from CODE_VERSION — arch §16
APM_SERVER_URL=${APM_URL}
APM_SECRET_TOKEN=${APM_BEARER}
APM_SERVICE_NAME=13-order
ELASTIC_APM_SERVER_URL=${APM_URL}
ELASTIC_APM_SECRET_TOKEN=${APM_BEARER}
ELASTIC_APM_SERVICE_NAME=13-order
ELASTIC_APM_SERVICE_VERSION=${CODE_VERSION}
ELASTIC_APM_ENVIRONMENT=${SUF}
# Required for the agent to weave @CaptureTransaction on the Temporal saga activities
# (worker threads have no HTTP tx → their gRPC/JDBC/Kafka calls would be dropped orphan spans).
ELASTIC_APM_APPLICATION_PACKAGES=com.dokandar.order

# -- JWT verify-only (auth's PUBLIC key) + east-west token -------------------
# get: components-creds.txt  ### Auth_Identity  (auth_service_public_key / internal_service_token)
JWT_PUBLIC_KEY_B64=${JWT_PUB}
JWT_ISSUER=dokandar-auth
INTERNAL_SERVICE_TOKEN=${INT_TOK}
EOF
chmod 600 "$OUT"
echo "✓ wrote $OUT"
echo "  SERVICE_NAME=13-order  POSTGRES_DB=$DB  INFRA=$INFRA  REST=8080 gRPC=9090 (internal; -p 10013:8080 -p 20013:9090)  redis-db=7"
echo "  Temporal=$TEMPORAL_HP  ES log sink=$ES_URL   APM=$APM_URL   Kafka=$KAFKA"
echo "  JWT public key + INTERNAL_SERVICE_TOKEN: verify-only (no private key)"
