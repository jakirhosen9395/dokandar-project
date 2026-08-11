#!/usr/bin/env bash
# env/init-env.sh — render env/.env.<env> for 17-shipping from env/components-creds.txt
#
# env/components-creds.txt holds the infra credentials paste in the `### NN_Service`
# format (PostgreSQL / MongoDB / Kafka / Elastic-APM / Neo4j) PLUS an `### Auth_Identity`
# block carrying auth's PUBLIC key + the shared INTERNAL_SERVICE_TOKEN.
#
# 17-shipping (Ruby/Rails) is VERIFY-ONLY: it needs auth's PUBLIC key + the shared
# INTERNAL_SERVICE_TOKEN (NEVER a private key) to verify JWTs and authenticate
# east-west calls. Those are read from the `### Auth_Identity` block; if that block
# is still a placeholder, the script falls back to auto-discovering the deployed
# 01-auth's rendered .env.dev (AUTH_ENV_FILE). It NEVER generates a keypair.
#
# Usage:  ./env/init-env.sh                      # -> env/.env.dev
#         ./env/init-env.sh .env.dev             # -> env/.env.dev
#         ./env/init-env.sh .env.prod            # -> env/.env.prod
#         AUTH_PUBLIC_KEY_B64=… AUTH_INTERNAL_TOKEN=… ./env/init-env.sh .env.dev
#         AUTH_ENV_FILE=/path/to/auth/.env.dev ./env/init-env.sh .env.dev
#         CREDS_FILE=/path/to/components-creds.txt ./env/init-env.sh .env.dev
#
# Required tooling: bash, awk.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-.env.dev}"; TARGET="${TARGET##*/}"
case "$TARGET" in .env.*) ;; *) echo "ERROR: target must be .env.<env>" >&2; exit 2;; esac
SUF="${TARGET#.env.}"; [ "$SUF" = "dev" ] && TENANT="local" || TENANT="cloud"

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

# gv <block-header-suffix> <field-key>  -> the field's first value token.
# Matches '### NN_Service' headers and 'key  value' rows; value = 2nd column,
# so trailing '(comment)' notes after a URL are ignored.
gv(){ awk -v hdr="$1" -v key="$2" '
  $0 ~ "^###[[:space:]]+"hdr"([[:space:]]|$)" { on=1; next }
  on && /^###/ { exit }
  on && $1==key { print $2; exit }
' "$ENVTXT"; }
port_of(){ printf '%s' "${1##*:}"; }; host_of(){ printf '%s' "${1%:*}"; }

echo "→ parsing $ENVTXT" >&2

# ---- PostgreSQL (block 01) — INFRA host is derived from here -----------------
PG_HP=$(gv 01_PostgreSQL host:port); PG_USER=$(gv 01_PostgreSQL user); PG_PASS=$(gv 01_PostgreSQL password)
INFRA=$(host_of "$PG_HP"); PG_PORT=$(port_of "$PG_HP")

# ---- MongoDB (block 02) — structured-log forensic sink ----------------------
MO_URI=$(gv 02_MongoDB endpoint); MO_HP=$(gv 02_MongoDB host:port); MO_PORT=$(port_of "$MO_HP"); MO_USER=$(gv 02_MongoDB user); MO_PASS=$(gv 02_MongoDB password)

# ---- Kafka (block 05) -------------------------------------------------------
KAFKA=$(gv 05_Kafka bootstrap)

# ---- Neo4j (block 13) — road-graph vehicle routing (bolt) -------------------
NEO4J_BOLT=$(gv 13_Neo4j bolt); NEO4J_USER=$(gv 13_Neo4j user); NEO4J_PASS=$(gv 13_Neo4j password)

# ---- Elastic-APM (block 07) — APM ingest/bearer + the APM-stack Elasticsearch -
# 17-shipping uses the APM stack for ALL observability: traces via the APM ingest
# (:8200) and application-log shipping into the APM-stack ES (:9200 — the block-07
# `elasticsearch` line + `elastic-pass`). Block 03 (:9201) is NOT read here — that
# standalone ES is the search/review business store used ONLY by 05-search/08-review.
APM_URL=$(gv 07_Elastic_APM apm-ingest); APM_BEARER=$(gv 07_Elastic_APM apm-token)
ES_RAW=$(gv 07_Elastic_APM elasticsearch)            # http://elastic:<pass>@<host>:9200
ES_PASS=$(gv 07_Elastic_APM elastic-pass)
ES_HP="${ES_RAW##*@}"                                # <host>:9200
_es_user_tmp="${ES_RAW#*://}"; ES_USER="${_es_user_tmp%%:*}"   # elastic
ES_URL="http://${ES_HP}"

# ---- sanity -----------------------------------------------------------------
miss=""
for v in PG_HP PG_USER PG_PASS INFRA PG_PORT MO_URI KAFKA NEO4J_BOLT NEO4J_USER NEO4J_PASS ES_URL ES_USER ES_PASS APM_URL APM_BEARER; do
  eval "x=\${$v:-}"; [ -n "$x" ] || miss="$miss $v"
done
[ -z "$miss" ] || { echo "ERROR: could not parse from components-creds.txt:$miss" >&2; echo "  check the '### NN_Service' headers / field names match env/components-creds.example.txt" >&2; exit 3; }

# ---- auth's PUBLIC key + shared INTERNAL_SERVICE_TOKEN (verify-only) ---------
# Primary source: the `### Auth_Identity` block of components-creds.txt
#   auth_service_public_key  <auth's JWT_PUBLIC_KEY_B64>
#   internal_service_token   <auth's INTERNAL_SERVICE_TOKEN>
# Fallback (block still a placeholder): env override, else auto-discover the
# deployed 01-auth's rendered .env.dev. 17-shipping NEVER generates a keypair.
JWT_PUB="${AUTH_PUBLIC_KEY_B64:-$(gv Auth_Identity auth_service_public_key)}"
INT_TOK="${AUTH_INTERNAL_TOKEN:-$(gv Auth_Identity internal_service_token)}"
case "$JWT_PUB" in ""|"<"*) JWT_PUB="";; esac   # treat empty / "<placeholder>" as unset
case "$INT_TOK" in ""|"<"*) INT_TOK="";; esac
AUTH_ENV_FILE="${AUTH_ENV_FILE:-/opt/dokandar/01-auth/env/.env.dev}"
if [ -z "$JWT_PUB" ] && [ -f "$AUTH_ENV_FILE" ]; then
  JWT_PUB=$(grep -E '^JWT_PUBLIC_KEY_B64=' "$AUTH_ENV_FILE" | head -1 | cut -d= -f2-)   # PUBLIC only — never the private key
fi
if [ -z "$INT_TOK" ] && [ -f "$AUTH_ENV_FILE" ]; then
  INT_TOK=$(grep -E '^INTERNAL_SERVICE_TOKEN=' "$AUTH_ENV_FILE" | head -1 | cut -d= -f2-)
fi
[ -n "$JWT_PUB" ] || { echo "ERROR: no JWT public key. Paste auth's JWT_PUBLIC_KEY_B64 into the ### Auth_Identity block (auth_service_public_key), or set AUTH_PUBLIC_KEY_B64=… / AUTH_ENV_FILE=path to auth's rendered .env.dev." >&2; exit 3; }
[ -n "$INT_TOK" ] || { echo "ERROR: no INTERNAL_SERVICE_TOKEN. Paste auth's value into the ### Auth_Identity block (internal_service_token), or set AUTH_INTERNAL_TOKEN=… / AUTH_ENV_FILE." >&2; exit 3; }

DB="dokandar_shipping_${SUF}"
OUT="$HERE/$TARGET"; umask 077

# Courier webhook signing secret (HMAC verify of inbound courier callbacks). dev/stage have
# no real courier, so it's generated; PRESERVE an already-rendered value so a re-run does NOT
# rotate it (which would break the deployed webhook). Prod: paste real per-courier secrets into
# a ### 17_Courier_Webhooks block and read them here.
WEBHOOK_SECRET="${SHIPPING_WEBHOOK_SECRET:-}"
if [ -z "$WEBHOOK_SECRET" ] && [ -f "$OUT" ]; then
  # awk exits 0 even on no-match (a grep|cut pipeline exits 1 → trips set -e/pipefail and
  # silently leaves the secret empty — the bug that shipped an empty value the first time).
  WEBHOOK_SECRET=$(awk -F= '/^SHIPPING_WEBHOOK_SECRET=/{print $2; exit}' "$OUT" || true)
fi
if [ -z "$WEBHOOK_SECRET" ]; then
  WEBHOOK_SECRET=$(openssl rand -hex 24 2>/dev/null || python3 -c 'import secrets;print(secrets.token_hex(24))')
fi

cat > "$OUT" <<EOF
# ============================================================================
#  env/${TARGET}  —  rendered by env/init-env.sh  from  env/components-creds.txt
#  REAL SECRETS · gitignored · never commit · re-run init-env.sh to re-render (webhook secret preserved; verify-only — no keypair here)
#  legend —  get: copied from a components-creds.txt  "### NN_block"
#            gen: generated locally on every run (one-line command shown)
# ============================================================================

# -- Application / identity --------------------------------------------------
# get: static; APP_ENV from the .env.<env> target, TENANT=local(dev)/cloud(stage|prod)
APP_ENV=${SUF}
SERVICE_NAME=17-shipping
ENV_VERSION=v1.0.0
TENANT=${TENANT}
SERVICE_PORT=8000
GRPC_PORT=8001
GRPC_ENABLED=true
LOG_LEVEL=info

# -- PostgreSQL --------------------------------------------------------------
# get: components-creds.txt  ### 01_PostgreSQL  (host:port / user / password)
# note: POSTGRES_DB = dokandar_shipping_<env>; the *_DSN are built from the block + DB name
POSTGRES_HOST=${INFRA}
POSTGRES_PORT=${PG_PORT}
POSTGRES_USER=${PG_USER}
POSTGRES_PASSWORD=${PG_PASS}
POSTGRES_DB=${DB}
POSTGRES_DSN=postgres://${PG_USER}:${PG_PASS}@${INFRA}:${PG_PORT}/${DB}?sslmode=disable
POSTGRES_ADMIN_DSN=postgres://${PG_USER}:${PG_PASS}@${INFRA}:${PG_PORT}/postgres?sslmode=disable

# -- Neo4j (road-graph vehicle routing) --------------------------------------
# get: components-creds.txt  ### 13_Neo4j  (bolt / user / password);  DATABASE = dokandar_road_graph
NEO4J_URL=${NEO4J_BOLT}
NEO4J_USERNAME=${NEO4J_USER}
NEO4J_PASSWORD=${NEO4J_PASS}
NEO4J_DATABASE=dokandar_road_graph

# -- Kafka -------------------------------------------------------------------
# get: components-creds.txt  ### 05_Kafka  (bootstrap);  topic names below are fixed
KAFKA_BOOTSTRAP=${KAFKA}
KAFKA_CONSUMER_GROUP=shipping

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
APM_SERVICE_NAME=17-shipping

# -- Courier webhook signing secret (HMAC verify of inbound courier status callbacks) --
# gen: openssl rand -hex 24 (dev/stage; prod renders real per-courier secrets). The webhook
# controller reads <COURIER>_WEBHOOK_SECRET, falling back to this — so no dev literal remains.
SHIPPING_WEBHOOK_SECRET=${WEBHOOK_SECRET}

# -- JWT / east-west auth: VERIFY-ONLY (auth's PUBLIC key + shared token) -----
# get: components-creds.txt  ### Auth_Identity  (auth_service_public_key / internal_service_token)
# note: or auto-discovered from the deployed 01-auth's .env.dev. NEVER a private key.
JWT_PUBLIC_KEY_B64=${JWT_PUB}
JWT_ISSUER=dokandar-auth
INTERNAL_SERVICE_TOKEN=${INT_TOK}
EOF
chmod 600 "$OUT"
echo "✓ wrote $OUT"
echo "  SERVICE_NAME=17-shipping  POSTGRES_DB=$DB  INFRA=$INFRA"
echo "  ES log sink=$ES_URL   APM=$APM_URL   Kafka=$KAFKA   Neo4j=$NEO4J_BOLT"
echo "  JWT public key + INTERNAL_SERVICE_TOKEN: verify-only (no private key)."
