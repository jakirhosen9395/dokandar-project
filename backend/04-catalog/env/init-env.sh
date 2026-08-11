#!/usr/bin/env bash
# env/init-env.sh — render env/.env.<env> for 04-catalog from the components dump
#
# 04-catalog (Java 25 / Spring Boot 4) is VERIFY-ONLY: it needs auth's PUBLIC key
# + the shared INTERNAL_SERVICE_TOKEN (NEVER a private key). This script:
#   1. parses infra creds from env/components-creds.txt in the '### NN_Service'
#      format (paste your "components" status dump there),
#   2. emits discrete POSTGRES_* (DbBootstrap + the Spring JDBC url read them),
#      Redis DB 3, Kafka, the Mongo+ES log sinks, and BOTH the app APM vars and
#      the elastic-apm -javaagent ELASTIC_APM_* vars (incl. SERVICE_VERSION),
#   3. pulls JWT_PUBLIC_KEY_B64 + INTERNAL_SERVICE_TOKEN from the
#      '### Auth_Identity' block of components-creds.txt, falling back to the
#      already-deployed 01-auth via $AUTH_ENV_FILE / $AUTH_PUBLIC_KEY_B64,
#   4. writes env/.env.<env> (chmod 600, gitignored).
#
# Reads infra blocks: 01_PostgreSQL 02_MongoDB 04_Redis 05_Kafka 07_Elastic_APM.
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
# Peer host for east-west calls — the docker-bridge gateway reaches host-published
# 100NN/200NN peer ports on a single-host deploy. Override PEER_HOST/APP_HOST for a
# split-host or service-mesh topology. (NOT a hardcoded peer address — the app reads the env.)
PEER_HOST="${PEER_HOST:-${APP_HOST:-172.17.0.1}}"
MO_URI=$(gv 02_MongoDB endpoint)
RE_PASS=$(gv 04_Redis password)
KAFKA=$(gv 05_Kafka bootstrap)

# ---- Elastic-APM (block 07) — APM ingest/bearer + the APM-stack Elasticsearch -
# The application log sink ships into the APM-stack ES (:9200 — the block-07
# `elasticsearch` line + `elastic-pass`). Block 03 (:9201) is NOT read here.
APM_URL=$(gv 07_Elastic_APM apm-ingest); APM_BEARER=$(gv 07_Elastic_APM apm-token)
ES_RAW=$(gv 07_Elastic_APM elasticsearch)            # http://elastic:<pass>@<host>:9200
ES_PASS=$(gv 07_Elastic_APM elastic-pass)
ES_HP="${ES_RAW##*@}"                                # <host>:9200
_es_user_tmp="${ES_RAW#*://}"; ES_USER="${_es_user_tmp%%:*}"   # elastic
ES_URL="http://${ES_HP}"

for v in PG_HP PG_USER PG_PASS INFRA PG_PORT MO_URI RE_PASS KAFKA ES_URL ES_USER ES_PASS APM_URL APM_BEARER; do
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

DB="dokandar_catalog_${SUF}"
CODE_VERSION="$(cat "$HERE/../CODE_VERSION" 2>/dev/null | tr -d ' \n\r' || echo 04-catalog)"
OUT="$HERE/$TARGET"; umask 077
cat > "$OUT" <<EOF
# ============================================================================
#  env/${TARGET}  —  rendered by env/init-env.sh  from  env/components-creds.txt
#  REAL SECRETS · gitignored · never commit · re-run init-env.sh to re-render
#  legend —  get: copied from a components-creds.txt  "### NN_block"
#            gen: generated locally on every run (one-line command shown)
# ============================================================================

# -- Application / identity --------------------------------------------------
# get: static; APP_ENV from the .env.<env> target, TENANT=local(dev)/cloud(stage|prod)
# note: SERVICE_PORT/GRPC_PORT are the IN-CONTAINER bind ports; docker run
#       publishes host 10004->8080 (REST) and 20004->9090 (gRPC) onto them
APP_ENV=${SUF}
SERVICE_NAME=04-catalog
ENV_VERSION=v1.0.0
TENANT=${TENANT}
SERVICE_PORT=8080
GRPC_PORT=9090
GRPC_ENABLED=true
LOG_LEVEL=info

# -- PostgreSQL --------------------------------------------------------------
# get: components-creds.txt  ### 01_PostgreSQL  (host:port / user / password)
# note: POSTGRES_DB = dokandar_catalog_<env>; DbBootstrap + Spring JDBC read discrete POSTGRES_*
POSTGRES_HOST=${INFRA}
POSTGRES_PORT=${PG_PORT}
POSTGRES_USER=${PG_USER}
POSTGRES_PASSWORD=${PG_PASS}
POSTGRES_DB=${DB}

# -- Redis (DB 3: hot read cache; degradable — does NOT gate /ready) ---------
# get: components-creds.txt  ### 04_Redis  (password); host:port fixed to INFRA:6379
REDIS_HOST=${INFRA}
REDIS_PORT=6379
REDIS_PASSWORD=${RE_PASS}
REDIS_DB=3
REDIS_URL=redis://default:${RE_PASS}@${INFRA}:6379/3
CATALOG_CACHE_TTL_SECONDS=300
STOCK_CACHE_TTL_SECONDS=30

# -- Kafka (emit-only via outbox relay; acks=all) ----------------------------
# get: components-creds.txt  ### 05_Kafka  (bootstrap);  topic names below are fixed
KAFKA_BOOTSTRAP=${KAFKA}
KAFKA_CONSUMER_GROUP=catalog
KAFKA_TOPIC_PRODUCT_CHANGED=dokandar.product.changed
KAFKA_TOPIC_CATEGORY_CHANGED=dokandar.category.changed
KAFKA_TOPIC_STOCK_LOW=dokandar.stock.low

# -- Log sinks: MongoDB + Elasticsearch log sink: APM-stack ES (:9200) -------
# get: components-creds.txt  ### 02_MongoDB  (endpoint) + ### 07_Elastic_APM  (elasticsearch :9200 line + elastic-pass)
# note: NOT block 03 (:9201) — that ES is the search/review business store
MONGO_LOG_URI=${MO_URI}
MONGO_LOG_DB=mongo_db_dokandar_application_logs
ELASTIC_SEARCH_URL=${ES_URL}
ELASTIC_SEARCH_USERNAME=${ES_USER}
ELASTIC_SEARCH_PASSWORD=${ES_PASS}

# -- Elastic APM (traces) ----------------------------------------------------
# get: components-creds.txt  ### 07_Elastic_APM  (apm-ingest :8200 + apm-token)
# note: app /health probes APM_SERVER_URL; the -javaagent reads the ELASTIC_APM_* set (SERVICE_VERSION from CODE_VERSION — arch §16-e)
APM_SERVER_URL=${APM_URL}
APM_SECRET_TOKEN=${APM_BEARER}
APM_SERVICE_NAME=04-catalog
ELASTIC_APM_SERVER_URL=${APM_URL}
ELASTIC_APM_SECRET_TOKEN=${APM_BEARER}
ELASTIC_APM_SERVICE_NAME=04-catalog
ELASTIC_APM_SERVICE_VERSION=${CODE_VERSION}
ELASTIC_APM_ENVIRONMENT=${SUF}
# only 5xx server faults belong in APM Errors; the handled 4xx classes below are expected
# client outcomes (auth/validation/not-found/method) — tell the -javaagent to skip them.
ELASTIC_APM_IGNORE_EXCEPTIONS=com.dokandar.catalog.api.ApiException,com.dokandar.catalog.auth.JwtAuth\$UnauthorizedException,org.springframework.web.servlet.NoHandlerFoundException,org.springframework.web.servlet.resource.NoResourceFoundException,org.springframework.web.HttpRequestMethodNotSupportedException,org.springframework.http.converter.HttpMessageNotReadableException

# -- JWT verify-only (auth's PUBLIC key) + east-west token -------------------
# get: components-creds.txt  ### Auth_Identity  (auth_service_public_key / internal_service_token) — verify-only, no private key minted here
JWT_PUBLIC_KEY_B64=${JWT_PUB}
JWT_ISSUER=dokandar-auth
INTERNAL_SERVICE_TOKEN=${INT_TOK}

# -- Media gRPC client (12-media @ ext gRPC 20012) ---------------------------
# get: PEER_HOST (docker-bridge default, overridable) + the fleet-constant ext port
MEDIA_GRPC_ADDR=${PEER_HOST}:20012
EOF
chmod 600 "$OUT"
echo "✓ wrote $OUT"
echo "  SERVICE_NAME=04-catalog  POSTGRES_DB=$DB  INFRA=$INFRA  REST=8080 gRPC=9090 (host 10004/20004)  redis-db=3"
echo "  ES log sink=$ES_URL   APM=$APM_URL   Kafka=$KAFKA"
echo "  JWT public key + INTERNAL_SERVICE_TOKEN: verify-only (no private key)"
