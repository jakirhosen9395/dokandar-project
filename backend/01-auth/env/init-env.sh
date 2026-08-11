#!/usr/bin/env bash
# env/init-env.sh — render env/.env.<env> from env/components-creds.txt
#
# env/components-creds.txt holds the infra credentials paste in the `### NN_Service` format
# (PostgreSQL / MongoDB / Elasticsearch / Redis / Kafka / RabbitMQ / Elastic-APM
# / RustFS). This script parses it, generates a fresh RS256 JWT keypair + a
# 64-hex INTERNAL_SERVICE_TOKEN (auth is the sole holder of the private key),
# and writes env/.env.<env> (chmod 600, gitignored).
#
# Usage:   ./env/init-env.sh            # -> env/.env.dev
#          ./env/init-env.sh .env.dev   # -> env/.env.dev
#          ./env/init-env.sh .env.prod  # -> env/.env.prod
#          CREDS_FILE=/path/to/components-creds.txt ./env/init-env.sh .env.dev
#
# Required tooling: bash, awk, openssl, base64.
set -euo pipefail

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

# ---- PostgreSQL (block 01) — INFRA host is derived from here -----------------
PG_HP=$(gv 01_PostgreSQL host:port);  PG_USER=$(gv 01_PostgreSQL user);  PG_PASS=$(gv 01_PostgreSQL password)
INFRA=$(host_of "$PG_HP");            PG_PORT=$(port_of "$PG_HP")

# ---- MongoDB (block 02) — log sink ------------------------------------------
MO_HP=$(gv 02_MongoDB host:port);     MO_USER=$(gv 02_MongoDB user);    MO_PASS=$(gv 02_MongoDB password)
MO_URI=$(gv 02_MongoDB endpoint);     MO_PORT=$(port_of "$MO_HP")

# ---- Elasticsearch: block 03 (:9201) is the SEARCH/REVIEW business ES and is
#      NOT used by 01-auth — the log-sink ES is the APM-stack ES (block 07, :9200),
#      derived in the Elastic-APM section below. ----

# ---- Redis (block 04) -------------------------------------------------------
RE_HP=$(gv 04_Redis host:port);       RE_PASS=$(gv 04_Redis password);   RE_PORT=$(port_of "$RE_HP")
RE_URL=$(gv 04_Redis endpoint)

# ---- Kafka (block 05) -------------------------------------------------------
KAFKA=$(gv 05_Kafka bootstrap)

# ---- RabbitMQ (block 06) ----------------------------------------------------
RMQ_URL=$(gv 06_RabbitMQ amqp-url);   RMQ_USER=$(gv 06_RabbitMQ user);   RMQ_PASS=$(gv 06_RabbitMQ password)
RMQ_HP=$(gv 06_RabbitMQ host:port);   RMQ_PORT=$(port_of "$RMQ_HP")

# ---- Elastic-APM (block 07) — APM ingest/bearer + the APM-stack Elasticsearch -
# 01-auth uses the APM stack for ALL observability: traces via the APM ingest
# (:8200) and application-log shipping into the APM-stack ES (:9200 — the block-07
# `elasticsearch` line + `elastic-pass`). Block 03 (:9201) is NOT read here.
APM_URL=$(gv 07_Elastic_APM apm-ingest);  APM_BEARER=$(gv 07_Elastic_APM apm-token)
ES_RAW=$(gv 07_Elastic_APM elasticsearch)            # http://elastic:<pass>@<host>:9200
ES_PASS=$(gv 07_Elastic_APM elastic-pass)
ES_HP="${ES_RAW##*@}"                                # <host>:9200
_es_user_tmp="${ES_RAW#*://}"; ES_USER="${_es_user_tmp%%:*}"   # elastic
ES_URL="http://${ES_HP}"

# ---- RustFS (block 10, :9002) — KYC document storage (S3 API) ----------------
S3_EP=$(gv 10_RustFS s3-endpoint);    S3_KEY=$(gv 10_RustFS access-key);  S3_SEC=$(gv 10_RustFS secret-key)

# ---- sanity -----------------------------------------------------------------
miss=""
for v in PG_HP PG_USER PG_PASS INFRA PG_PORT MO_URI MO_PORT ES_URL ES_USER ES_PASS RE_URL RE_PORT KAFKA RMQ_URL RMQ_PORT APM_URL APM_BEARER S3_EP; do
  eval "x=\${$v:-}"; [ -n "$x" ] || miss="$miss $v"
done
[ -z "$miss" ] || { echo "ERROR: could not parse from components-creds.txt:$miss" >&2; echo "  check the '### NN_Service' headers / field names match env/components-creds.example.txt" >&2; exit 3; }

# ---- JWT keypair + east-west token (auth holds the private key) --------------
PRIV="$(openssl genrsa 2048 2>/dev/null)"
PUB="$(printf '%s' "$PRIV" | openssl rsa -pubout 2>/dev/null)"
JWT_PRIV_B64="$(printf '%s' "$PRIV" | base64 -w0)"
JWT_PUB_B64="$(printf '%s' "$PUB"  | base64 -w0)"
INTERNAL_TOKEN="$(openssl rand -hex 32)"

# Guarantee EVERY run emits fresh, NON-EMPTY secrets. openssl draws from the OS CSPRNG,
# so the RS256 keypair + token are cryptographically unique on each run; this aborts if
# any came out empty (e.g. openssl missing) rather than writing blank secrets.
for kv in JWT_PRIV_B64 JWT_PUB_B64 INTERNAL_TOKEN; do
  eval "kx=\${$kv:-}"; [ -n "$kx" ] || { echo "ERROR: $kv is empty — openssl key generation failed (is openssl installed?)" >&2; exit 4; }
done

DB="dokandar_auth_${SUF}"
OUT="$HERE/$TARGET"
umask 077
cat > "$OUT" <<EOF
# ============================================================================
#  env/${TARGET}  —  rendered by env/init-env.sh  from  env/components-creds.txt
#  REAL SECRETS · gitignored · never commit · re-run init-env.sh to rotate the keypair
#  legend —  get: copied from a components-creds.txt  "### NN_block"
#            gen: generated locally on every run (one-line command shown)
# ============================================================================

# -- Application / identity --------------------------------------------------
# get: static; APP_ENV from the .env.<env> target, TENANT=local(dev)/cloud(stage|prod)
APP_ENV=${SUF}
SERVICE_NAME=01-auth
ENV_VERSION=v1.0.0
TENANT=${TENANT}
SERVICE_PORT=8000
GRPC_PORT=8001
GRPC_ENABLED=true
LOG_LEVEL=info

# -- PostgreSQL --------------------------------------------------------------
# 01_PostgreSQL  (host:port / user / password)
# note: POSTGRES_DB = dokandar_auth_<env>; the *_DSN are built from the block + DB name
POSTGRES_HOST=${INFRA}
POSTGRES_PORT=${PG_PORT}
POSTGRES_USER=${PG_USER}
POSTGRES_PASSWORD=${PG_PASS}
POSTGRES_DB=${DB}
POSTGRES_DSN=postgresql+asyncpg://${PG_USER}:${PG_PASS}@${INFRA}:${PG_PORT}/${DB}
POSTGRES_ADMIN_DSN=postgresql+asyncpg://${PG_USER}:${PG_PASS}@${INFRA}:${PG_PORT}/postgres

# -- Redis -------------------------------------------------------------------
# 04_Redis  (host:port / password / endpoint)
REDIS_HOST=${INFRA}
REDIS_PORT=${RE_PORT}
REDIS_PASSWORD=${RE_PASS}
REDIS_URL=${RE_URL}

# -- Kafka -------------------------------------------------------------------
# 05_Kafka  (bootstrap);  topic names below are fixed
KAFKA_SERVERS=${KAFKA}
KAFKA_BOOTSTRAP=${KAFKA}
KAFKA_TOPIC_USER=dokandar.user.created
KAFKA_TOPIC_USER_UPDATED=dokandar.user.updated
KAFKA_TOPIC_KYC_SUBMITTED=dokandar.kyc.submitted
KAFKA_TOPIC_KYC_APPROVED=dokandar.kyc.approved
KAFKA_TOPIC_KYC_REJECTED=dokandar.kyc.rejected

# -- RabbitMQ ----------------------------------------------------------------
# 06_RabbitMQ  (amqp-url / host:port / user / password)
RABBITMQ_HOST=${INFRA}
RABBITMQ_PORT=${RMQ_PORT}
RABBITMQ_USERNAME=${RMQ_USER}
RABBITMQ_PASSWORD=${RMQ_PASS}
RABBITMQ_URL=${RMQ_URL}
RABBITMQ_OTP_QUEUE=notifications.otp.send

# -- MongoDB (structured-log forensic sink, collection = 01-auth) ------------
# 02_MongoDB  (endpoint / host:port / user / password)
MONGO_HOST=${INFRA}
MONGO_PORT=${MO_PORT}
MONGO_USERNAME=${MO_USER}
MONGO_PASSWORD=${MO_PASS}
MONGO_DATABASE=mongo_db_dokandar_application_logs
MONGO_AUTH_SOURCE=admin
MONGO_LOG_URI=${MO_URI}
MONGO_LOG_DB=mongo_db_dokandar_application_logs

# -- Elasticsearch log sink: APM-stack ES (:9200) ----------------------------
# 07_Elastic_APM  (elasticsearch :9200 line + elastic-pass)
# note: NOT block 03 (:9201) — that ES is the search/review business store
ELASTIC_SEARCH_URL=${ES_URL}
ELASTIC_SEARCH_USERNAME=${ES_USER}
ELASTIC_SEARCH_PASSWORD=${ES_PASS}

# -- Elastic APM (traces) ----------------------------------------------------
# 07_Elastic_APM  (apm-ingest :8200 + apm-token)
APM_SERVER_URL=${APM_URL}
APM_SECRET_TOKEN=${APM_BEARER}
APM_SERVICE_NAME=01-auth
ELASTIC_APM_SERVICE_NAME=01-auth
ELASTIC_APM_SERVICE_VERSION=01-auth

# -- Object storage (RustFS, S3 API) — KYC documents -------------------------
# 10_RustFS  (s3-endpoint / access-key / secret-key)
S3_ENDPOINT=${S3_EP}
S3_ACCESS_KEY=${S3_KEY}
S3_SECRET_KEY=${S3_SEC}
S3_BUCKET=dokandar-kyc-${SUF}
S3_REGION=us-east-1
S3_FORCE_PATH_STYLE=true

# -- JWT / east-west auth: GENERATED fresh every run (auth is the SOLE key holder) --
# gen: private  ->  openssl genrsa 2048 | base64 -w0
# gen: public   ->  openssl rsa -in <private.pem> -pubout | base64 -w0   (derived from the private)
# gen: token    ->  openssl rand -hex 32
JWT_PRIVATE_KEY_B64=${JWT_PRIV_B64}
JWT_PUBLIC_KEY_B64=${JWT_PUB_B64}
INTERNAL_SERVICE_TOKEN=${INTERNAL_TOKEN}
JWT_ISSUER=dokandar-auth
JWT_ACCESS_TTL_SECONDS=900
JWT_REFRESH_TTL_SECONDS=2592000

# -- OTP (dev: code returned in the verify response; no SMS provider wired) ---
# get: static dev defaults
OTP_ENABLED=true
OTP_TTL_SECONDS=300
OTP_MAX_ATTEMPTS=5
OTP_RATE_PER_HOUR=5

# -- Default admin seed ------------------------------------------------------
# get: static; login is phone-OTP, so the password field below is unused by the app
DEFAULT_ADMIN_PHONE=01700000000
DEFAULT_ADMIN_NAME=Platform Admin
DEFAULT_ADMIN_Password=Admin123
EOF
chmod 600 "$OUT"

echo "✓ wrote $OUT"
echo "  SERVICE_NAME=01-auth  POSTGRES_DB=$DB  INFRA_HOST=$INFRA"
echo "  ES log sink=$ES_URL   APM=$APM_URL   Kafka=$KAFKA"
echo "  JWT RS256 keypair + INTERNAL_SERVICE_TOKEN generated fresh (rotate by re-running)."
