#!/usr/bin/env bash
# env/init-env.sh — render env/.env.<env> for 08-review from env/components-creds.txt.
#
# env/components-creds.txt holds the infra credentials paste in the `### NN_Service`
# format. 08-review reads only:
#   01_PostgreSQL · 02_MongoDB (forensic log sink) · 03_Elasticsearch (:9201 review
#   SEARCH store) · 05_Kafka · 07_Elastic_APM (:8200 traces + :9200 ES log sink).
#
# 08-review is a search/review service, so it wires BOTH Elasticsearch instances:
#   - block 07_Elastic_APM `elasticsearch` (:9200) = application LOG SINK (logs-app-08-review-*)
#   - block 03_Elasticsearch (:9201)              = business review-SEARCH store (dokandar-reviews)
# NO Redis.
#
# 08-review is VERIFY-ONLY: it reads 01-auth's PUBLIC key + the shared
# INTERNAL_SERVICE_TOKEN from the `### Auth_Identity` block (it NEVER mints a keypair).
#
# Usage:   ./env/init-env.sh            # -> env/.env.dev
#          ./env/init-env.sh .env.dev   # -> env/.env.dev
#          ./env/init-env.sh .env.prod  # -> env/.env.prod
#          CREDS_FILE=/path/to/components-creds.txt ./env/init-env.sh .env.dev
#
# Required tooling: bash, awk, grep.
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
  for f in "$HERE/components-creds.txt"; do
    [ -f "$f" ] && { ENVTXT="$f"; break; }
  done
fi
[ -n "$ENVTXT" ] && [ -f "$ENVTXT" ] || {
  echo "ERROR: no creds file found. Paste the infra creds (### NN_Service format) into" >&2
  echo "       env/components-creds.txt first (see env/components-creds.example.txt)." >&2
  exit 2
}

# gv <block-header-suffix> <field-key>  -> the field's first value token.
gv() { awk -v hdr="$1" -v key="$2" '
  $0 ~ "^###[[:space:]]+"hdr"([[:space:]]|$)" { on=1; next }
  on && /^###/ { exit }
  on && $1==key { print $2; exit }
' "$ENVTXT"; }
port_of(){ printf '%s' "${1##*:}"; }
host_of(){ printf '%s' "${1%:*}"; }

echo "→ parsing $ENVTXT" >&2

# ---- PostgreSQL (block 01) — INFRA host is derived from here -----------------
PG_HP=$(gv 01_PostgreSQL host:port); PG_USER=$(gv 01_PostgreSQL user); PG_PASS=$(gv 01_PostgreSQL password)
INFRA=$(host_of "$PG_HP"); PG_PORT=$(port_of "$PG_HP")

# ---- MongoDB (block 02) — forensic log sink ---------------------------------
MO_URI=$(gv 02_MongoDB endpoint)

# ---- Elasticsearch business SEARCH store: block 03 (:9201) -------------------
# This is the review-search index (dokandar-reviews), SEPARATE from the log-sink ES.
SE_HP=$(gv 03_Elasticsearch host:port); SE_USER=$(gv 03_Elasticsearch user); SE_PASS=$(gv 03_Elasticsearch password)
SE_URL=""; [ -n "$SE_HP" ] && SE_URL="http://${SE_HP}"

# ---- Kafka (block 05) -------------------------------------------------------
KAFKA=$(gv 05_Kafka bootstrap)

# ---- Elastic-APM (block 07) — APM ingest/bearer + the APM-stack Elasticsearch -
# The application LOG SINK ES is the APM-stack ES (:9200 — the block-07
# `elasticsearch` line + `elastic-pass`). Block 03 (:9201) above is the search store.
APM_URL=$(gv 07_Elastic_APM apm-ingest); APM_BEARER=$(gv 07_Elastic_APM apm-token)
ES_RAW=$(gv 07_Elastic_APM elasticsearch)            # http://elastic:<pass>@<host>:9200
ES_PASS=$(gv 07_Elastic_APM elastic-pass)
ES_HP="${ES_RAW##*@}"                                # <host>:9200
_es_user_tmp="${ES_RAW#*://}"; ES_USER="${_es_user_tmp%%:*}"   # elastic
ES_URL=""; [ -n "$ES_HP" ] && ES_URL="http://${ES_HP}"

# ---- sanity -----------------------------------------------------------------
miss=""
for v in PG_HP PG_USER PG_PASS INFRA PG_PORT MO_URI SE_URL KAFKA ES_URL ES_USER ES_PASS APM_URL APM_BEARER; do
  eval "x=\${$v:-}"; [ -n "$x" ] || miss="$miss $v"
done
[ -z "$miss" ] || { echo "ERROR: could not parse from components-creds.txt:$miss" >&2; echo "  check the '### NN_Service' headers / field names match env/components-creds.example.txt" >&2; exit 3; }

# ---- Identity (verify-only): JWT public key + east-west token ----------------
# 08-review reads 01-auth's PUBLIC key + shared token from the `### Auth_Identity`
# block; it NEVER generates a keypair. If the block is still a placeholder, fall back
# to AUTH_ENV_FILE auto-discovery from 01-auth's rendered .env.dev.
JWT_PUB=$(gv Auth_Identity auth_service_public_key)
INT_TOK=$(gv Auth_Identity internal_service_token)
case "$JWT_PUB" in '<paste'*|'<'*) JWT_PUB="";; esac
case "$INT_TOK" in '<paste'*|'<'*) INT_TOK="";; esac
if [ -z "$JWT_PUB" ] || [ -z "$INT_TOK" ]; then
  AUTH_ENV_FILE="${AUTH_ENV_FILE:-}"
  if [ -z "$AUTH_ENV_FILE" ]; then
    for f in /opt/dokandar/01-auth/env/.env.dev /opt/01-auth/env/.env.dev; do
      [ -f "$f" ] && { AUTH_ENV_FILE="$f"; break; }
    done
  fi
  if [ -n "$AUTH_ENV_FILE" ] && [ -f "$AUTH_ENV_FILE" ]; then
    [ -n "$JWT_PUB" ] || JWT_PUB=$(grep -E '^JWT_PUBLIC_KEY_B64=' "$AUTH_ENV_FILE" | head -1 | cut -d= -f2-)
    [ -n "$INT_TOK" ] || INT_TOK=$(grep -E '^INTERNAL_SERVICE_TOKEN=' "$AUTH_ENV_FILE" | head -1 | cut -d= -f2-)
  fi
fi

DB="dokandar_review_${SUF}"
OUT="$HERE/$TARGET"
umask 077
cat > "$OUT" <<EOF
# ============================================================================
#  env/${TARGET}  —  rendered by env/init-env.sh  from  env/components-creds.txt
#  REAL SECRETS · gitignored · never commit
#  legend —  get: copied from a components-creds.txt  "### NN_block"
# ============================================================================

# -- Application / identity --------------------------------------------------
# get: static; APP_ENV from the .env.<env> target, TENANT=local(dev)/cloud(stage|prod)
# SERVICE_PORT/GRPC_PORT are the INTERNAL container bind ports (docker run maps
# host 10008->8080 and 20008->50051).
APP_ENV=${SUF}
SERVICE_NAME=08-review
ENV_VERSION=v1.0.0
TENANT=${TENANT}
SERVICE_PORT=8080
GRPC_PORT=50051
LOG_LEVEL=info

# -- PostgreSQL --------------------------------------------------------------
# get: components-creds.txt  ### 01_PostgreSQL  (host:port / user / password);  POSTGRES_DB = dokandar_review_<env>
POSTGRES_HOST=${INFRA}
POSTGRES_PORT=${PG_PORT}
POSTGRES_USER=${PG_USER}
POSTGRES_PASSWORD=${PG_PASS}
POSTGRES_DB=${DB}

# -- Kafka -------------------------------------------------------------------
# get: components-creds.txt  ### 05_Kafka  (bootstrap)
KAFKA_BOOTSTRAP=${KAFKA}
KAFKA_GROUP_PREFIX=review

# -- Elasticsearch business SEARCH store: block 03 (:9201) -------------------
# get: components-creds.txt  ### 03_Elasticsearch  (host:port / user / password) — the review-search index.
# SEPARATE from the log-sink ES below (which is the APM-stack ES :9200).
SEARCH_ES_URL=${SE_URL}
SEARCH_ES_USERNAME=${SE_USER}
SEARCH_ES_PASSWORD=${SE_PASS}
ES_INDEX_REVIEWS=dokandar-reviews

# -- Elasticsearch log sink: APM-stack ES (:9200) ----------------------------
# get: components-creds.txt  ### 07_Elastic_APM  (elasticsearch :9200 line + elastic-pass)
# note: NOT block 03 (:9201) — that ES is the review-search store above
ELASTIC_SEARCH_URL=${ES_URL}
ELASTIC_SEARCH_USERNAME=${ES_USER}
ELASTIC_SEARCH_PASSWORD=${ES_PASS}

# -- MongoDB (structured-log forensic sink, collection = 08-review) ----------
# get: components-creds.txt  ### 02_MongoDB  (endpoint)
MONGO_LOG_URI=${MO_URI}
MONGO_LOG_DB=mongo_db_dokandar_application_logs

# -- Elastic APM (traces) ----------------------------------------------------
# get: components-creds.txt  ### 07_Elastic_APM  (apm-ingest :8200 + apm-token)
APM_SERVER_URL=${APM_URL}
APM_SECRET_TOKEN=${APM_BEARER}
APM_SERVICE_NAME=08-review

# -- JWT / east-west auth: VERIFY-ONLY (read from ### Auth_Identity) ----------
# get: Auth_Identity  (auth_service_public_key -> JWT_PUBLIC_KEY_B64,
#                      internal_service_token  -> INTERNAL_SERVICE_TOKEN)
# 08-review NEVER mints keys; fallback = AUTH_ENV_FILE auto-discovery.
JWT_PUBLIC_KEY_B64=${JWT_PUB}
JWT_ISSUER=dokandar-auth
INTERNAL_SERVICE_TOKEN=${INT_TOK}

# -- Review business rules ---------------------------------------------------
# get: static defaults
REVIEW_EDIT_WINDOW_DAYS=7
REVIEW_REPORT_THRESHOLD=5
REVIEW_ENFORCE_VERIFIED_PURCHASE=false
EOF
chmod 600 "$OUT"

echo "✓ wrote $OUT"
echo "  SERVICE_NAME=08-review  POSTGRES_DB=$DB  INFRA_HOST=$INFRA  REST=8080 (host 10008)  gRPC=50051 (host 20008)"
echo "  ES log sink=$ES_URL (:9200, block 07)   search ES=$SE_URL (:9201, block 03)"
echo "  APM=$APM_URL   Kafka=$KAFKA"
if [ -z "$JWT_PUB" ] || [ -z "$INT_TOK" ]; then
  echo "  WARN: JWT_PUBLIC_KEY_B64 / INTERNAL_SERVICE_TOKEN empty — paste them into the" >&2
  echo "        ### Auth_Identity block of components-creds.txt (from 01-auth's .env.dev)." >&2
fi
