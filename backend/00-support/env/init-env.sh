#!/usr/bin/env bash
# env/init-env.sh — render env/.env.<env> for 00-support from env/components-creds.txt
#
# 00-support is a DEV/STAGE OTP-readback hub + payment-webhook simulator (verify-only:
# it does NOT mint JWTs). env/components-creds.txt holds the infra credentials paste in
# the `### NN_Service` format. 00-support reads only:
#   01_PostgreSQL  → DATABASE_URL pointed at dokandar_auth_<env> (email→phone search)
#   02_MongoDB     → application-log forensic sink (block 02)
#   04_Redis       → cache/coordination
#   06_RabbitMQ    → RABBITMQ_URL (the OTP queue auth publishes to)
#   07_Elastic_APM → APM traces (:8200) + the application log-sink ES (:9200)
#   Auth_Identity  → auth's PUBLIC key + shared INTERNAL_SERVICE_TOKEN (verify-only)
# Block 03_Elasticsearch (:9201) is NOT read — that is the search/review business ES.
#
# Usage:  ./env/init-env.sh            # -> env/.env.dev
#         ./env/init-env.sh .env.stage # -> env/.env.stage
#         CREDS_FILE=/path/to/components-creds.txt ./env/init-env.sh .env.dev
#
# Required tooling: bash, awk.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-.env.dev}"; TARGET="${TARGET##*/}"
case "$TARGET" in .env.*) ;; *) echo "ERROR: target must be .env.<env>" >&2; exit 2;; esac
SUF="${TARGET#.env.}"
# 00-support refuses to start outside dev/stage; render only those.
case "$SUF" in dev|stage) ;; *) echo "ERROR: 00-support is DEV/STAGE only (got .env.$SUF)" >&2; exit 2;; esac
[ "$SUF" = "dev" ] && TENANT="local" || TENANT="cloud"

# creds source: $CREDS_FILE override, else env/components-creds.txt
ENVTXT="${CREDS_FILE:-}"
if [ -z "$ENVTXT" ]; then
  for f in "$HERE/components-creds.txt"; do [ -f "$f" ] && { ENVTXT="$f"; break; }; done
fi
[ -n "$ENVTXT" ] && [ -f "$ENVTXT" ] || {
  echo "ERROR: no creds file found. Paste the infra creds (### NN_Service format) into" >&2
  echo "       env/components-creds.txt first (see env/components-creds.example.txt)." >&2
  exit 2; }

# gv <block-header-suffix> <field-key>  -> the field's first value token.
# Matches '### NN_Service' headers and 'key  value' rows; value = 2nd column,
# so trailing '(comment)' notes after a URL are ignored.
gv(){ awk -v hdr="$1" -v key="$2" '
  $0 ~ "^###[[:space:]]+"hdr"([[:space:]]|$)" { on=1; next }
  on && /^###/ { exit }
  on && $1==key { print $2; exit }
' "$ENVTXT"; }
port_of(){ printf '%s' "${1##*:}"; }
host_of(){ printf '%s' "${1%:*}"; }

echo "→ parsing $ENVTXT" >&2

# ---- PostgreSQL (block 01) — auth's PG; DATABASE_URL points at dokandar_auth_<env> --
PG_HP=$(gv 01_PostgreSQL host:port);  PG_USER=$(gv 01_PostgreSQL user);  PG_PASS=$(gv 01_PostgreSQL password)
INFRA=$(host_of "$PG_HP");            PG_PORT=$(port_of "$PG_HP")

# ---- MongoDB (block 02) — application-log forensic sink -----------------------
MO_HP=$(gv 02_MongoDB host:port);     MO_USER=$(gv 02_MongoDB user);    MO_PASS=$(gv 02_MongoDB password)
MO_URI=$(gv 02_MongoDB endpoint);     MO_PORT=$(port_of "$MO_HP")

# ---- Redis (block 04) -------------------------------------------------------
RE_HP=$(gv 04_Redis host:port);       RE_PASS=$(gv 04_Redis password);   RE_PORT=$(port_of "$RE_HP")
RE_URL=$(gv 04_Redis endpoint)

# ---- RabbitMQ (block 06) — the queue auth publishes OTPs to ------------------
RMQ_URL=$(gv 06_RabbitMQ amqp-url);   RMQ_USER=$(gv 06_RabbitMQ user);   RMQ_PASS=$(gv 06_RabbitMQ password)
RMQ_HP=$(gv 06_RabbitMQ host:port);   RMQ_PORT=$(port_of "$RMQ_HP")

# ---- Elastic-APM (block 07) — APM ingest/bearer + the APM-stack Elasticsearch -
# Application log shipping goes into the APM-stack ES (:9200 — the block-07
# `elasticsearch` line + `elastic-pass`). Block 03 (:9201) is NOT read here.
APM_URL=$(gv 07_Elastic_APM apm-ingest);  APM_BEARER=$(gv 07_Elastic_APM apm-token)
ES_RAW=$(gv 07_Elastic_APM elasticsearch)            # http://elastic:<pass>@<host>:9200
ES_PASS=$(gv 07_Elastic_APM elastic-pass)
ES_HP="${ES_RAW##*@}"                                # <host>:9200
_es_user_tmp="${ES_RAW#*://}"; ES_USER="${_es_user_tmp%%:*}"   # elastic
ES_URL="http://${ES_HP}"

# ---- Auth identity (verify-only: read auth's PUBLIC key + shared token) -------
# 00-support never mints JWTs. Read the public key + INTERNAL_SERVICE_TOKEN from the
# ### Auth_Identity block; if that block is still a placeholder, fall back to
# auto-discovery from a rendered 01-auth env file (AUTH_ENV_FILE).
JWT_PUB_B64=$(gv Auth_Identity auth_service_public_key)
INTERNAL_TOKEN=$(gv Auth_Identity internal_service_token)
case "$JWT_PUB_B64" in "<paste"*|"") JWT_PUB_B64="";; esac
case "$INTERNAL_TOKEN" in "<paste"*|"") INTERNAL_TOKEN="";; esac
AUTH_ENV_FILE="${AUTH_ENV_FILE:-/opt/01-auth/env/.env.dev}"
if { [ -z "$JWT_PUB_B64" ] || [ -z "$INTERNAL_TOKEN" ]; } && [ -f "$AUTH_ENV_FILE" ]; then
  [ -n "$JWT_PUB_B64" ]   || JWT_PUB_B64=$(awk '/^JWT_PUBLIC_KEY_B64=/{sub(/^JWT_PUBLIC_KEY_B64=/,""); print; exit}' "$AUTH_ENV_FILE")
  [ -n "$INTERNAL_TOKEN" ] || INTERNAL_TOKEN=$(awk '/^INTERNAL_SERVICE_TOKEN=/{sub(/^INTERNAL_SERVICE_TOKEN=/,""); print; exit}' "$AUTH_ENV_FILE")
fi

# ---- sanity -----------------------------------------------------------------
miss=""
for v in PG_HP PG_USER PG_PASS INFRA PG_PORT MO_URI MO_PORT ES_URL ES_USER ES_PASS RE_URL RE_PORT RMQ_URL RMQ_PORT APM_URL APM_BEARER; do
  eval "x=\${$v:-}"; [ -n "$x" ] || miss="$miss $v"
done
[ -z "$miss" ] || { echo "ERROR: could not parse from components-creds.txt:$miss" >&2; echo "  check the '### NN_Service' headers / field names match env/components-creds.example.txt" >&2; exit 3; }

AUTH_DB="dokandar_auth_${SUF}"
DB_URL="postgresql://${PG_USER}:${PG_PASS}@${INFRA}:${PG_PORT}/${AUTH_DB}"

OUT="$HERE/$TARGET"
umask 077
cat > "$OUT" <<EOF
# ============================================================================
#  env/${TARGET}  —  rendered by env/init-env.sh  from  env/components-creds.txt
#  REAL SECRETS · gitignored · never commit · re-run init-env.sh to rotate
#  legend —  get: copied from a components-creds.txt  "### NN_block"
#            gen: generated locally on every run (one-line command shown)
# ============================================================================

# -- Application / identity --------------------------------------------------
# get: static; APP_ENV from the .env.<env> target, TENANT=local(dev)/cloud(stage)
# SERVICE_PORT is the INTERNAL container bind port (docker run maps host 10000 -> 8000)
APP_ENV=${SUF}
SERVICE_NAME=00-support
SERVICE_PORT=8000
TENANT=${TENANT}
LOG_LEVEL=info

# -- RabbitMQ — SAME value the auth service uses (consumes the OTP queue) -----
# get: components-creds.txt  ### 06_RabbitMQ  (amqp-url / host:port / user / password)
RABBITMQ_HOST=${INFRA}
RABBITMQ_PORT=${RMQ_PORT}
RABBITMQ_USERNAME=${RMQ_USER}
RABBITMQ_PASSWORD=${RMQ_PASS}
RABBITMQ_URL=${RMQ_URL}
OTP_QUEUE=notifications.otp.send

# -- auth Postgres — enables email→phone search (points at the auth DB) ------
# get: components-creds.txt  ### 01_PostgreSQL  (host:port / user / password); DATABASE_URL = dokandar_auth_<env>
POSTGRES_HOST=${INFRA}
POSTGRES_PORT=${PG_PORT}
POSTGRES_USER=${PG_USER}
POSTGRES_PASSWORD=${PG_PASS}
DATABASE_URL=${DB_URL}

# -- Redis -------------------------------------------------------------------
# get: components-creds.txt  ### 04_Redis  (host:port / password / endpoint)
REDIS_HOST=${INFRA}
REDIS_PORT=${RE_PORT}
REDIS_PASSWORD=${RE_PASS}
REDIS_URL=${RE_URL}

# -- MongoDB (structured-log forensic sink, collection = 00-support) ---------
# get: components-creds.txt  ### 02_MongoDB  (endpoint / host:port / user / password)
MONGO_HOST=${INFRA}
MONGO_PORT=${MO_PORT}
MONGO_USERNAME=${MO_USER}
MONGO_PASSWORD=${MO_PASS}
MONGO_DATABASE=mongo_db_dokandar_application_logs
MONGO_AUTH_SOURCE=admin
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
APM_SERVICE_NAME=00-support
ELASTIC_APM_SERVICE_NAME=00-support
ELASTIC_APM_SERVICE_VERSION=00-support

# -- JWT / east-west auth: VERIFY-ONLY (auth's PUBLIC key + shared token) -----
# get: components-creds.txt  ### Auth_Identity  (or AUTH_ENV_FILE fallback)
JWT_PUBLIC_KEY_B64=${JWT_PUB_B64}
INTERNAL_SERVICE_TOKEN=${INTERNAL_TOKEN}

# -- OTP capture buffer + payment webhook simulator --------------------------
# get: static dev defaults
BUFFER_SIZE=500
PAYMENT_BASE_URL=http://${INFRA}:10009
PAYMENT_STUB_WEBHOOK_SECRET=dokandar_payment_stub_secret_dev
EOF
chmod 600 "$OUT"

echo "✓ wrote $OUT"
echo "  SERVICE_NAME=00-support  RABBITMQ=amqp://…@${RMQ_URL##*@}  email-search-db=${AUTH_DB}"
echo "  ES log sink=$ES_URL   APM=$APM_URL"
echo "  JWT public key + INTERNAL_SERVICE_TOKEN: $([ -n "$JWT_PUB_B64" ] && [ -n "$INTERNAL_TOKEN" ] && echo 'set (verify-only)' || echo 'PLACEHOLDER — paste from 01-auth or set AUTH_ENV_FILE')"
