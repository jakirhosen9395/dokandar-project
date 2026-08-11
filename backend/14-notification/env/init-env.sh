#!/usr/bin/env bash
# env/init-env.sh — render env/.env.<env> for 14-notification from env/components-creds.txt.
#
# 14-notification (Node.js 24 / Fastify 5) is the event-to-user fan-out fabric and is
# VERIFY-ONLY:
#   * MongoDB (the bilingual inbox — notifications/preferences/dispatch-log) — GATED on /ready
#   * Redis DB 10 (Kafka dedup + WS user→pod routing + cross-pod pub/sub) — degradable
#   * Kafka: consume-only (user.created, order.placed, payment.*, kyc.*, wallet.cashback_granted)
#   * RabbitMQ: per-channel dispatch queues (email/sms/push/whatsapp_deeplink) + drains
#     notifications.otp.send from 01-auth
#   * NATS JetStream: low-latency WebSocket fan-out subjects (NOT a durability path)
#   * NO Postgres, NO outbox, NO gRPC (exposes none, calls none)
#   * Application LOG SINK: the APM-stack Elasticsearch (block 07, :9200 — the
#     `elasticsearch` line + `elastic-pass`). Block 03 (:9201) is NOT read.
#   * RS256 verify-only: it reads auth's PUBLIC key + the shared
#     INTERNAL_SERVICE_TOKEN from the `### Auth_Identity` block of
#     components-creds.txt (it NEVER generates a keypair). If that block is still
#     a placeholder, it falls back to $AUTH_PUBLIC_KEY_B64 / $AUTH_INTERNAL_TOKEN
#     or $AUTH_ENV_FILE (auth's rendered .env.dev).
#
# Reads infra blocks: 02_MongoDB, 04_Redis, 05_Kafka, 06_RabbitMQ, 07_Elastic_APM, 15_NATS.
#
# Usage:  ./env/init-env.sh                                    # → env/.env.dev
#         ./env/init-env.sh .env.prod                          # → env/.env.prod
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

# Mongo — the inbox store (and the structured-log forensic sink)
MO_URI=$(gv 02_MongoDB endpoint)
MO_HP=$(gv 02_MongoDB host:port)
INFRA=$(host_of "$MO_HP")

# Redis — DB 10 (dedup + WS routing)
RD_HP=$(gv 04_Redis host:port); RD_PASS=$(gv 04_Redis password)
RD_HOST=$(host_of "$RD_HP"); RD_PORT=$(port_of "$RD_HP")

# Kafka (consume-only)
KAFKA=$(gv 05_Kafka bootstrap)

# RabbitMQ — per-channel dispatch queues + the OTP drain
RMQ_URL=$(gv 06_RabbitMQ amqp-url)

# NATS JetStream — WS fan-out subjects (NOT durable)
NATS_URL=$(gv 15_NATS client-url)

# ---- Elastic-APM (block 07) — APM ingest/bearer + the APM-stack Elasticsearch -
# 14-notification ships its application logs into the APM-stack ES (:9200 — the
# block-07 `elasticsearch` line + `elastic-pass`); traces go to the APM ingest
# (:8200). Block 03 (:9201) is the search/review business ES and is NOT read here.
APM_URL=$(gv 07_Elastic_APM apm-ingest); APM_BEARER=$(gv 07_Elastic_APM apm-token)
ES_RAW=$(gv 07_Elastic_APM elasticsearch)            # http://elastic:<pass>@<host>:9200
ES_PASS=$(gv 07_Elastic_APM elastic-pass)
ES_HP="${ES_RAW##*@}"                                # <host>:9200
_es_user_tmp="${ES_RAW#*://}"; ES_USER="${_es_user_tmp%%:*}"   # elastic
ES_URL="http://${ES_HP}"

for v in MO_URI INFRA RD_HOST RD_PORT RD_PASS KAFKA RMQ_URL NATS_URL APM_URL APM_BEARER ES_URL ES_USER ES_PASS; do
  eval "x=\${$v:-}"
  [ -n "$x" ] || { echo "ERROR: could not parse $v from $ENVTXT" >&2; exit 3; }
done

# ── auth's PUBLIC key + shared INTERNAL_SERVICE_TOKEN (verify-only) ──────────
# Primary source: the `### Auth_Identity` block in components-creds.txt. If still
# a placeholder, fall back to env vars or auth's rendered .env.dev. NEVER a
# private key — 14-notification only verifies JWTs, it never mints them.
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

DB="dokandar_notification_${SUF}"
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
SERVICE_NAME=14-notification
ENV_VERSION=v1.0.0
TENANT=${TENANT}
SERVICE_PORT=3000
LOG_LEVEL=info

# -- MongoDB (the bilingual inbox store — gated on /ready) -------------------
# get: components-creds.txt  ### 02_MongoDB  (endpoint / host:port / user / password)
MONGO_URI=${MO_URI}
MONGO_DB=${DB}

# -- Redis DB 10 (dedup + WS user→pod routing + cross-pod pub/sub) -----------
# get: components-creds.txt  ### 04_Redis  (host:port / password)
REDIS_HOST=${RD_HOST}
REDIS_PORT=${RD_PORT}
REDIS_PASSWORD=${RD_PASS}
REDIS_DB=10
NOTIF_DEDUP_TTL_SECONDS=86400

# -- NATS JetStream (WS fan-out subjects — NOT a durability path) ------------
# get: components-creds.txt  ### 15_NATS  (client-url)
NATS_URL=${NATS_URL}
NATS_WS_SUBJECT_PREFIX=dokandar.ws.inbox

# -- Kafka (consume-only) ----------------------------------------------------
# get: components-creds.txt  ### 05_Kafka  (bootstrap);  topic names below are fixed
KAFKA_BOOTSTRAP=${KAFKA}
KAFKA_TOPIC_USER_CREATED=dokandar.user.created
KAFKA_TOPIC_ORDER_PLACED=dokandar.order.placed
KAFKA_TOPIC_PAYMENT_SETTLED=dokandar.payment.settled
KAFKA_TOPIC_KYC_APPROVED=dokandar.kyc.approved
KAFKA_TOPIC_KYC_REJECTED=dokandar.kyc.rejected
KAFKA_TOPIC_WALLET_CASHBACK=dokandar.wallet.cashback_granted

# -- RabbitMQ (per-channel dispatch queues + the OTP drain) ------------------
# get: components-creds.txt  ### 06_RabbitMQ  (amqp-url);  queue names below are fixed
RABBITMQ_URL=${RMQ_URL}
RABBITMQ_QUEUES=notifications.email,notifications.sms,notifications.push,notifications.whatsapp_deeplink
RABBITMQ_QUEUE_OTP=notifications.otp.send

# -- External channel providers ----------------------------------------------
# get: static; blank in dev — paste real provider creds in stage/prod
SSL_WIRELESS_API_KEY=
WHATSAPP_CLOUD_TOKEN=
FCM_SERVER_KEY=
AWS_SES_REGION=

# -- Mongo log sink (structured-log forensic sink, collection = 14-notification) --
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
APM_SERVICE_NAME=14-notification

# -- JWT verify-only (auth's PUBLIC key) + east-west token -------------------
# get: components-creds.txt  ### Auth_Identity  (auth_service_public_key / internal_service_token)
JWT_PUBLIC_KEY_B64=${JWT_PUB}
JWT_ISSUER=dokandar-auth
INTERNAL_SERVICE_TOKEN=${INT_TOK}
EOF
chmod 600 "$OUT"

echo "✓ wrote $OUT"
echo "  SERVICE_NAME=14-notification  MONGO_DB=$DB  INFRA=$INFRA  REDIS_DB=10  REST=3000  no gRPC  no Postgres"
echo "  ES log sink=$ES_URL (APM-stack :9200)   APM=$APM_URL   Kafka=$KAFKA"
echo "  RabbitMQ=amqp://…@${RMQ_URL##*@}   NATS=${NATS_URL}"
echo "  JWT public key + INTERNAL_SERVICE_TOKEN: verify-only (no private key)"
