#!/usr/bin/env bash
# env/init-env.sh — render env/.env.<env> from env/components-creds.txt
#
# env/components-creds.txt holds the infra credentials paste in the `### NN_Service`
# format (PostgreSQL / MongoDB / Kafka / Elastic-APM / Qdrant / ScyllaDB) plus the
# `### Auth_Identity` block (auth's PUBLIC key + the shared INTERNAL_SERVICE_TOKEN).
# This is a VERIFY-ONLY service: it never generates a keypair — only 01-auth does.
#
# Usage:   ./env/init-env.sh            # -> env/.env.dev
#          ./env/init-env.sh .env.dev   # -> env/.env.dev
#          ./env/init-env.sh .env.prod  # -> env/.env.prod
#          CREDS_FILE=/path/to/components-creds.txt ./env/init-env.sh .env.dev
set -euo pipefail
shopt -u patsub_replacement 2>/dev/null || true
HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-.env.dev}"; TARGET="${TARGET##*/}"
case "$TARGET" in .env.*) ;; *) echo "ERROR: target must be .env.<env>" >&2; exit 2;; esac
SUF="${TARGET#.env.}"
[ "$SUF" = "dev" ] && TENANT="local" || TENANT="cloud"
# creds source: $CREDS_FILE override, else env/components-creds.txt
ENVTXT="${CREDS_FILE:-}"
if [ -z "$ENVTXT" ]; then
  for f in "$HERE/components-creds.txt"; do [ -f "$f" ] && { ENVTXT="$f"; break; }; done
fi
[ -n "$ENVTXT" ] && [ -f "$ENVTXT" ] || {
  echo "ERROR: no creds file found. Paste the infra creds (### NN_Service format) into" >&2
  echo "       env/components-creds.txt first (see env/components-creds.example.txt)." >&2
  exit 2
}

# gv <block-header-suffix> <field-key> -> the field's first value token.
gv() { awk -v hdr="$1" -v key="$2" '
  $0 ~ "^###[[:space:]]+"hdr"([[:space:]]|$)" { on=1; next }
  on && /^###/ { exit }
  on && $1==key { print $2; exit }' "$ENVTXT"; }
port_of(){ printf '%s' "${1##*:}"; }; host_of(){ printf '%s' "${1%:*}"; }

echo "→ parsing $ENVTXT" >&2

# ---- PostgreSQL (block 01) — INFRA host is derived from here -----------------
PG_HP=$(gv 01_PostgreSQL host:port); PG_USER=$(gv 01_PostgreSQL user); PG_PASS=$(gv 01_PostgreSQL password)
INFRA=$(host_of "$PG_HP"); PG_PORT=$(port_of "$PG_HP")

# ---- MongoDB (block 02) — forensic log sink ---------------------------------
MO_URI=$(gv 02_MongoDB endpoint)

# ---- Kafka (block 05) -------------------------------------------------------
KAFKA=$(gv 05_Kafka bootstrap)

# ---- Elastic-APM (block 07) — APM ingest (:8200) + the APM-stack ES (:9200) --
# The application log-sink ES is the APM-stack ES (block 07 `elasticsearch` line
# + `elastic-pass`, :9200). Block 03 (:9201) is the search/review business ES and
# is NOT read by this service.
APM_URL=$(gv 07_Elastic_APM apm-ingest); APM_BEARER=$(gv 07_Elastic_APM apm-token)
ES_RAW=$(gv 07_Elastic_APM elasticsearch)            # http://elastic:<pass>@<host>:9200
ES_PASS=$(gv 07_Elastic_APM elastic-pass)
ES_HP="${ES_RAW##*@}"                                # <host>:9200
_es_user_tmp="${ES_RAW#*://}"; ES_USER="${_es_user_tmp%%:*}"   # elastic
ES_URL="http://${ES_HP}"

# ---- Qdrant (block 12) ------------------------------------------------------
QDRANT=$(gv 12_Qdrant rest); QDRANT_KEY=$(gv 12_Qdrant api-key)

# ---- ScyllaDB (block 14) ----------------------------------------------------
SCYLLA=$(gv 14_ScyllaDB cql)

# ---- sanity -----------------------------------------------------------------
miss=""
for v in PG_HP PG_USER PG_PASS INFRA PG_PORT MO_URI KAFKA ES_URL ES_USER ES_PASS APM_URL APM_BEARER QDRANT SCYLLA; do
  eval "x=\${$v:-}"; [ -n "$x" ] || miss="$miss $v"
done
[ -z "$miss" ] || { echo "ERROR: could not parse from components-creds.txt:$miss" >&2; echo "  check the '### NN_Service' headers / field names match env/components-creds.example.txt" >&2; exit 3; }

# ---- Identity (VERIFY-ONLY): read auth's PUBLIC key + shared token from the
#      `### Auth_Identity` block; fall back to AUTH_ENV_FILE auto-discovery. ----
JWT_PUB=$(gv Auth_Identity auth_service_public_key)
INT_TOK=$(gv Auth_Identity internal_service_token)
AUTH_ENV_FILE="${AUTH_ENV_FILE:-/opt/01-auth/env/.env.dev}"
if [ -f "$AUTH_ENV_FILE" ]; then
  [ -z "$JWT_PUB" ] && JWT_PUB=$(grep -E '^JWT_PUBLIC_KEY_B64=' "$AUTH_ENV_FILE" | head -1 | cut -d= -f2-)
  [ -z "$INT_TOK" ] && INT_TOK=$(grep -E '^INTERNAL_SERVICE_TOKEN=' "$AUTH_ENV_FILE" | head -1 | cut -d= -f2-)
fi

DB="dokandar_risk_${SUF}"; OUT="$HERE/$TARGET"; umask 077
cat > "$OUT" <<EOF
# ============================================================================
#  env/${TARGET}  —  rendered by env/init-env.sh  from  env/components-creds.txt
#  REAL SECRETS · gitignored · never commit · re-run init-env.sh to rotate
#  legend —  get: copied from a components-creds.txt  "### NN_block"
#            gen: generated locally on every run (one-line command shown)
# ============================================================================

# -- Application / identity --------------------------------------------------
# get: static; APP_ENV from the .env.<env> target, TENANT=local(dev)/cloud(stage|prod)
# SERVICE_PORT is the IN-CONTAINER bind port (docker maps host 10018 -> 8000)
APP_ENV=${SUF}
SERVICE_NAME=18-risk-trust
ENV_VERSION=v1.0.0
TENANT=${TENANT}
SERVICE_PORT=8000
LOG_LEVEL=info

# -- PostgreSQL --------------------------------------------------------------
# get: components-creds.txt  ### 01_PostgreSQL  (host:port / user / password)
POSTGRES_HOST=${INFRA}
POSTGRES_PORT=${PG_PORT}
POSTGRES_USER=${PG_USER}
POSTGRES_PASSWORD=${PG_PASS}
POSTGRES_DB=${DB}

# -- ScyllaDB ----------------------------------------------------------------
# get: components-creds.txt  ### 14_ScyllaDB  (cql)
SCYLLA_HOSTS=${SCYLLA}

# -- Qdrant ------------------------------------------------------------------
# get: components-creds.txt  ### 12_Qdrant  (rest / api-key)
QDRANT_URL=${QDRANT}
QDRANT_API_KEY=${QDRANT_KEY}

# -- Kafka -------------------------------------------------------------------
# get: components-creds.txt  ### 05_Kafka  (bootstrap);  group prefix is fixed
KAFKA_BOOTSTRAP=${KAFKA}
KAFKA_GROUP_PREFIX=risk

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
APM_SERVICE_NAME=18-risk-trust

# -- JWT / east-west auth: VERIFY-ONLY (auth mints; this service only verifies) --
# get: components-creds.txt  ### Auth_Identity  (auth_service_public_key / internal_service_token)
JWT_PUBLIC_KEY_B64=${JWT_PUB}
JWT_ISSUER=dokandar-auth
INTERNAL_SERVICE_TOKEN=${INT_TOK}
EOF
chmod 600 "$OUT"
echo "✓ $OUT (SERVICE_NAME=18-risk-trust, DB=$DB, REST bind=8000, host=10018)"
echo "  ES log sink=$ES_URL  APM=$APM_URL  Kafka=$KAFKA"
