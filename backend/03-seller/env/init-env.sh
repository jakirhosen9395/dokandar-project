#!/usr/bin/env bash
# env/init-env.sh — render env/.env.<env> for 03-seller from env/components-creds.txt
#
# 03-seller (PHP 8.5 / Laravel 13) is VERIFY-ONLY: it needs auth's PUBLIC key +
# the shared INTERNAL_SERVICE_TOKEN (NEVER a private key). This script:
#   1. parses infra creds from env/components-creds.txt (### NN_Service format —
#      paste the "components" status dump there),
#   2. maps PostgreSQL into Laravel-native DB_* vars (Laravel reads DB_HOST /
#      DB_DATABASE / … , not a single DSN),
#   3. reads the application LOG-SINK Elasticsearch from the APM-stack ES
#      (block 07_Elastic_APM `elasticsearch` :9200 line + `elastic-pass`) — NOT
#      block 03 (:9201), which is the search/review business ES used only by
#      05-search + 08-review,
#   4. pulls auth's PUBLIC key + the shared INTERNAL_SERVICE_TOKEN from the
#      `### Auth_Identity` block of components-creds.txt, falling back to
#      $AUTH_PUBLIC_KEY_B64 / $AUTH_INTERNAL_TOKEN env vars, else $AUTH_ENV_FILE
#      (auto-tries /opt/dokandar/01-auth then /opt/01-auth). It NEVER generates
#      a keypair — only 01-auth mints these.
#   5. writes env/.env.<env> (chmod 600, gitignored) with a fresh APP_KEY.
#
# Bounded-context note: the DB stays named dokandar_shop_<env> and routes stay
# /api/v1/shop/* — only the identity (SERVICE_NAME) is 03-seller.
#
# Reads infra blocks: 01_PostgreSQL 02_MongoDB 04_Redis 05_Kafka 07_Elastic_APM
# (+ the Auth_Identity block). (03_Elasticsearch :9201, 06_RabbitMQ, 10_RustFS
# are NOT used by seller.)
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
# Peer host for east-west gRPC (auth staff-verify, media presign, coupon) — the docker-bridge
# gateway reaches host-published 200NN peer ports on a single-host deploy. Override PEER_HOST/
# APP_HOST for split-host/mesh. (NOT a hardcoded peer address — the app reads the env.)
PEER_HOST="${PEER_HOST:-${APP_HOST:-172.17.0.1}}"
MO_URI=$(gv 02_MongoDB endpoint)
RE_PASS=$(gv 04_Redis password)
KAFKA=$(gv 05_Kafka bootstrap)
# ---- Elasticsearch LOG SINK: APM-stack ES (block 07, :9200) ------------------
# NOT block 03 (:9201) — that ES is the search/review business store (05/08 only).
ES_RAW=$(gv 07_Elastic_APM elasticsearch)            # http://elastic:<pass>@<host>:9200
ES_PASS=$(gv 07_Elastic_APM elastic-pass)
ES_HP="${ES_RAW##*@}"                                # <host>:9200
_es_user_tmp="${ES_RAW#*://}"; ES_USER="${_es_user_tmp%%:*}"   # elastic
ES_URL="http://${ES_HP}"
# ---- Elastic APM (traces) ---------------------------------------------------
APM_URL=$(gv 07_Elastic_APM apm-ingest); APM_BEARER=$(gv 07_Elastic_APM apm-token)

for v in PG_HP PG_USER PG_PASS INFRA PG_PORT MO_URI RE_PASS KAFKA ES_URL ES_USER ES_PASS APM_URL APM_BEARER; do
  eval "x=\${$v:-}"; [ -n "$x" ] || { echo "ERROR: could not parse $v from $ENVTXT" >&2; exit 3; }
done

# ---- auth's PUBLIC key + shared INTERNAL_SERVICE_TOKEN (verify-only) ---------
# Primary source: the `### Auth_Identity` block of components-creds.txt
# (auth_service_public_key / internal_service_token). Falls back to env vars or
# auth's rendered .env.dev. NEVER generates a keypair — only 01-auth mints these.
JWT_PUB=$(gv Auth_Identity auth_service_public_key)
INT_TOK=$(gv Auth_Identity internal_service_token)
# treat an unfilled <placeholder> as empty so the AUTH_ENV_FILE fallback engages
case "$JWT_PUB" in '<'*) JWT_PUB="";; esac
case "$INT_TOK" in '<'*) INT_TOK="";; esac
JWT_PUB="${AUTH_PUBLIC_KEY_B64:-$JWT_PUB}"
INT_TOK="${AUTH_INTERNAL_TOKEN:-$INT_TOK}"
AUTH_ENV_FILE="${AUTH_ENV_FILE:-}"
if [ -z "$AUTH_ENV_FILE" ]; then
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
[ -n "$JWT_PUB" ] || { echo "ERROR: no JWT public key. Paste auth's JWT_PUBLIC_KEY_B64 into the ### Auth_Identity block of components-creds.txt, or set AUTH_PUBLIC_KEY_B64=… / AUTH_ENV_FILE=path to auth's rendered .env.dev." >&2; exit 3; }
[ -n "$INT_TOK" ] || { echo "ERROR: no INTERNAL_SERVICE_TOKEN. Paste auth's value into the ### Auth_Identity block of components-creds.txt, or set AUTH_INTERNAL_TOKEN=… / AUTH_ENV_FILE." >&2; exit 3; }

DB="dokandar_shop_${SUF}"
APP_KEY_VAL="base64:$(openssl rand -base64 32)"
OUT="$HERE/$TARGET"; umask 077
cat > "$OUT" <<EOF
# ============================================================================
#  env/${TARGET}  —  rendered by env/init-env.sh  from  env/components-creds.txt
#  REAL SECRETS · gitignored · never commit · re-run init-env.sh to rotate APP_KEY
#  legend —  get: copied from a components-creds.txt  "### NN_block"
#            gen: generated locally on every run (one-line command shown)
# ============================================================================

# -- Application / identity --------------------------------------------------
# get: static; APP_ENV from the .env.<env> target, TENANT=local(dev)/cloud(stage|prod)
# gen: APP_KEY  ->  base64: + openssl rand -base64 32
APP_NAME=dokandar-seller
APP_ENV=${SUF}
APP_KEY=${APP_KEY_VAL}
APP_DEBUG=false
SERVICE_NAME=03-seller
ENV_VERSION=v1.0.0
TENANT=${TENANT}
SERVICE_PORT=8000
LOG_LEVEL=info
LOG_STACK=stdout,mongo,es

# -- PostgreSQL (Laravel-native DB_*; bounded-context name stays "shop") ------
# get: components-creds.txt  ### 01_PostgreSQL  (host:port / user / password)
# note: DB_DATABASE = dokandar_shop_<env>
DB_CONNECTION=pgsql
DB_HOST=${INFRA}
DB_PORT=${PG_PORT}
DB_DATABASE=${DB}
DB_USERNAME=${PG_USER}
DB_PASSWORD=${PG_PASS}

# -- Redis (DB 2 handle cache · DB 9 prometheus metric store) ----------------
# get: components-creds.txt  ### 04_Redis  (password)
# NOTE: metrics moved DB 3 → 9 to keep the fleet logical-DB map DISJOINT — 04-catalog
# owns DB 3 (hot read cache). DB 9 is unallocated. (fleet-integration-matrix.md §5)
REDIS_CLIENT=predis
REDIS_HOST=${INFRA}
REDIS_PORT=6379
REDIS_PASSWORD=${RE_PASS}
REDIS_DB=2
REDIS_METRICS_DB=9

# -- Kafka (emits dokandar.shop.* via outbox; consumes dokandar.kyc.*) -------
# get: components-creds.txt  ### 05_Kafka  (bootstrap)
KAFKA_BOOTSTRAP=${KAFKA}
KAFKA_CONSUMER_GROUP=seller

# -- Log sinks: Mongo + Elasticsearch log sink (APM-stack ES, block 07 :9200) -
# get: components-creds.txt  ### 02_MongoDB  (endpoint)  +  ### 07_Elastic_APM  (elasticsearch :9200 + elastic-pass)
# note: NOT block 03 (:9201) — that ES is the search/review business store
MONGO_LOG_URI=${MO_URI}
MONGO_LOG_DB=mongo_db_dokandar_application_logs
ELASTIC_SEARCH_URL=${ES_URL}
ELASTIC_SEARCH_USERNAME=${ES_USER}
ELASTIC_SEARCH_PASSWORD=${ES_PASS}

# -- Elastic APM (traces) ----------------------------------------------------
# get: components-creds.txt  ### 07_Elastic_APM  (apm-ingest :8200 + apm-token)
APM_SERVER_URL=${APM_URL}
APM_SECRET_TOKEN=${APM_BEARER}
APM_SERVICE_NAME=03-seller

# -- JWT verify-only (auth's PUBLIC key) + east-west token -------------------
# get: components-creds.txt  ### Auth_Identity  (auth_service_public_key / internal_service_token) — verify-only, never minted here
JWT_PUBLIC_KEY_B64=${JWT_PUB}
JWT_ISSUER=dokandar-auth
JWT_AUDIENCE=
INTERNAL_SERVICE_TOKEN=${INT_TOK}

# -- East-west gRPC clients (auth @20001 · media @20012 · coupon @20007) ------
# get: PEER_HOST (docker-bridge default, overridable) + the fleet-constant ext gRPC ports.
# Ports are the EXTERNAL 200NN mappings (auth in-ctr 8001→20001, media 50051→20012, coupon 9090→20007).
AUTH_GRPC_HOST=${PEER_HOST}
AUTH_GRPC_PORT=20001
MEDIA_GRPC_HOST=${PEER_HOST}
MEDIA_GRPC_PORT=20012
COUPON_GRPC_HOST=${PEER_HOST}
COUPON_GRPC_PORT=20007
EOF
chmod 600 "$OUT"
echo "✓ wrote $OUT"
echo "  SERVICE_NAME=03-seller  DB=$DB  INFRA=$INFRA  REST(in-container)=8000 ext=10003  redis-db=2  no gRPC server"
echo "  ES log sink=$ES_URL (block 07 :9200)   APM=$APM_URL   Kafka=$KAFKA"
echo "  JWT public key + INTERNAL_SERVICE_TOKEN: verify-only (no private key) — from Auth_Identity / env / ${AUTH_ENV_FILE:-<none>}"
