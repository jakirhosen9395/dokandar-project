#!/usr/bin/env bash
# env/init-env.sh — render env/.env.<env> for 09-payment from env/components-creds.txt
#
# env/components-creds.txt holds the infra credentials paste in the `### NN_Service`
# format. 09-payment reads: 01_PostgreSQL, 02_MongoDB (log sink), 04_Redis (DB 8),
# 05_Kafka, 06_RabbitMQ (payout.execute), 07_Elastic_APM (APM :8200 + the APM-stack
# Elasticsearch :9200 log sink), and the ### Auth_Identity block (auth's PUBLIC key +
# the shared INTERNAL_SERVICE_TOKEN — this is a VERIFY-ONLY service, it never mints).
#
# Usage:   ./env/init-env.sh            # -> env/.env.dev
#          ./env/init-env.sh .env.dev   # -> env/.env.dev
#          ./env/init-env.sh .env.prod  # -> env/.env.prod
#          CREDS_FILE=/path/to/components-creds.txt ./env/init-env.sh .env.dev
#
# Required tooling: bash, awk.
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
  on && $1==key { print $2; exit }' "$ENVTXT"; }
port_of(){ printf '%s' "${1##*:}"; }
host_of(){ printf '%s' "${1%:*}"; }

echo "→ parsing $ENVTXT" >&2

# ---- PostgreSQL (block 01) — INFRA host is derived from here -----------------
PG_HP=$(gv 01_PostgreSQL host:port); PG_USER=$(gv 01_PostgreSQL user); PG_PASS=$(gv 01_PostgreSQL password)
INFRA=$(host_of "$PG_HP"); PG_PORT=$(port_of "$PG_HP")

# ---- MongoDB (block 02) — structured-log forensic sink ----------------------
MO_URI=$(gv 02_MongoDB endpoint)

# ---- Redis (block 04) — DB 8 (degradable) -----------------------------------
RD_HP=$(gv 04_Redis host:port); RD_PASS=$(gv 04_Redis password)
RD_HOST=$(host_of "$RD_HP"); RD_PORT=$(port_of "$RD_HP")

# ---- Kafka (block 05) -------------------------------------------------------
KAFKA=$(gv 05_Kafka bootstrap)

# ---- RabbitMQ (block 06) — payout.execute -----------------------------------
RMQ=$(gv 06_RabbitMQ amqp-url)

# ---- Elastic-APM (block 07) — APM ingest/bearer + the APM-stack Elasticsearch -
# ALL observability is on the APM stack: traces via the APM ingest (:8200) and the
# application-log sink into the APM-stack ES (:9200 — the block-07 `elasticsearch`
# line + `elastic-pass`). Block 03 (:9201) is NOT read (that ES is search/review only).
APM_URL=$(gv 07_Elastic_APM apm-ingest); APM_BEARER=$(gv 07_Elastic_APM apm-token)
ES_RAW=$(gv 07_Elastic_APM elasticsearch)            # http://elastic:<pass>@<host>:9200
ES_PASS=$(gv 07_Elastic_APM elastic-pass)
ES_HP="${ES_RAW##*@}"                                # <host>:9200
_es_user_tmp="${ES_RAW#*://}"; ES_USER="${_es_user_tmp%%:*}"   # elastic
ES_URL="http://${ES_HP}"

# ---- Auth identity (VERIFY-ONLY) — auth's PUBLIC key + shared east-west token -
# Primary source: the ### Auth_Identity block of components-creds.txt (paste from
# 01-auth's rendered .env.dev). If still a placeholder, fall back to auto-discovering
# 01-auth's rendered .env.dev. This service NEVER generates a keypair.
JWT_PUB=$(gv Auth_Identity auth_service_public_key)
INT_TOK=$(gv Auth_Identity internal_service_token)
case "$JWT_PUB" in ""|"<paste"*|"<"*) JWT_PUB="";; esac
case "$INT_TOK" in ""|"<paste"*|"<"*) INT_TOK="";; esac
if [ -z "$JWT_PUB" ] || [ -z "$INT_TOK" ]; then
  AUTH_ENV_FILE="${AUTH_ENV_FILE:-}"
  [ -z "$AUTH_ENV_FILE" ] && for f in /opt/dokandar/01-auth/env/.env.dev /opt/01-auth/env/.env.dev; do [ -f "$f" ] && AUTH_ENV_FILE="$f" && break; done
  [ -n "$AUTH_ENV_FILE" ] && [ -f "$AUTH_ENV_FILE" ] && {
    [ -z "$JWT_PUB" ] && JWT_PUB=$(grep -E '^JWT_PUBLIC_KEY_B64=' "$AUTH_ENV_FILE" | head -1 | cut -d= -f2-)
    [ -z "$INT_TOK" ] && INT_TOK=$(grep -E '^INTERNAL_SERVICE_TOKEN=' "$AUTH_ENV_FILE" | head -1 | cut -d= -f2-)
  }
fi

# ---- sanity -----------------------------------------------------------------
miss=""
for v in PG_HP PG_USER PG_PASS INFRA PG_PORT MO_URI RD_HOST RD_PORT KAFKA RMQ ES_URL ES_USER ES_PASS APM_URL APM_BEARER; do
  eval "x=\${$v:-}"; [ -n "$x" ] || miss="$miss $v"
done
[ -z "$miss" ] || { echo "ERROR: could not parse from components-creds.txt:$miss" >&2; echo "  check the '### NN_Service' headers / field names match env/components-creds.example.txt" >&2; exit 3; }

DB="dokandar_payment_${SUF}"; OUT="$HERE/$TARGET"; umask 077
cat > "$OUT" <<EOF
# ============================================================================
#  env/${TARGET}  —  rendered by env/init-env.sh  from  env/components-creds.txt
#  REAL SECRETS · gitignored · never commit · re-run init-env.sh to rotate
#  legend —  get: copied from a components-creds.txt  "### NN_block"
#            gen: generated locally on every run (one-line command shown)
# ============================================================================

# -- Application / identity --------------------------------------------------
# get: static; APP_ENV from the .env.<env> target, TENANT=local(dev)/cloud(stage|prod)
APP_ENV=${SUF}
SERVICE_NAME=09-payment
ENV_VERSION=v1.0.0
TENANT=${TENANT}
SERVICE_PORT=4000
LOG_LEVEL=info

# -- PostgreSQL --------------------------------------------------------------
# get: components-creds.txt  ### 01_PostgreSQL  (host:port / user / password)
# note: POSTGRES_DB = dokandar_payment_<env>
POSTGRES_HOST=${INFRA}
POSTGRES_PORT=${PG_PORT}
POSTGRES_USER=${PG_USER}
POSTGRES_PASSWORD=${PG_PASS}
POSTGRES_DB=${DB}

# -- Redis (DB 8) ------------------------------------------------------------
# get: components-creds.txt  ### 04_Redis  (host:port / password)
REDIS_HOST=${RD_HOST}
REDIS_PORT=${RD_PORT}
REDIS_PASSWORD=${RD_PASS}
REDIS_DB=8

# -- Kafka -------------------------------------------------------------------
# get: components-creds.txt  ### 05_Kafka  (bootstrap)
KAFKA_BOOTSTRAP=${KAFKA}

# -- RabbitMQ ----------------------------------------------------------------
# get: components-creds.txt  ### 06_RabbitMQ  (amqp-url)
RABBITMQ_URL=${RMQ}
RABBITMQ_PAYOUT_QUEUE=payout.execute

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
APM_SERVICE_NAME=09-payment

# -- JWT / east-west auth: VERIFY-ONLY (auth's PUBLIC key + shared token) -----
# get: components-creds.txt  ### Auth_Identity  (auth_service_public_key / internal_service_token)
JWT_PUBLIC_KEY_B64=${JWT_PUB}
JWT_ISSUER=dokandar-auth
INTERNAL_SERVICE_TOKEN=${INT_TOK}

# -- Payment provider --------------------------------------------------------
# get: static dev defaults. The stub webhook secret MUST match 00-support's
# committed default so its HMAC-signed provider-callback simulations verify here.
PAYMENT_PROVIDER_MODE=stub
PAYMENT_STUB_WEBHOOK_SECRET=dokandar_payment_stub_secret_dev
PAYMENT_COMMISSION_DEFAULT_BPS=250
EOF
chmod 600 "$OUT"
echo "✓ $OUT (SERVICE_NAME=09-payment, DB=$DB, REDIS_DB=8, REST=4000 internal / 10009 host)"
echo "  ES log sink=$ES_URL   APM=$APM_URL   Kafka=$KAFKA"
