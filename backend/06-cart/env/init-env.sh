#!/usr/bin/env bash
# env/init-env.sh — render env/.env.<env> for 06-cart from env/components-creds.txt.
#
# 06-cart (Node 24 / NestJS 11) is a quote builder + cart store and is VERIFY-ONLY:
#   * MongoDB (carts/wishlists embedded docs) — the business store, GATED on /ready
#   * Redis DB 5 (guest carts + Redlock + idempotency cache) — GATED on /ready
#   * Kafka: consume-only (product.changed, order.placed) — manual commit
#   * NO Postgres in the business path, NO outbox, NO gRPC server
#   * Application LOG SINK: the APM-stack Elasticsearch (block 07, :9200 — the
#     `elasticsearch` line + `elastic-pass`). Block 03 (:9201) is NOT read.
#   * RS256 verify-only: it reads auth's PUBLIC key + the shared
#     INTERNAL_SERVICE_TOKEN from the `### Auth_Identity` block of
#     components-creds.txt (it NEVER generates a keypair). If that block is still
#     a placeholder, it falls back to $AUTH_PUBLIC_KEY_B64 / $AUTH_INTERNAL_TOKEN
#     or $AUTH_ENV_FILE (auth's rendered .env.dev).
#
# Reads infra blocks: 02_MongoDB, 04_Redis, 05_Kafka, 07_Elastic_APM.
#
# Usage:  ./env/init-env.sh                                    # → env/.env.dev
#         AUTH_PUBLIC_KEY_B64=… AUTH_INTERNAL_TOKEN=… ./env/init-env.sh .env.dev
#         AUTH_ENV_FILE=/path/to/auth/.env.dev ./env/init-env.sh .env.dev
set -euo pipefail
# bash 5.2 patsub_replacement expands `&` in ${var//pat/$repl} to the matched
# pattern — would corrupt any secret containing `&`. Disable defensively.
shopt -u patsub_replacement 2>/dev/null || true

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-.env.dev}"; TARGET="${TARGET##*/}"
case "$TARGET" in .env.*) ;; *) echo "ERROR: target must be .env.<env>" >&2; exit 2;; esac
SUF="${TARGET#.env.}"
[ "$SUF" = "dev" ] && TENANT="local" || TENANT="cloud"

ENVTXT="${CREDS_FILE:-}"
if [ -z "$ENVTXT" ]; then
  for f in "$HERE/components-creds.txt"; do
    [ -f "$f" ] && { ENVTXT="$f"; break; }
  done
fi
[ -n "$ENVTXT" ] && [ -f "$ENVTXT" ] || {
  echo "ERROR: no creds file found. Paste the infra creds (### NN_Service format) into" >&2
  echo "       env/components-creds.txt first (see env/components-creds.example.txt)." >&2
  exit 2
}

gv() {
  awk -v hdr="$1" -v key="$2" '
    $0 ~ "^###[[:space:]]+"hdr"([[:space:]]|$)" { on=1; next }
    on && /^###/ { exit }
    on && $1==key { print $2; exit }
  ' "$ENVTXT"
}
port_of(){ printf '%s' "${1##*:}"; }
host_of(){ printf '%s' "${1%:*}"; }

echo "→ parsing $ENVTXT" >&2

# Mongo — the business cart store
MO_URI=$(gv 02_MongoDB endpoint)
MO_HP=$(gv 02_MongoDB host:port)
INFRA=$(host_of "$MO_HP")

# Redis — DB 5 + sliding TTL
RD_HP=$(gv 04_Redis host:port); RD_USER=$(gv 04_Redis user); RD_PASS=$(gv 04_Redis password)
RD_HOST=$(host_of "$RD_HP"); RD_PORT=$(port_of "$RD_HP")

# Kafka
KAFKA=$(gv 05_Kafka bootstrap)

# ---- Elastic-APM (block 07) — APM ingest/bearer + the APM-stack Elasticsearch -
# 06-cart ships its application logs into the APM-stack ES (:9200 — the block-07
# `elasticsearch` line + `elastic-pass`); traces go to the APM ingest (:8200).
# Block 03 (:9201) is the search/review business ES and is NOT read here.
APM_URL=$(gv 07_Elastic_APM apm-ingest); APM_BEARER=$(gv 07_Elastic_APM apm-token)
ES_RAW=$(gv 07_Elastic_APM elasticsearch)            # http://elastic:<pass>@<host>:9200
ES_PASS=$(gv 07_Elastic_APM elastic-pass)
ES_HP="${ES_RAW##*@}"                                # <host>:9200
_es_user_tmp="${ES_RAW#*://}"; ES_USER="${_es_user_tmp%%:*}"   # elastic
ES_URL="http://${ES_HP}"

for v in MO_URI INFRA RD_HOST RD_PORT RD_PASS KAFKA APM_URL APM_BEARER ES_URL ES_USER ES_PASS; do
  eval "x=\${$v:-}"
  [ -n "$x" ] || { echo "ERROR: could not parse $v from $ENVTXT" >&2; exit 3; }
done

# ── auth's PUBLIC key + shared INTERNAL_SERVICE_TOKEN (verify-only) ──────────
# Primary source: the `### Auth_Identity` block in components-creds.txt. If still
# a placeholder, fall back to env vars or auth's rendered .env.dev. NEVER a
# private key — 06-cart only verifies JWTs, it never mints them.
JWT_PUB="${AUTH_PUBLIC_KEY_B64:-}"
INT_TOK="${AUTH_INTERNAL_TOKEN:-}"
[ -n "$JWT_PUB" ] || JWT_PUB=$(gv Auth_Identity auth_service_public_key)
[ -n "$INT_TOK" ] || INT_TOK=$(gv Auth_Identity internal_service_token)
case "$JWT_PUB" in ""|"<"*|*"_public_key>"*|"<paste"*) JWT_PUB="";; esac
case "$INT_TOK" in ""|"<"*|*"_token>"*|"<paste"*) INT_TOK="";; esac

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
[ -n "$JWT_PUB" ] || echo "WARN: no JWT public key. Authed routes will 503. Paste auth's JWT_PUBLIC_KEY_B64 into the ### Auth_Identity block, or set AUTH_PUBLIC_KEY_B64=… / AUTH_ENV_FILE=…" >&2
[ -n "$INT_TOK" ] || echo "WARN: no INTERNAL_SERVICE_TOKEN. Paste auth's INTERNAL_SERVICE_TOKEN into the ### Auth_Identity block, or set AUTH_INTERNAL_TOKEN=… / AUTH_ENV_FILE=…" >&2

# Downstream peer URLs for the checkout-quote fan-out (catalog REST 10004 · coupon REST
# 10007 · risk REST 10018). PEER_HOST = the docker-bridge gateway (overridable PEER_HOST/
# APP_HOST for split-host/mesh). NOT hardcoded in app — the app reads these env vars.
PEER_HOST="${PEER_HOST:-${APP_HOST:-172.17.0.1}}"
CATALOG_URL="${CATALOG_HTTP_URL:-http://${PEER_HOST}:10004}"
COUPON_URL="${COUPON_HTTP_URL:-http://${PEER_HOST}:10007}"
RISK_URL="${RISK_HTTP_URL:-http://${PEER_HOST}:10018}"

DB="dokandar_cart_${SUF}"
OUT="$HERE/$TARGET"
umask 077

cat > "$OUT" <<EOF
# ============================================================================
#  env/${TARGET}  —  rendered by env/init-env.sh  from  env/components-creds.txt
#  REAL SECRETS · gitignored · never commit · re-run init-env.sh to refresh
#  legend —  get: copied from a components-creds.txt  "### NN_block"
#            gen: generated locally on every run (one-line command shown)
# ============================================================================

# -- Application / identity --------------------------------------------------
# get: static; APP_ENV from the .env.<env> target, TENANT=local(dev)/cloud(stage|prod)
APP_ENV=${SUF}
SERVICE_NAME=06-cart
ENV_VERSION=v1.0.0
TENANT=${TENANT}
# internal container bind port — docker run publishes host 10006 → 3000
SERVICE_PORT=3000
LOG_LEVEL=info

# -- MongoDB (the cart store — gated on /ready) ------------------------------
# get: components-creds.txt  ### 02_MongoDB  (endpoint / host:port)
MONGO_URL=${MO_URI}
MONGO_DB=${DB}

# -- Redis DB 5 (gated on /ready — guest carts + Redlock + idempotency) ------
# get: components-creds.txt  ### 04_Redis  (host:port / user / password)
REDIS_HOST=${RD_HOST}
REDIS_PORT=${RD_PORT}
REDIS_PASSWORD=${RD_PASS}
REDIS_DB=5
GUEST_CART_TTL_DAYS=7
IDEMPOTENCY_TTL_HOURS=24
CHECKOUT_LOCK_TTL_SECONDS=5

# -- Kafka (consume-only) ----------------------------------------------------
# get: components-creds.txt  ### 05_Kafka  (bootstrap);  topic names below are fixed
KAFKA_BOOTSTRAP=${KAFKA}
KAFKA_GROUP_PREFIX=cart
KAFKA_TOPIC_PRODUCT_CHANGED=dokandar.product.changed
KAFKA_TOPIC_ORDER_PLACED=dokandar.order.placed

# -- MongoDB (structured-log forensic sink) ----------------------------------
# get: components-creds.txt  ### 02_MongoDB  (endpoint)
MONGO_LOG_URI=${MO_URI}
MONGO_LOG_DB=mongo_db_dokandar_application_logs

# -- Elasticsearch log sink: APM-stack ES (:9200) ----------------------------
# get: components-creds.txt  ### 07_Elastic_APM  (elasticsearch :9200 line + elastic-pass)
# note: NOT block 03 (:9201) — that ES is the search/review business store
ELASTIC_SEARCH_URL=${ES_URL}
ELASTIC_SEARCH_USERNAME=${ES_USER}
ELASTIC_SEARCH_PASSWORD=${ES_PASS}

# -- Elastic APM (traces) ----------------------------------------------------
# get: components-creds.txt  ### 07_Elastic_APM  (apm-ingest :8200 + apm-token)
APM_SERVER_URL=${APM_URL}
APM_SECRET_TOKEN=${APM_BEARER}
APM_SERVICE_NAME=06-cart

# -- JWT verify-only (auth's PUBLIC key) + east-west token -------------------
# get: components-creds.txt  ### Auth_Identity  (auth_service_public_key / internal_service_token)
# note: verify-only — 06-cart NEVER mints JWTs, so nothing is generated here
JWT_PUBLIC_KEY_B64=${JWT_PUB}
JWT_ISSUER=dokandar-auth
INTERNAL_SERVICE_TOKEN=${INT_TOK}

# -- Downstream peers (REST shim for the gRPC clients) -----------------------
# get: static; peer URLs autodetected from INFRA (caller can override)
CATALOG_HTTP_URL=${CATALOG_URL}
COUPON_HTTP_URL=${COUPON_URL}
RISK_HTTP_URL=${RISK_URL}
GRPC_DEADLINE_MS_CATALOG=2000
GRPC_DEADLINE_MS_COUPON=1000
GRPC_DEADLINE_MS_RISK=1000
DEFAULT_TAX_PERCENT=0
EOF
chmod 600 "$OUT"

echo "✓ wrote $OUT"
echo "  SERVICE_NAME=06-cart  MONGO_DB=$DB  INFRA=$INFRA  REDIS_DB=5  REST=3000 in-container (host 10006)  no gRPC server  no Postgres"
echo "  ES log sink=$ES_URL (APM-stack :9200)   APM=$APM_URL   Kafka=$KAFKA"
echo "  JWT public key + INTERNAL_SERVICE_TOKEN: verify-only (no private key)"
echo "  Catalog URL: $CATALOG_URL  Coupon URL: ${COUPON_URL:-<empty — fail-open>}  Risk URL: ${RISK_URL:-<empty — COD-hold>}"
