#!/usr/bin/env bash
# env/init-env.sh — render env/.env.<env> for 07-coupon from the components dump.
#
# 07-coupon (C#/.NET 10 / ASP.NET Core + EF Core 10) — discount engine:
#   * PostgreSQL (sole writer) — GATES /ready
#   * Redis DB 6 — DEGRADABLE (does NOT gate /ready)
#   * Kafka producer-only via the transactional outbox
#   * RS256 verify-only JWT + constant-time INTERNAL_SERVICE_TOKEN
#
# Reads: 01_PostgreSQL, 02_MongoDB (log sink), 04_Redis, 05_Kafka,
# 07_Elastic_APM (APM traces :8200 + the :9200 log-sink Elasticsearch), and the
# ### Auth_Identity block (verify-only JWT public key + INTERNAL_SERVICE_TOKEN).
# (Block 03 :9201 is the search/review business ES — NOT read here.)
# JWT_PUBLIC_KEY_B64 + INTERNAL_SERVICE_TOKEN come from the ### Auth_Identity block
# of components-creds.txt, falling back to AUTH_ENV_FILE auto-discovery of 01-auth's env.
#
# Usage:  ./env/init-env.sh                              # → env/.env.dev
#         AUTH_ENV_FILE=/opt/01-auth/env/.env.dev ./env/init-env.sh .env.dev
set -euo pipefail
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
  echo "ERROR: no creds file (env/components-creds.txt)." >&2
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

PG_HP=$(gv 01_PostgreSQL host:port); PG_USER=$(gv 01_PostgreSQL user); PG_PASS=$(gv 01_PostgreSQL password)
INFRA=$(host_of "$PG_HP"); PG_PORT=$(port_of "$PG_HP")
MO_URI=$(gv 02_MongoDB endpoint)
RD_HP=$(gv 04_Redis host:port); RD_PASS=$(gv 04_Redis password)
RD_HOST=$(host_of "$RD_HP"); RD_PORT=$(port_of "$RD_HP")
KAFKA=$(gv 05_Kafka bootstrap)

# ── Elastic-APM (block 07) — APM ingest (:8200) + the APM-stack log-sink ES (:9200) ──
# The application log sink is the APM-stack Elasticsearch: block 07 `elasticsearch`
# line (http://elastic:<pass>@<host>:9200) + `elastic-pass`. NOT block 03 (:9201).
APM_URL=$(gv 07_Elastic_APM apm-ingest); APM_BEARER=$(gv 07_Elastic_APM apm-token)
ES_RAW=$(gv 07_Elastic_APM elasticsearch)            # http://elastic:<pass>@<host>:9200
ES_PASS=$(gv 07_Elastic_APM elastic-pass)
ES_HP="${ES_RAW##*@}"                                # <host>:9200
_es_user_tmp="${ES_RAW#*://}"; ES_USER="${_es_user_tmp%%:*}"   # elastic
ES_URL=""; [ -n "$ES_HP" ] && ES_URL="http://${ES_HP}"

for v in PG_HP PG_USER PG_PASS INFRA PG_PORT MO_URI RD_HOST RD_PORT KAFKA APM_URL APM_BEARER ES_URL ES_USER ES_PASS; do
  eval "x=\${$v:-}"
  [ -n "$x" ] || { echo "ERROR: could not parse $v from $ENVTXT" >&2; exit 3; }
done

# ── Auth identity (verify-only): auth's PUBLIC key + shared INTERNAL_SERVICE_TOKEN ──
# 07-coupon never MINTS JWTs (only 01-auth does). Read them block-scoped from the
# ### Auth_Identity block of components-creds.txt; if that block is still a placeholder,
# fall back to AUTH_ENV_FILE auto-discovery of 01-auth's rendered env.
JWT_PUB="${AUTH_PUBLIC_KEY_B64:-}"
INT_TOK="${AUTH_INTERNAL_TOKEN:-}"
[ -z "$JWT_PUB" ] && JWT_PUB=$(gv Auth_Identity auth_service_public_key)
[ -z "$INT_TOK" ] && INT_TOK=$(gv Auth_Identity internal_service_token)
# strip unfilled placeholders (gv returns the literal '<paste...' first token, which is non-empty)
case "$JWT_PUB" in ''|'<'*) JWT_PUB="";; esac
case "$INT_TOK" in ''|'<'*) INT_TOK="";; esac

AUTH_ENV_FILE="${AUTH_ENV_FILE:-}"
if [ -z "$AUTH_ENV_FILE" ]; then
  for f in /opt/dokandar/01-auth/env/.env.dev /opt/01-auth/env/.env.dev; do
    [ -f "$f" ] && { AUTH_ENV_FILE="$f"; break; }
  done
fi
if [ -n "$AUTH_ENV_FILE" ] && [ -f "$AUTH_ENV_FILE" ]; then
  [ -z "$JWT_PUB" ] && JWT_PUB=$(grep -E '^JWT_PUBLIC_KEY_B64=' "$AUTH_ENV_FILE" | head -1 | cut -d= -f2-)
  [ -z "$INT_TOK" ] && INT_TOK=$(grep -E '^INTERNAL_SERVICE_TOKEN=' "$AUTH_ENV_FILE" | head -1 | cut -d= -f2-)
fi
[ -n "$JWT_PUB" ] || echo "WARN: no JWT public key — authed routes will 503" >&2
[ -n "$INT_TOK" ] || echo "WARN: no INTERNAL_SERVICE_TOKEN — /validate accepts unauthenticated calls" >&2

DB="dokandar_coupon_${SUF}"
OUT="$HERE/$TARGET"
umask 077

cat > "$OUT" <<EOF
# ============================================================================
#  env/$TARGET  —  rendered by env/init-env.sh  from  env/components-creds.txt
#  REAL SECRETS · gitignored · never commit · re-run init-env.sh to rotate
#  legend —  get: copied from a components-creds.txt  "### NN_block"
#            gen: generated locally on every run (one-line command shown)
# ============================================================================

# -- Application / identity --------------------------------------------------
# get: static; APP_ENV from the .env.<env> target, TENANT=local(dev)/cloud(stage|prod)
APP_ENV=${SUF}
SERVICE_NAME=07-coupon
ENV_VERSION=v1.0.0
TENANT=${TENANT}
# note: INTERNAL container bind ports (host mapping 10007→8080 / 20007→9090 happens at docker run)
SERVICE_PORT=8080
GRPC_PORT=9090
LOG_LEVEL=info

# -- PostgreSQL (sole writer — GATES /ready) ---------------------------------
# get: components-creds.txt  ### 01_PostgreSQL  (host:port / user / password)
# note: POSTGRES_DB = dokandar_coupon_<env>
POSTGRES_HOST=${INFRA}
POSTGRES_PORT=${PG_PORT}
POSTGRES_USER=${PG_USER}
POSTGRES_PASSWORD=${PG_PASS}
POSTGRES_DB=${DB}

# -- Redis DB 6 (DEGRADABLE — does NOT gate /ready) --------------------------
# get: components-creds.txt  ### 04_Redis  (host:port / password)
REDIS_HOST=${RD_HOST}
REDIS_PORT=${RD_PORT}
REDIS_PASSWORD=${RD_PASS}
REDIS_DB=6
COUPON_CACHE_TTL_SECONDS=60
REDEEM_LOCK_TTL_SECONDS=5

# -- Kafka (producer-only via outbox; acks=all + idempotent producer) --------
# get: components-creds.txt  ### 05_Kafka  (bootstrap);  topic names below are fixed
KAFKA_BOOTSTRAP=${KAFKA}
KAFKA_TOPIC_COUPON_DRAFTED=dokandar.coupon.drafted
KAFKA_TOPIC_COUPON_APPROVED=dokandar.coupon.approved
KAFKA_TOPIC_COUPON_REVOKED=dokandar.coupon.revoked
OUTBOX_POLL_INTERVAL_SECONDS=1.0
OUTBOX_BATCH_SIZE=100

# -- Mongo + ES log sinks ----------------------------------------------------
# get: components-creds.txt  ### 02_MongoDB (endpoint) + ### 07_Elastic_APM (elasticsearch :9200 + elastic-pass)
# note: ES log sink is the APM-stack ES (:9200), NOT block 03 (:9201, search/review only)
MONGO_LOG_URI=${MO_URI}
MONGO_LOG_DB=mongo_db_dokandar_application_logs
ELASTIC_SEARCH_URL=${ES_URL}
ELASTIC_SEARCH_USERNAME=${ES_USER}
ELASTIC_SEARCH_PASSWORD=${ES_PASS}

# -- Elastic APM (traces) ----------------------------------------------------
# get: components-creds.txt  ### 07_Elastic_APM  (apm-ingest :8200 / apm-token)
APM_SERVER_URL=${APM_URL}
APM_SECRET_TOKEN=${APM_BEARER}
APM_SERVICE_NAME=07-coupon

# -- JWT verify-only + east-west INTERNAL_SERVICE_TOKEN ----------------------
# get: components-creds.txt  ### Auth_Identity  (auth_service_public_key / internal_service_token)
# note: 07-coupon VERIFIES only — it never mints JWTs (01-auth is the sole key holder)
JWT_PUBLIC_KEY_B64=${JWT_PUB}
JWT_ISSUER=dokandar-auth
INTERNAL_SERVICE_TOKEN=${INT_TOK}
EOF
chmod 600 "$OUT"

echo "✓ wrote $OUT"
echo "  SERVICE_NAME=07-coupon  POSTGRES_DB=$DB  INFRA=$INFRA  REDIS_DB=6  REST=8080(int)/10007(host)"
echo "  JWT public key: ${AUTH_PUBLIC_KEY_B64:+from env}${AUTH_PUBLIC_KEY_B64:-from ${AUTH_ENV_FILE:-<none>}}"
echo "  INTERNAL_SERVICE_TOKEN: ${AUTH_INTERNAL_TOKEN:+from env}${AUTH_INTERNAL_TOKEN:-from ${AUTH_ENV_FILE:-<none>}}"
