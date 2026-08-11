#!/usr/bin/env bash
# env/init-env.sh — render env/.env.<env> for 15-api-gateway from env/components-creds.txt
#
# env/components-creds.txt holds the infra credentials paste in the `### NN_Service`
# format (MongoDB / Redis / Elastic-APM) PLUS an `### Auth_Identity` block carrying
# auth's PUBLIC key + the shared INTERNAL_SERVICE_TOKEN.
#
# 15-api-gateway (Go) is the STATELESS edge: no PostgreSQL / Kafka / RabbitMQ. Redis
# DB13 is its only datastore (the token-bucket rate-limiter). It is VERIFY-ONLY: it
# needs auth's PUBLIC key + the shared INTERNAL_SERVICE_TOKEN (NEVER a private key) to
# verify JWTs and authenticate east-west calls. Those are read from the
# `### Auth_Identity` block; if that block is still a placeholder, the script falls back
# to auto-discovering the deployed 01-auth's rendered .env.dev (AUTH_ENV_FILE). It NEVER
# generates a keypair.
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

# ---- Redis (block 04) — INFRA host is derived from here ----------------------
# 15-api-gateway is stateless: there is NO PostgreSQL block, so the shared infra
# host is taken from the Redis block. Redis DB13 backs the token-bucket rate-limiter.
RE_HP=$(gv 04_Redis host:port); RE_PASS=$(gv 04_Redis password)
INFRA=$(host_of "$RE_HP"); RE_PORT=$(port_of "$RE_HP")

# ---- upstream / edge host knobs ---------------------------------------------
# Upstreams are the OTHER 18 services, not infra. They are published on a host at
# the external 100NN ports. By default that host is the same INFRA host (single-
# node fleet); override APP_HOST=<ip|dns> for a split topology, AUTH_HOST=<ip> to
# point JWKS at a specific 01-auth, or run with 172.17.0.1 from inside a container
# (the docker-bridge gateway — see commands.md). The literal :100NN ports are
# fixed per the fleet table (auth=10001 … risk=10018).
APP_HOST="${APP_HOST:-172.17.0.1}"  # docker-bridge -> host (siblings/auth publish 100NN on the app host, NOT the infra host)
AUTH_HOST="${AUTH_HOST:-$APP_HOST}"

# ---- MongoDB (block 02) — structured-log forensic sink ----------------------
MO_URI=$(gv 02_MongoDB endpoint); MO_HP=$(gv 02_MongoDB host:port); MO_PORT=$(port_of "$MO_HP"); MO_USER=$(gv 02_MongoDB user); MO_PASS=$(gv 02_MongoDB password)

# ---- Elastic-APM (block 07) — APM ingest/bearer + the APM-stack Elasticsearch -
# 15-api-gateway uses the APM stack for ALL observability: traces via the APM ingest
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
for v in RE_HP RE_PASS INFRA RE_PORT MO_URI ES_URL ES_USER ES_PASS APM_URL APM_BEARER; do
  eval "x=\${$v:-}"; [ -n "$x" ] || miss="$miss $v"
done
[ -z "$miss" ] || { echo "ERROR: could not parse from components-creds.txt:$miss" >&2; echo "  check the '### NN_Service' headers / field names match env/components-creds.example.txt" >&2; exit 3; }

# ---- auth's PUBLIC key + shared INTERNAL_SERVICE_TOKEN (verify-only) ---------
# Primary source: the `### Auth_Identity` block of components-creds.txt
#   auth_service_public_key  <auth's JWT_PUBLIC_KEY_B64>
#   internal_service_token   <auth's INTERNAL_SERVICE_TOKEN>
# Fallback (block still a placeholder): env override, else auto-discover the
# deployed 01-auth's rendered .env.dev. 15-api-gateway NEVER generates a keypair.
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

OUT="$HERE/$TARGET"; umask 077
cat > "$OUT" <<EOF
# ============================================================================
#  env/${TARGET}  —  rendered by env/init-env.sh  from  env/components-creds.txt
#  REAL SECRETS · gitignored · never commit · re-run init-env.sh to re-render (verify-only: no keypair is ever generated here)
#  legend —  get: copied from a components-creds.txt  "### NN_block"
#            gen: generated locally on every run (one-line command shown)
# ============================================================================

# -- Application / identity --------------------------------------------------
# get: static; APP_ENV from the .env.<env> target, TENANT=local(dev)/cloud(stage|prod)
APP_ENV=${SUF}
SERVICE_NAME=15-api-gateway
ENV_VERSION=v1.0.0
TENANT=${TENANT}
SERVICE_PORT=8080
GRPC_ENABLED=false
LOG_LEVEL=info

# -- Redis -------------------------------------------------------------------
# get: components-creds.txt  ### 04_Redis  (host:port / password);  gateway uses DB 13 for the token-bucket rate-limiter
REDIS_HOST=${INFRA}
REDIS_PORT=${RE_PORT}
REDIS_PASSWORD=${RE_PASS}
REDIS_URL=redis://default:${RE_PASS}@${INFRA}:${RE_PORT}/13
RATE_LIMIT_REDIS_DB=13

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
APM_SERVICE_NAME=15-api-gateway

# -- JWT / east-west auth: VERIFY-ONLY (auth's PUBLIC key + shared token) -----
# get: ### Auth_Identity (auth_service_public_key / internal_service_token),
#      or auto-discovered from the deployed 01-auth's .env.dev. NEVER a private key.
JWT_PUBLIC_KEY_B64=${JWT_PUB}
JWT_ISSUER=dokandar-auth
INTERNAL_SERVICE_TOKEN=${INT_TOK}

# -- JWKS verify (primary) + static-key fallback ------------------------------
# get: static; AUTH_HOST derived from APP_HOST (default = the Redis INFRA host).
# JWKS is PRIMARY: verify Bearer tokens against the 5-min in-process cache of
# 01-auth's JWKS, algorithms PINNED to RS256 (reject alg:none/HS256). If JWKS_URL
# is unreachable the verifier serves from cache; if JWKS_URL is empty the static
# JWT_PUBLIC_KEY_B64 above is the fallback verifier key.
JWKS_URL=http://${AUTH_HOST}:10001/api/v1/auth/jwks
JWKS_CACHE_TTL_SECONDS=300
JWT_ALGORITHMS=RS256
# JWT_AUDIENCE=dokandar          # uncomment to enforce aud (off by default in dev)

# -- Rate-limit (token bucket; Redis DB13) ------------------------------------
# get: static defaults; per-route overrides live in code (search/payment tighter).
RATE_LIMIT_MAX=120
RATE_LIMIT_WINDOW_MS=1000

# -- CORS + true-client-IP ----------------------------------------------------
# get: static. CORS_ALLOWLIST='*' is DEV-ONLY (architecture.md §12/§16-e) — set an
# explicit origin allowlist in stage/prod. TRUSTED_PROXY_CIDRS gates which peer's
# X-Forwarded-For is believed for the true-client-IP derivation (Cloudflare ranges
# in prod); the docker bridge + RFC1918 are the dev default.
CORS_ALLOWLIST=*
TRUSTED_PROXY_CIDRS=127.0.0.1/32,172.16.0.0/12,10.0.0.0/8,192.168.0.0/16

# -- Upstreams (verbatim proxy targets) ---------------------------------------
# get: static; APP_HOST + the fixed :100NN external ports (fleet table). Parsed by
# config.Load() into {auth, profile, …}. From inside a container set these to the
# docker-bridge gateway (172.17.0.1) per commands.md; behind Istio use mesh DNS.
UPSTREAM_READ_TIMEOUT_MS=5000
UPSTREAM_SUPPORT=http://${APP_HOST}:10099
UPSTREAM_AUTH=http://${APP_HOST}:10001
UPSTREAM_PROFILE=http://${APP_HOST}:10002
UPSTREAM_SELLER=http://${APP_HOST}:10003
UPSTREAM_CATALOG=http://${APP_HOST}:10004
UPSTREAM_SEARCH=http://${APP_HOST}:10005
UPSTREAM_CART=http://${APP_HOST}:10006
UPSTREAM_COUPON=http://${APP_HOST}:10007
UPSTREAM_REVIEW=http://${APP_HOST}:10008
UPSTREAM_PAYMENT=http://${APP_HOST}:10009
UPSTREAM_WALLET=http://${APP_HOST}:10010
UPSTREAM_REPORTING=http://${APP_HOST}:10011
UPSTREAM_MEDIA=http://${APP_HOST}:10012
UPSTREAM_ORDER=http://${APP_HOST}:10013
UPSTREAM_NOTIFICATION=http://${APP_HOST}:10014
UPSTREAM_API_GATEWAY=http://${APP_HOST}:10015
UPSTREAM_RECOMMENDATION=http://${APP_HOST}:10016
UPSTREAM_SHIPPING=http://${APP_HOST}:10017
UPSTREAM_RISK=http://${APP_HOST}:10018
EOF
chmod 600 "$OUT"
echo "✓ wrote $OUT"
echo "  SERVICE_NAME=15-api-gateway  INFRA=$INFRA  APP_HOST=$APP_HOST  (stateless — Redis DB13 only)"
echo "  ES log sink=$ES_URL   APM=$APM_URL"
echo "  JWT public key + INTERNAL_SERVICE_TOKEN: verify-only (no private key)."
echo "  JWKS_URL=http://${AUTH_HOST}:10001/api/v1/auth/jwks  (primary; static key = fallback)"
echo "  UPSTREAM_<SVC> table: 18 services on ${APP_HOST}:100NN  (override APP_HOST/AUTH_HOST; use 172.17.0.1 in a container)"
echo "  CORS_ALLOWLIST=*  (DEV ONLY — set an explicit allowlist in stage/prod)"
