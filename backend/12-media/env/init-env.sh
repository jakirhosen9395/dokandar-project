#!/usr/bin/env bash
# env/init-env.sh — render env/.env.<env> from env/components-creds.txt  (12-media)
#
# env/components-creds.txt holds the infra credentials paste in the `### NN_Service`
# format (PostgreSQL / MongoDB / Kafka / Elastic-APM / RustFS) plus the
# `### Auth_Identity` block. 12-media is VERIFY-ONLY: it does NOT mint JWT keys —
# it reads auth's PUBLIC key + the shared INTERNAL_SERVICE_TOKEN from the
# `### Auth_Identity` block (falling back to AUTH_ENV_FILE if still a placeholder).
#
# Usage:   ./env/init-env.sh            # -> env/.env.dev
#          ./env/init-env.sh .env.dev   # -> env/.env.dev
#          ./env/init-env.sh .env.prod  # -> env/.env.prod
#          CREDS_FILE=/path/to/components-creds.txt ./env/init-env.sh .env.dev
#
# Required tooling: bash, awk, base64.
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
#      NOT used by 12-media — the log-sink ES is the APM-stack ES (block 07, :9200),
#      derived in the Elastic-APM section below. ----

# ---- Kafka (block 05) -------------------------------------------------------
KAFKA=$(gv 05_Kafka bootstrap)

# ---- Elastic-APM (block 07) — APM ingest/bearer + the APM-stack Elasticsearch -
# 12-media ships application logs into the APM-stack ES (:9200 — the block-07
# `elasticsearch` line + `elastic-pass`) and traces via the APM ingest (:8200).
# Block 03 (:9201) is NOT read here.
APM_URL=$(gv 07_Elastic_APM apm-ingest);  APM_BEARER=$(gv 07_Elastic_APM apm-token)
ES_RAW=$(gv 07_Elastic_APM elasticsearch)            # http://elastic:<pass>@<host>:9200
ES_PASS=$(gv 07_Elastic_APM elastic-pass)
ES_HP="${ES_RAW##*@}"                                # <host>:9200
_es_user_tmp="${ES_RAW#*://}"; ES_USER="${_es_user_tmp%%:*}"   # elastic
ES_URL="http://${ES_HP}"

# ---- RustFS (block 10, :9002) — media object storage (S3 API) ----------------
S3_EP=$(gv 10_RustFS s3-endpoint);    S3_KEY=$(gv 10_RustFS access-key);  S3_SEC=$(gv 10_RustFS secret-key)

# ---- Auth identity (verify-only) — public key + east-west token --------------
# 12-media NEVER mints JWT keys; it reads auth's PUBLIC key + the shared
# INTERNAL_SERVICE_TOKEN from the ### Auth_Identity block of components-creds.txt.
JWT_PUB_B64=$(gv Auth_Identity auth_service_public_key)
INTERNAL_TOKEN=$(gv Auth_Identity internal_service_token)

# Optional fallback: auto-discover 01-auth's rendered .env.dev if the Auth_Identity
# block is still a placeholder (e.g. value starts with '<' or is empty).
AUTH_ENV_FILE="${AUTH_ENV_FILE:-/opt/01-auth/env/.env.dev}"
case "${JWT_PUB_B64:-}" in ""|"<"*) JWT_PUB_B64=""; esac
case "${INTERNAL_TOKEN:-}" in ""|"<"*) INTERNAL_TOKEN=""; esac
if { [ -z "$JWT_PUB_B64" ] || [ -z "$INTERNAL_TOKEN" ]; } && [ -f "$AUTH_ENV_FILE" ]; then
  echo "→ Auth_Identity placeholder; reading $AUTH_ENV_FILE" >&2
  [ -n "$JWT_PUB_B64" ]   || JWT_PUB_B64="$(awk -F= '$1=="JWT_PUBLIC_KEY_B64"{print $2; exit}' "$AUTH_ENV_FILE")"
  [ -n "$INTERNAL_TOKEN" ] || INTERNAL_TOKEN="$(awk -F= '$1=="INTERNAL_SERVICE_TOKEN"{print $2; exit}' "$AUTH_ENV_FILE")"
fi

# ---- sanity -----------------------------------------------------------------
miss=""
for v in PG_HP PG_USER PG_PASS INFRA PG_PORT MO_URI MO_PORT ES_URL ES_USER ES_PASS KAFKA APM_URL APM_BEARER S3_EP JWT_PUB_B64 INTERNAL_TOKEN; do
  eval "x=\${$v:-}"; [ -n "$x" ] || miss="$miss $v"
done
[ -z "$miss" ] || {
  echo "ERROR: could not parse from components-creds.txt:$miss" >&2
  echo "  check the '### NN_Service' headers / field names match env/components-creds.example.txt" >&2
  echo "  (for JWT_PUB_B64 / INTERNAL_TOKEN: paste 01-auth's values into the ### Auth_Identity block" >&2
  echo "   or set AUTH_ENV_FILE to 01-auth's rendered .env.dev)" >&2
  exit 3
}

DB="dokandar_media_${SUF}"
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
APP_ENV=${SUF}
SERVICE_NAME=12-media
ENV_VERSION=v1.0.0
TENANT=${TENANT}
SERVICE_PORT=8080
GRPC_PORT=50051
LOG_LEVEL=info

# -- PostgreSQL --------------------------------------------------------------
# get: components-creds.txt  ### 01_PostgreSQL  (host:port / user / password)
# note: POSTGRES_DB = dokandar_media_<env>; the *_DSN are built from the block + DB name
POSTGRES_HOST=${INFRA}
POSTGRES_PORT=${PG_PORT}
POSTGRES_USER=${PG_USER}
POSTGRES_PASSWORD=${PG_PASS}
POSTGRES_DB=${DB}
POSTGRES_DSN=postgresql://${PG_USER}:${PG_PASS}@${INFRA}:${PG_PORT}/${DB}
POSTGRES_ADMIN_DSN=postgresql://${PG_USER}:${PG_PASS}@${INFRA}:${PG_PORT}/postgres

# -- Kafka -------------------------------------------------------------------
# get: components-creds.txt  ### 05_Kafka  (bootstrap);  topic names below are fixed
KAFKA_BOOTSTRAP=${KAFKA}
KAFKA_TOPIC_MEDIA_UPLOADED=dokandar.media.uploaded
KAFKA_TOPIC_MEDIA_DELETED=dokandar.media.deleted

# -- MongoDB (structured-log forensic sink, collection = 12-media) -----------
# get: components-creds.txt  ### 02_MongoDB  (endpoint / host:port / user / password)
MONGO_HOST=${INFRA}
MONGO_PORT=${MO_PORT}
MONGO_USERNAME=${MO_USER}
MONGO_PASSWORD=${MO_PASS}
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
APM_SERVICE_NAME=12-media
ELASTIC_APM_SERVICE_NAME=12-media
ELASTIC_APM_SERVICE_VERSION=12-media

# -- Object storage (RustFS, S3 API) — media objects -------------------------
# get: components-creds.txt  ### 10_RustFS  (s3-endpoint / access-key / secret-key)
S3_ENDPOINT=${S3_EP}
S3_ACCESS_KEY=${S3_KEY}
S3_SECRET_KEY=${S3_SEC}
S3_BUCKET=dokandar-media-${SUF}
S3_REGION=us-east-1
S3_FORCE_PATH_STYLE=true
PRESIGN_UPLOAD_TTL_SECONDS=900
PRESIGN_DOWNLOAD_TTL_SECONDS=300

# -- JWT (verify-only) + east-west auth: from ### Auth_Identity --------------
# get: components-creds.txt  ### Auth_Identity  (auth_service_public_key / internal_service_token)
# note: 12-media VERIFIES JWTs with auth's PUBLIC key — it never holds the private key
JWT_PUBLIC_KEY_B64=${JWT_PUB_B64}
INTERNAL_SERVICE_TOKEN=${INTERNAL_TOKEN}
JWT_ISSUER=dokandar-auth
EOF
chmod 600 "$OUT"

echo "✓ wrote $OUT"
echo "  SERVICE_NAME=12-media  POSTGRES_DB=$DB  INFRA_HOST=$INFRA"
echo "  ES log sink=$ES_URL   APM=$APM_URL   Kafka=$KAFKA"
echo "  JWT public key + INTERNAL_SERVICE_TOKEN read from ### Auth_Identity (verify-only)."
