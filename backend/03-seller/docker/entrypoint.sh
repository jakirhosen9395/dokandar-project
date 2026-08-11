#!/usr/bin/env bash
# Container entrypoint: bootstrap DB + run migrations + start HTTP server.
# Bootstrap output is emitted in the canonical fleet log shape (pretty JSON
# {asctime,name,levelname,message}) so it matches the running service's logs;
# Laravel/artisan plain output is captured and only surfaced on failure.
set -euo pipefail
cd /app

# canonical pretty-JSON log line (name=seller.entrypoint). message must be plain.
jlog() {
    local msg; msg=$(printf '%s' "$2" | tr -d '\n"' | cut -c1-400)
    printf '{\n  "asctime": "%s",\n  "name": "seller.entrypoint",\n  "levelname": "%s",\n  "message": "%s"\n}\n' \
        "$(date '+%Y-%m-%d %H:%M:%S,%3N')" "$1" "$msg"
}

# Stamp container boot time — read by App\Support\BootTime so /ready reports a
# real uptime_seconds (php -S is request-per-process, so uptime would be 0).
date +%s > /tmp/dokandar-seller.boot
chmod 0644 /tmp/dokandar-seller.boot

# Config is injected at RUNTIME via docker --env-file (process env). There is
# no .env inside the image; SkipEnvLoader (bootstrap/app.php) stops Laravel
# opening /app/.env. env() still works via $_ENV/$_SERVER (EGPCS).

if [ -z "${APP_KEY:-}" ]; then
    export APP_KEY="base64:$(php -r "echo base64_encode(random_bytes(32));" 2>/dev/null)"
    jlog INFO "generated ephemeral APP_KEY (not persisted)"
fi

# Elastic APM agent — runtime docker context + service-node / global-labels,
# matching auth (Python) / profile (Go). Picked up by the elastic_apm PHP
# extension if it loaded; harmless otherwise.
if [ -z "${ELASTIC_APM_SERVICE_NODE_NAME:-}" ]; then
    if [ -f /.dockerenv ] && [ -r /etc/hostname ]; then
        CID="$(cat /etc/hostname)"
        export ELASTIC_APM_SERVICE_NODE_NAME="$CID"
        export ELASTIC_APM_GLOBAL_LABELS="${ELASTIC_APM_GLOBAL_LABELS:-runtime=docker,container_id=${CID},container_runtime=docker}"
    fi
fi
[ -z "${ELASTIC_APM_SERVER_URL:-}"     ] && [ -n "${APM_SERVER_URL:-}"    ] && export ELASTIC_APM_SERVER_URL="$APM_SERVER_URL"
[ -z "${ELASTIC_APM_SECRET_TOKEN:-}"   ] && [ -n "${APM_SECRET_TOKEN:-}"  ] && export ELASTIC_APM_SECRET_TOKEN="$APM_SECRET_TOKEN"
[ -z "${ELASTIC_APM_SERVICE_NAME:-}"   ] && [ -n "${APM_SERVICE_NAME:-}"  ] && export ELASTIC_APM_SERVICE_NAME="$APM_SERVICE_NAME"
[ -z "${ELASTIC_APM_ENVIRONMENT:-}"    ] && [ -n "${APP_ENV:-}"           ] && export ELASTIC_APM_ENVIRONMENT="$APP_ENV"
[ -z "${ELASTIC_APM_SERVICE_VERSION:-}"] && [ -f /app/CODE_VERSION         ] && export ELASTIC_APM_SERVICE_VERSION="$(cat /app/CODE_VERSION)"
jlog INFO "APM env: service=${ELASTIC_APM_SERVICE_NAME:-?} url=${ELASTIC_APM_SERVER_URL:-?} node=${ELASTIC_APM_SERVICE_NODE_NAME:-?}"
if php -m 2>/dev/null | grep -q '^elastic_apm$'; then jlog INFO "elastic_apm extension loaded"; else jlog WARNING "elastic_apm extension NOT loaded — traces will not be sent"; fi

jlog INFO "ensure DB exists"
if ! out=$(php artisan shop:ensure-db 2>&1); then jlog ERROR "ensure-db failed: $out"; exit 1; fi

jlog INFO "running migrations (force, idempotent)"
if ! out=$(php artisan migrate --force --no-interaction --no-ansi 2>&1); then jlog ERROR "migration failed: $out"; exit 1; fi

jlog INFO "seeding BD admin areas (idempotent)"
out=$(php artisan db:seed --class=BdAdminAreasSeeder --force --no-interaction --no-ansi 2>&1) || jlog WARNING "bd_admin_areas seed skipped: $out"

jlog INFO "starting outbox relay (background)"
# display_startup_errors=Off suppresses the elastic_apm "already loaded" startup
# notice (it prints to stdout, so a stderr redirect can't catch it); the relay's
# real logs go to stdout via Monolog in the canonical JSON shape.
php -d display_startup_errors=Off artisan shop:relay-outbox --interval=2 &
RELAY_PID=$!
jlog INFO "outbox relay pid=$RELAY_PID"

jlog INFO "starting KYC events consumer (background)"
php -d display_startup_errors=Off artisan shop:consume-kyc-events &
KYC_PID=$!
jlog INFO "kyc-consumer pid=$KYC_PID"

trap "kill $RELAY_PID $KYC_PID 2>/dev/null || true" EXIT

jlog INFO "starting HTTP server on :${SERVICE_PORT:-8000}"
# php -S writes its own access log + the elastic_apm startup notice to stderr —
# dropped so stdout stays the clean JSON + uvicorn stream. App errors surface
# via the JSON exception handler + Monolog stdout channel.
exec php -S 0.0.0.0:${SERVICE_PORT:-8000} -t public server.php 2>/dev/null
