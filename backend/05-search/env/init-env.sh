#!/usr/bin/env bash
# env/init-env.sh — render env/.env.<env> for 05-search from the components dump.
#
# 05-search (Rust / Axum) is a CQRS read projection: consume-only (4 Kafka
# projectors), Postgres *_view store. It is VERIFY-ONLY for the admin reindex
# route (POST /api/v1/search/admin/reindex): it verifies JWTs with auth's PUBLIC
# key + the shared INTERNAL_SERVICE_TOKEN (### Auth_Identity block) and NEVER
# generates a keypair.
#
# ES-port rule (see overview/SERVICE_ENV_BUILD_STANDARD.md §2):
#   * application LOG SINK ES  → APM-stack ES, block 07 (:9200) — the block-07
#     `elasticsearch` line + `elastic-pass`. Drives ELASTIC_SEARCH_* (logs-app-*).
#   * business SEARCH ES       → standalone ES, block 03 (:9201). Separate
#     SEARCH_ES_* vars for the dokandar-products/-shops indices.
#
# Reads infra blocks: 01_PostgreSQL 02_MongoDB 03_Elasticsearch 05_Kafka
# 07_Elastic_APM  (+ the ### Auth_Identity block for verify-only JWT).
#
# Usage:  ./env/init-env.sh                            # → env/.env.dev
#         ./env/init-env.sh .env.prod                  # → env/.env.prod
#         CREDS_FILE=/path/to/components-creds.txt ./env/init-env.sh .env.dev
#         AUTH_ENV_FILE=/opt/01-auth/env/.env.dev ./env/init-env.sh .env.dev
set -euo pipefail
# bash 5.2 `patsub_replacement` expands `&` in ${var//pat/$repl} to the matched
# pattern, corrupting any secret containing `&`. Disable defensively.
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

# gv hdr key → first value in the `### hdr` section (block-scoped; same key in
# two blocks never collides).
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

# ---- PostgreSQL (block 01) — INFRA host derived here ------------------------
PG_HP=$(gv 01_PostgreSQL host:port); PG_USER=$(gv 01_PostgreSQL user); PG_PASS=$(gv 01_PostgreSQL password)
INFRA=$(host_of "$PG_HP"); PG_PORT=$(port_of "$PG_HP")

# ---- MongoDB (block 02) — forensic log sink ---------------------------------
MO_URI=$(gv 02_MongoDB endpoint)

# ---- Kafka (block 05) — consume-only ----------------------------------------
KAFKA=$(gv 05_Kafka bootstrap)

# ---- Elastic-APM (block 07) — APM ingest (:8200) + the APM-stack ES (:9200) --
# This APM-stack ES is the application LOG SINK for ALL services (logs-app-*).
APM_URL=$(gv 07_Elastic_APM apm-ingest);  APM_BEARER=$(gv 07_Elastic_APM apm-token)
ES_RAW=$(gv 07_Elastic_APM elasticsearch)            # http://elastic:<pass>@<host>:9200
ES_PASS=$(gv 07_Elastic_APM elastic-pass)
ES_HP="${ES_RAW##*@}"                                # <host>:9200
_es_user_tmp="${ES_RAW#*://}"; ES_USER="${_es_user_tmp%%:*}"   # elastic
ES_URL="http://${ES_HP}"

# ---- Elasticsearch (block 03, :9201) — SEPARATE business-search store --------
# dokandar-products / dokandar-shops indices (search/review only). NOT the log sink.
SES_HP=$(gv 03_Elasticsearch host:port); SES_USER=$(gv 03_Elasticsearch user); SES_PASS=$(gv 03_Elasticsearch password)
SES_URL="http://${SES_HP}"

# ---- sanity -----------------------------------------------------------------
miss=""
for v in PG_HP PG_USER PG_PASS INFRA PG_PORT MO_URI KAFKA APM_URL APM_BEARER ES_URL ES_USER ES_PASS SES_URL SES_USER SES_PASS; do
  eval "x=\${$v:-}"; [ -n "$x" ] || miss="$miss $v"
done
[ -z "$miss" ] || { echo "ERROR: could not parse from components-creds.txt:$miss" >&2; echo "  check the '### NN_Service' headers / field names match env/components-creds.example.txt" >&2; exit 3; }

# ---- Auth identity (VERIFY-ONLY) — auth's PUBLIC key + shared east-west token -
# Read block-scoped from the ### Auth_Identity block (paste from 01-auth's .env.dev).
# 05-search NEVER generates a keypair (only 01-auth mints these).
JWT_PUB=$(gv Auth_Identity auth_service_public_key)
INTERNAL_TOKEN=$(gv Auth_Identity internal_service_token)

# Optional fallback: auto-discover the deployed 01-auth env file and pull both.
AUTH_ENV_FILE="${AUTH_ENV_FILE:-}"
if [ -z "$AUTH_ENV_FILE" ]; then
  for f in /opt/dokandar/01-auth/env/.env.dev /opt/01-auth/env/.env.dev; do
    [ -f "$f" ] && { AUTH_ENV_FILE="$f"; break; }
  done
fi
if [ -n "$AUTH_ENV_FILE" ] && [ -f "$AUTH_ENV_FILE" ]; then
  [ -z "$JWT_PUB" ] && JWT_PUB=$(grep -E '^JWT_PUBLIC_KEY_B64=' "$AUTH_ENV_FILE" | head -1 | cut -d= -f2-)
  [ -z "$INTERNAL_TOKEN" ] && INTERNAL_TOKEN=$(grep -E '^INTERNAL_SERVICE_TOKEN=' "$AUTH_ENV_FILE" | head -1 | cut -d= -f2-)
fi
if [ -z "$JWT_PUB" ]; then
  echo "WARN: no JWT public key (### Auth_Identity auth_service_public_key empty and no AUTH_ENV_FILE)." >&2
  echo "      Admin reindex will return 503 until set. Stage/prod boot will fail-fast." >&2
fi
if [ -z "$INTERNAL_TOKEN" ]; then
  echo "WARN: INTERNAL_SERVICE_TOKEN empty (### Auth_Identity internal_service_token and no AUTH_ENV_FILE)." >&2
fi

DB="dokandar_search_${SUF}"
OUT="$HERE/$TARGET"
umask 077

cat > "$OUT" <<EOF
# ============================================================================
#  env/${TARGET}  —  rendered by env/init-env.sh  from  env/components-creds.txt
#  REAL SECRETS · gitignored · never commit · re-run to rotate
#  legend —  get: copied from a components-creds.txt  "### NN_block"
#            gen: generated locally on every run (one-line command shown)
# ============================================================================

# -- Application / identity --------------------------------------------------
# get: static; APP_ENV from the .env.<env> target, TENANT=local(dev)/cloud(stage|prod)
APP_ENV=${SUF}
SERVICE_NAME=05-search
ENV_VERSION=v1.0.0
TENANT=${TENANT}
SERVICE_PORT=8080
LOG_LEVEL=info

# -- PostgreSQL (the projection *_view store; sole writer = Kafka projectors) -
# get: components-creds.txt  ### 01_PostgreSQL  (host:port / user / password)
POSTGRES_HOST=${INFRA}
POSTGRES_PORT=${PG_PORT}
POSTGRES_USER=${PG_USER}
POSTGRES_PASSWORD=${PG_PASS}
POSTGRES_DB=${DB}
SEARCH_DEFAULT_PAGE_SIZE=20
SEARCH_MAX_PAGE_SIZE=100
SEARCH_GEO_DEFAULT_RADIUS_KM=5
SEARCH_GEO_MAX_RADIUS_KM=30

# -- Elasticsearch LOG SINK: APM-stack ES (:9200) ----------------------------
# get: components-creds.txt  ### 07_Elastic_APM  (elasticsearch :9200 line + elastic-pass)
# note: NOT block 03 (:9201) — this is the application log sink (logs-app-05-search-*)
ELASTIC_SEARCH_URL=${ES_URL}
ELASTIC_SEARCH_USERNAME=${ES_USER}
ELASTIC_SEARCH_PASSWORD=${ES_PASS}

# -- Elasticsearch business SEARCH store (:9201) — separate from the log sink -
# get: components-creds.txt  ### 03_Elasticsearch  (host:port / user / password)
# note: dokandar-products / dokandar-shops indices — search/review business store
SEARCH_ES_URL=${SES_URL}
SEARCH_ES_USERNAME=${SES_USER}
SEARCH_ES_PASSWORD=${SES_PASS}
ES_INDEX_PRODUCTS=dokandar-products
ES_INDEX_SHOPS=dokandar-shops

# -- Kafka (consume-only — 4 topics, one group each, read from earliest) -----
# get: components-creds.txt  ### 05_Kafka  (bootstrap)
KAFKA_BOOTSTRAP=${KAFKA}
KAFKA_GROUP_PREFIX=search
KAFKA_TOPIC_PRODUCT_CHANGED=dokandar.product.changed
KAFKA_TOPIC_SHOP_CHANGED=dokandar.shop.changed
KAFKA_TOPIC_CATEGORY_CHANGED=dokandar.category.changed
KAFKA_TOPIC_ORDER_PLACED=dokandar.order.placed

# -- MongoDB (structured-log forensic sink) ----------------------------------
# get: components-creds.txt  ### 02_MongoDB  (endpoint)
MONGO_LOG_URI=${MO_URI}
MONGO_LOG_DB=mongo_db_dokandar_application_logs

# -- Elastic APM (traces) ----------------------------------------------------
# get: components-creds.txt  ### 07_Elastic_APM  (apm-ingest :8200 + apm-token)
APM_SERVER_URL=${APM_URL}
APM_SECRET_TOKEN=${APM_BEARER}
APM_SERVICE_NAME=05-search
OTEL_EXPORTER_OTLP_ENDPOINT=${APM_URL}

# -- JWT / east-west auth: VERIFY-ONLY (auth's PUBLIC key + shared token) -----
# get: components-creds.txt  ### Auth_Identity  (auth_service_public_key / internal_service_token)
# note: NEVER generated here — only 01-auth mints these
JWT_PUBLIC_KEY_B64=${JWT_PUB}
INTERNAL_SERVICE_TOKEN=${INTERNAL_TOKEN}
JWT_ISSUER=dokandar-auth
EOF
chmod 600 "$OUT"

echo "✓ wrote $OUT"
echo "  SERVICE_NAME=05-search  POSTGRES_DB=$DB  INFRA=$INFRA  REST=8080 (host 10005)"
echo "  ES log sink(:9200)=$ES_URL   business search(:9201)=$SES_URL   Kafka=$KAFKA"
echo "  JWT verify-only: public key + INTERNAL_SERVICE_TOKEN from ### Auth_Identity (never generated)."
