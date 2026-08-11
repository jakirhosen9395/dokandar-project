#!/usr/bin/env bash
#==============================================================================
# DOKANDAR utilities — UNIFIED one-host orchestrator (utility1 + utility2)
#------------------------------------------------------------------------------
# One file that drives BOTH bundles on a SINGLE machine: it merges every tool
# from utility1/ and utility2/, sorts them 01..16, and brings the whole fleet up
# (or down/purge/status) in one chosen install variant. Use this when you run
# everything on ONE box; use 01_/02_utility_setup.sh to split across two boxes.
#
#   Usage:   bash setup.sh [variant] [action]
#            bash setup.sh <action>            # action-first; variant defaults to 03_docker_single
#
#     variant  01_native_single | 02_native_cluster | 03_docker_single | 04_docker_cluster
#     action   up (default) | down | purge | status | creds
#
#   Examples:
#     bash setup.sh                              # bring the whole fleet up (Docker single-node)
#     bash setup.sh 03_docker_single             # same, explicit variant
#     bash setup.sh creds                        # print ONLY credentials + endpoints for every tool
#     bash setup.sh status                       # status of every tool
#     bash setup.sh down                          # stop everything   (DATA PRESERVED)
#     bash setup.sh purge                         # stop + DELETE data
#     bash setup.sh 01_native_single up           # native packages instead of Docker (uses sudo)
#
#   By DEFAULT Prometheus (monitoring) and OpenBao (secrets) are SKIPPED to cut load
#   (Elastic APM is kept). Run everything with UTIL_SKIP="".
#
#   Tunable environment variables:
#     UTIL_SKIP="a b"       skip tools whose name contains any token. DEFAULT "prometheus openbao".
#                           UTIL_SKIP="" runs the FULL fleet.
#     UTIL_ONLY="a b"       run ONLY tools whose name contains a token (takes precedence)
#     UTIL_SLEEP=N          seconds to pause between tool bring-ups (default 15) so a small box
#                           isn't overwhelmed by many simultaneous starts; 0 disables.
#     UTIL_FORCE=1          proceed with 04_docker_cluster even on an under-resourced host
#     UTIL_MASK_SECRETS=1   mask secret values (creds + the end-of-up report)
#     NO_COLOR=1            disable ANSI colour (also auto-disabled when not a TTY)
#
#   NOTE: the whole fleet in single-node mode is ~10 GB idle and will NOT fit a single 8 GB box.
#         For 2 vCPU / 8 GB use the two-box split (01_ on box A, 02_ on box B), or skip more tools.
#==============================================================================
set -uo pipefail   # NOT -e: one tool's failure must not kill the fleet

SERVER_LABEL="combined fleet"
BUNDLES="utility1 utility2"

DEFAULT_SKIP="prometheus openbao"
UTIL_SKIP="${UTIL_SKIP-$DEFAULT_SKIP}"
UTIL_SLEEP="${UTIL_SLEEP:-15}"; case "$UTIL_SLEEP" in ''|*[!0-9]*) UTIL_SLEEP=15;; esac

# ---- palette ----------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RST=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
  RED=$'\033[1;31m'; GRN=$'\033[32m'; YLW=$'\033[1;33m'
  BLU=$'\033[1;34m'; MAG=$'\033[1;35m'; CYN=$'\033[1;36m'
else
  RST=''; BOLD=''; DIM=''; RED=''; GRN=''; YLW=''; BLU=''; MAG=''; CYN=''
fi
RULE="$(printf '─%.0s' $(seq 1 78))"
DRULE="$(printf '═%.0s' $(seq 1 78))"

# ---- output helpers ---------------------------------------------------------
step(){ printf '\n%s==>%s %s%s%s\n' "$BLU" "$RST" "$BOLD" "$*" "$RST"; }
ok(){   printf '   %s✓%s %s\n' "$GRN" "$RST" "$*"; }
warn(){ printf '   %s!%s %s\n' "$YLW" "$RST" "$*"; }
err(){  printf '   %s✗%s %s\n' "$RED" "$RST" "$*"; }
die(){  err "$*"; exit 2; }
note(){ printf '   %s%s%s\n' "$DIM" "$*" "$RST"; }
fmt_dur(){ local s="$1"; if [ "$s" -ge 60 ]; then printf '%dm%02ds' $((s/60)) $((s%60)); else printf '%ds' "$s"; fi; }

# ---- tool filtering (UTIL_SKIP / UTIL_ONLY) ---------------------------------
lc(){ printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
token_match(){ local list tok; list="$(printf '%s' "$2" | tr ',' ' ' | tr '[:upper:]' '[:lower:]')"
  for tok in $list; do [ -n "$tok" ] && case "$1" in *"$tok"*) return 0;; esac; done; return 1; }
EXCL_REASON=""
is_excluded(){ local nm; nm="$(lc "$1")"
  if [ -n "${UTIL_ONLY:-}" ] && ! token_match "$nm" "${UTIL_ONLY}"; then EXCL_REASON="not in UTIL_ONLY"; return 0; fi
  if [ -n "${UTIL_SKIP:-}" ] &&   token_match "$nm" "${UTIL_SKIP}"; then EXCL_REASON="UTIL_SKIP";       return 0; fi
  EXCL_REASON=""; return 1; }

# ---- collapse docker image-pull spam in the per-tool frame ------------------
indent_filter(){
  local line pulling=0
  while IFS= read -r line; do
    case "$line" in
      *"Image "*" Pulling"*) pulling=0; printf '   %s│%s %s\n' "$DIM" "$RST" "$line"; continue;;
    esac
    if [[ "$line" =~ ^[[:space:]]*[0-9a-f]{12}[0-9a-f]*[[:space:]] ]]; then
      [ "$pulling" -eq 0 ] && { printf '   %s│   … downloading image layers (progress hidden)%s\n' "$DIM" "$RST"; pulling=1; }
      continue
    fi
    printf '   %s│%s %s\n' "$DIM" "$RST" "$line"
  done
}

# ---- credential formatter (the `creds` action + the end-of-up report) -------
# Reads a tool's .env and prints ONLY connection essentials: endpoints, host:port,
# user, password/token/secret/keys, UI — never image/version/data-path noise.
_ENV=""                                   # current tool's .env text (set per tool)
gv(){ printf '%s\n' "$_ENV" | awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,"");print;exit}'; }
sec(){ if [ "${UTIL_MASK_SECRETS:-0}" = 1 ] && [ -n "$1" ]; then printf '••••••••'; else printf '%s' "$1"; fi; }
row(){ [ -n "$2" ] && printf '   %-14s %s\n' "$1" "$2"; }
load_env(){ _ENV="$( { cat "$1" 2>/dev/null; } )"; [ -n "$_ENV" ] || _ENV="$($SUDO cat "$1" 2>/dev/null || true)"; [ -n "$_ENV" ]; }

tool_creds(){ # $1 = tool dir name, $2 = .env path, $3 = host
  local n="$1" H="$3"
  load_env "$2" || { printf '\n%s### %s%s  %s(no readable .env)%s\n' "$CYN" "$n" "$RST" "$DIM" "$RST"; return; }
  printf '\n%s### %s%s\n' "$CYN" "$n" "$RST"
  case "$n" in
    *PostgreSQL*) local u p pt d; u=$(gv POSTGRES_USER); p=$(gv POSTGRES_PASSWORD); pt=$(gv POSTGRES_PORT); d=$(gv POSTGRES_DB)
      row endpoint "postgresql://${u}:$(sec "$p")@${H}:${pt:-5432}/${d}"; row host:port "${H}:${pt:-5432}"; row user "$u"; row password "$(sec "$p")";;
    *Redis*) local p pt; p=$(gv REDIS_PASSWORD); pt=$(gv REDIS_PORT)
      row endpoint "redis://default:$(sec "$p")@${H}:${pt:-6379}/0"; row host:port "${H}:${pt:-6379}"; row user default; row password "$(sec "$p")";;
    *Elastic_APM*) local ep app kp es ap kp_port; ep=$(gv ELASTIC_PASSWORD); app=$(gv APM_SECRET_TOKEN); kp=$(gv KIBANA_PASSWORD)
      es=$(gv ES_HTTP_PORT); ap=$(gv APM_PORT); kp_port=$(gv KIBANA_PORT)
      row elasticsearch "http://elastic:$(sec "$ep")@${H}:${es:-9200}"; row apm-ingest "http://${H}:${ap:-8200}  (Bearer token)"
      row apm-token "$(sec "$app")"; row kibana-ui "http://${H}:${kp_port:-5601}  (login: elastic)"
      row elastic-pass "$(sec "$ep")"; row kibana_system "$(sec "$kp")";;
    *Prometheus*) local pt; pt=$(gv PROMETHEUS_PORT); row endpoint "http://${H}:${pt:-9090}"; row ui "http://${H}:${pt:-9090}"; row auth none;;
    *ClickHouse*) local u p hp tp; u=$(gv CLICKHOUSE_USER); p=$(gv CLICKHOUSE_PASSWORD); hp=$(gv CLICKHOUSE_HTTP_PORT); tp=$(gv CLICKHOUSE_TCP_PORT)
      row http "http://${H}:${hp:-8123}"; row native-tcp "${H}:${tp:-9000}"; row user "${u:-default}"; row password "$(sec "$p")"; row ui "http://${H}:${hp:-8123}/play";;
    *ScyllaDB*) local pt; pt=$(gv SCYLLA_CQL_PORT); row cql "${H}:${pt:-9042}"; row auth none;;
    *MongoDB*) local u p pt; u=$(gv MONGO_ROOT_USER); p=$(gv MONGO_ROOT_PASSWORD); pt=$(gv MONGO_PORT)
      row endpoint "mongodb://${u}:$(sec "$p")@${H}:${pt:-27017}/?authSource=admin"; row host:port "${H}:${pt:-27017}"; row user "$u"; row password "$(sec "$p")";;
    *Elasticsearch*) local p pt; p=$(gv ELASTIC_PASSWORD); pt=$(gv ES_HTTP_PORT)
      row endpoint "http://elastic:$(sec "$p")@${H}:${pt:-9201}"; row host:port "${H}:${pt:-9201}"; row user elastic; row password "$(sec "$p")";;
    *Kafka*) local bp up; bp=$(gv KAFKA_EXTERNAL_PORT); up=$(gv KAFKA_UI_PORT)
      row bootstrap "${H}:${bp:-9092}"; row ui "http://${H}:${up:-8080}"; row auth "none (PLAINTEXT)";;
    *RabbitMQ*) local u p ap mp; u=$(gv RABBITMQ_DEFAULT_USER); p=$(gv RABBITMQ_DEFAULT_PASS); ap=$(gv RABBITMQ_AMQP_PORT); mp=$(gv RABBITMQ_MGMT_PORT)
      row amqp-url "amqp://${u}:$(sec "$p")@${H}:${ap:-5672}/"; row host:port "${H}:${ap:-5672}"; row user "$u"; row password "$(sec "$p")"; row ui "http://${H}:${mp:-15672}";;
    *OpenBao*) local t k pt; t=$(gv BAO_ROOT_TOKEN); k=$(gv BAO_UNSEAL_KEY); pt=$(gv BAO_API_PORT)
      row endpoint "http://${H}:${pt:-8200}"; row ui "http://${H}:${pt:-8200}/ui"; row root-token "$(sec "$t")"; row unseal-key "$(sec "$k")";;
    *RustFS*) local ak sk ap cp; ak=$(gv RUSTFS_ACCESS_KEY); sk=$(gv RUSTFS_SECRET_KEY); ap=$(gv RUSTFS_API_PORT); cp=$(gv RUSTFS_CONSOLE_PORT)
      row s3-endpoint "http://${H}:${ap:-9002}"; row console-ui "http://${H}:${cp:-9001}"; row access-key "$ak"; row secret-key "$(sec "$sk")";;
    *Qdrant*) local k hp gp; k=$(gv QDRANT_API_KEY); hp=$(gv QDRANT_HTTP_PORT); gp=$(gv QDRANT_GRPC_PORT)
      row rest "http://${H}:${hp:-6333}"; row grpc "${H}:${gp:-6334}"; row api-key "$(sec "$k")"; row ui "http://${H}:${hp:-6333}/dashboard";;
    *Neo4j*) local u p hp bp; u=$(gv NEO4J_USER); p=$(gv NEO4J_PASSWORD); hp=$(gv NEO4J_HTTP_PORT); bp=$(gv NEO4J_BOLT_PORT)
      row bolt "bolt://${H}:${bp:-7687}"; row browser-ui "http://${H}:${hp:-7474}"; row user "${u:-neo4j}"; row password "$(sec "$p")";;
    *NATS*) local t cp mp; t=$(gv NATS_AUTH_TOKEN); cp=$(gv NATS_CLIENT_PORT); mp=$(gv NATS_MONITOR_PORT)
      row client-url "nats://$(sec "$t")@${H}:${cp:-4222}"; row host:port "${H}:${cp:-4222}"; row auth-token "$(sec "$t")"; row monitoring "http://${H}:${mp:-8222}";;
    *Temporal*) local gp up; gp=$(gv TEMPORAL_GRPC_PORT); up=$(gv TEMPORAL_UI_PORT)
      row grpc "${H}:${gp:-7233}"; row web-ui "http://${H}:${up:-8233}"; row auth none;;
    *) printf '%s' "$_ENV" | grep -iE '^[A-Z0-9_]*(USER|PASS|TOKEN|SECRET|KEY|PORT|HOST)[A-Z0-9_]*=' | grep -ivE 'IMAGE|VERSION|ENCRYPTION' | sed 's/^/   /';;
  esac
}

# ---- args (variant-first OR action-first) -----------------------------------
VALID="01_native_single 02_native_cluster 03_docker_single 04_docker_cluster"
usage(){ printf '%sUsage:%s bash %s [variant] [up|down|purge|status|creds]\n' "$BOLD" "$RST" "$(basename "$0")"
  printf '   variant : %s  (default 03_docker_single)\n' "$VALID"
  printf '   e.g.    : bash %s          bash %s creds          bash %s status\n' "$(basename "$0")" "$(basename "$0")" "$(basename "$0")"; }
A1="${1:-}"; A2="${2:-}"
if [ -z "$A1" ]; then VARIANT="03_docker_single"; ACTION="up"
else case "$A1" in
  up|down|purge|status|creds) ACTION="$A1"; VARIANT="${A2:-03_docker_single}";;
  -h|--help) usage; exit 0;;
  *) VARIANT="$A1"; ACTION="${A2:-up}";;
esac; fi
case " $VALID " in *" $VARIANT "*) ;; *) die "invalid variant '$VARIANT' (expected: $VALID)";; esac
case "$ACTION" in up|down|purge|status|creds) ;; *) die "invalid action '$ACTION' (expected: up | down | purge | status | creds)";; esac

# ---- locate the two bundles + merge tools 01..16 ----------------------------
ROOT="${UTIL_ROOT:-$(cd "$(dirname "$0")" && pwd)}"
mapfile -t TOOLS < <(
  for b in $BUNDLES; do ls -d "$ROOT/$b"/[0-9]*/ 2>/dev/null; done \
    | awk -F/ '{print $(NF-1)"\t"$0}' | sort | cut -f2-
)
[ "${#TOOLS[@]}" -gt 0 ] || die "no tools found under $ROOT/{utility1,utility2} (set UTIL_ROOT=/path)"

# ---- variant kind + verb + privilege ---------------------------------------
case "$VARIANT" in *native*) KIND=native;; *) KIND=docker;; esac
case "$KIND:$ACTION" in
  native:up)  VERB=install;;   native:down) VERB=uninstall;;
  docker:up)  VERB=up;;        docker:down) VERB=down;;
  *:purge)    VERB=purge;;     *:status)    VERB=status;;   *:creds) VERB=creds;;
esac
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

# ---- host facts -------------------------------------------------------------
HOST_NAME="$(hostname -s 2>/dev/null || hostname 2>/dev/null)"
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"; [ -n "$HOST_IP" ] || HOST_IP="127.0.0.1"
CPU_N="$(nproc 2>/dev/null || echo '?')"
MEM_KIB="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
SWAP_KIB="$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
gib(){ awk -v k="$1" 'BEGIN{printf "%.1f", k/1048576}'; }
MEM_GIB="$(gib "$MEM_KIB")"; SWAP_GIB="$(gib "$SWAP_KIB")"

# ---- creds action: print connection details for every configured tool, then exit ----
if [ "$ACTION" = creds ]; then
  printf '\n%s%s%s\n' "$YLW" "$DRULE" "$RST"
  printf '%s  DOKANDAR utilities — CREDENTIALS  (variant %s · host %s)%s\n' "$BOLD" "$VARIANT" "$HOST_IP" "$RST"
  printf '%s%s%s\n' "$YLW" "$DRULE" "$RST"
  if [ "${UTIL_MASK_SECRETS:-0}" = 1 ]; then note "secrets MASKED (UTIL_MASK_SECRETS=1) — re-run without it to reveal."
  else warn "REAL secrets below — treat this output as sensitive. (UTIL_MASK_SECRETS=1 to mask.)"; fi
  shown=0
  for tdir in "${TOOLS[@]}"; do
    tname="$(basename "$tdir")"; f="${tdir%/}/$VARIANT/.env"
    { [ -f "$f" ] || $SUDO test -f "$f" 2>/dev/null; } || continue
    tool_creds "$tname" "$f" "$HOST_IP"; shown=$((shown+1))
  done
  printf '\n%s%s%s\n' "$YLW" "$DRULE" "$RST"
  [ "$shown" -gt 0 ] || note "no tool .env found for variant '$VARIANT' — bring the fleet up first (bash $(basename "$0") $VARIANT)."
  exit 0
fi

# ---- header -----------------------------------------------------------------
printf '\n%s%s%s\n' "$MAG" "$DRULE" "$RST"
printf '%s  DOKANDAR utilities  ·  %s (utility1 + utility2) on this host%s\n' "$BOLD" "$SERVER_LABEL" "$RST"
printf '%s%s%s\n' "$MAG" "$DRULE" "$RST"
printf '   %-9s %s%s%s   %saction%s %s%s%s   %sverb%s %s   %skind%s %s\n' \
  'variant' "$BOLD" "$VARIANT" "$RST" "$DIM" "$RST" "$BOLD" "$ACTION" "$RST" "$DIM" "$RST" "$VERB" "$DIM" "$RST" "$KIND"
printf '   %-9s %s  %s(%d tools across utility1+utility2)%s\n' 'tools' "$ROOT" "$DIM" "${#TOOLS[@]}" "$RST"
printf '   %-9s %s  %s%s  ·  %s vCPU · %s GiB RAM · %s GiB swap%s\n' \
  'host' "$HOST_NAME" "$DIM" "$HOST_IP" "$CPU_N" "$MEM_GIB" "$SWAP_GIB" "$RST"
if [ -n "${UTIL_ONLY:-}" ] || [ -n "${UTIL_SKIP:-}" ]; then
  _excl=""
  for _t in "${TOOLS[@]}"; do _tn="$(basename "$_t")"; is_excluded "$_tn" && _excl="$_excl $_tn"; done
  [ -n "${UTIL_ONLY:-}" ] && printf '   %-9s only = %s%s%s\n' 'filter' "$BOLD" "$UTIL_ONLY" "$RST"
  [ -n "${UTIL_SKIP:-}" ] && printf '   %-9s skip = %s%s%s\n' 'filter' "$BOLD" "$UTIL_SKIP" "$RST"
  [ -n "$_excl" ] && printf '   %-9s %sexcluded:%s%s   %s(run all: UTIL_SKIP="")%s\n' '' "$DIM" "$_excl" "$RST" "$DIM" "$RST"
fi

# ---- preflight: runtime -----------------------------------------------------
PREFIX=""
if [ "$KIND" = docker ]; then
  command -v docker >/dev/null 2>&1 || die "docker not found — install Docker Engine first"
  docker compose version >/dev/null 2>&1 || die "the 'docker compose' plugin is not installed"
  if ! docker info >/dev/null 2>&1; then
    if [ -n "$SUDO" ] && $SUDO docker info >/dev/null 2>&1; then PREFIX="$SUDO"; warn "using sudo for docker"
    else die "cannot reach the Docker daemon (add your user to 'docker', or run with sudo)"; fi
  fi
  export COMPOSE_IGNORE_ORPHANS=true DOCKER_CLI_HINTS=false
else
  PREFIX="$SUDO"; [ -n "$SUDO" ] && { sudo -v 2>/dev/null || warn "native variant needs root; sudo will prompt"; }
  warn "native variant installs system packages (apt/systemd) directly on THIS host"
fi
[ "$VARIANT" = 02_native_cluster ] && warn "02_native_cluster is an unbuilt slot — every tool will be SKIPPED"

# ---- preflight: cluster RAM guardrail (bring-up only) -----------------------
if [ "$VARIANT" = 04_docker_cluster ] && [ "$ACTION" = up ] && [ "$MEM_KIB" -gt 0 ] && [ "$MEM_KIB" -lt $((16*1048576)) ]; then
  step "Preflight — cluster-mode RAM check"
  err  "04_docker_cluster runs 3–6 nodes PER tool; the whole ${#TOOLS[@]}-tool fleet needs far more than ~21 GB."
  err  "This host has only ${MEM_GIB} GiB RAM and ${SWAP_GIB} GiB swap — it WILL OOM."
  printf '   %sUse single-node mode instead:%s  %sbash %s 03_docker_single%s\n' "$DIM" "$RST" "$BOLD" "$(basename "$0")" "$RST"
  if [ "${UTIL_FORCE:-0}" = 1 ]; then warn "UTIL_FORCE=1 set — proceeding despite limited RAM."
  else die "refusing to OOM this host. Re-run with 03_docker_single, or UTIL_FORCE=1 to override."; fi
fi

# ---- preflight: host-port uniqueness across BOTH bundles (bring-up only) -----
if [ "$ACTION" = up ]; then
  step "Preflight — checking host-port uniqueness across utility1 + utility2"
  port_lines=""
  for tdir in "${TOOLS[@]}"; do
    tname="$(basename "$tdir")"; vdir="${tdir%/}/$VARIANT"; envf=""
    is_excluded "$tname" && continue
    [ -f "$vdir/.env" ] && envf="$vdir/.env" || envf="$vdir/.env.example"
    [ -f "$envf" ] || continue
    while IFS='=' read -r k v; do v="${v%%[[:space:]]*}"; [ -n "$v" ] && port_lines+="${v}|${tname}|${k}"$'\n'
    done < <(grep -E '^[A-Z_0-9]*PORT[A-Z_0-9]*=[0-9]+' "$envf" 2>/dev/null)
  done
  dup_report="$(printf '%s' "$port_lines" | awk -F'|' 'NF>=2{c[$1]++; who[$1]=who[$1]"  "$2"("$3")"} END{for(p in c) if(c[p]>1) printf "   port %-7s used by:%s\n", p, who[p]}')"
  if [ -n "$dup_report" ]; then
    err "host-port collision(s) — two co-located tools want the same host port:"
    printf '%s\n' "$dup_report"
    err "fix: change a *_PORT in the offending .env (or skip one tool via UTIL_SKIP)."
    die "resolve the duplicate port(s) above and re-run"
  fi
  ok "no host-port collisions"
fi

# ---- run each tool ----------------------------------------------------------
declare -a NAMES RESULTS ENVS DURS
idx=0; RUN_START=$SECONDS
for tdir in "${TOOLS[@]}"; do
  tname="$(basename "$tdir")"; vdir="${tdir%/}/$VARIANT"
  NAMES[idx]="$tname"; ENVS[idx]="$vdir/.env"; DURS[idx]=0

  if is_excluded "$tname"; then
    printf '\n   %s▸ [%d/%d] %s — skipped (%s)%s\n' "$DIM" "$((idx+1))" "${#TOOLS[@]}" "$tname" "$EXCL_REASON" "$RST"
    RESULTS[idx]="SKIP ($EXCL_REASON)"; idx=$((idx+1)); continue
  fi

  printf '\n%s%s%s\n' "$CYN" "$RULE" "$RST"
  printf '%s ▸ [%d/%d] %s%s   %s· %s %s%s\n' "$CYN" "$((idx+1))" "${#TOOLS[@]}" "$tname" "$RST" "$DIM" "$VARIANT" "$ACTION" "$RST"

  if [ ! -d "$vdir" ];          then warn "no '$VARIANT' variant for $tname — skipped";         RESULTS[idx]="SKIP (no variant)";  idx=$((idx+1)); continue; fi
  if [ ! -f "$vdir/setup.sh" ]; then warn "no setup.sh in $tname/$VARIANT (unbuilt) — skipped"; RESULTS[idx]="SKIP (no setup.sh)"; idx=$((idx+1)); continue; fi
  if [ "$ACTION" = up ] && [ ! -f "$vdir/.env" ]; then
    if [ -f "$vdir/.env.example" ]; then cp "$vdir/.env.example" "$vdir/.env"; ok ".env seeded from .env.example"
    else warn "no .env.example to seed .env — setup.sh may refuse to start"; fi
  fi

  t0=$SECONDS
  $PREFIX bash "$vdir/setup.sh" "$VERB" 2>&1 | indent_filter
  rc=${PIPESTATUS[0]}
  el=$((SECONDS - t0)); DURS[idx]=$el

  if [ "$rc" -eq 0 ]; then
    printf '   %s✓ %s OK%s   %s· %s%s\n' "$GRN" "$tname" "$RST" "$DIM" "$(fmt_dur "$el")" "$RST"; RESULTS[idx]="OK"
  else
    printf '   %s✗ %s FAILED (rc=%s)%s   %s· %s%s\n' "$RED" "$tname" "$rc" "$RST" "$DIM" "$(fmt_dur "$el")" "$RST"
    printf '   %s  ↳ inspect: bash %s/%s/setup.sh status   (or: ... logs)%s\n' "$DIM" "${tdir%/}" "$VARIANT" "$RST"
    RESULTS[idx]="FAILED (rc=$rc)"
  fi
  if [ "$ACTION" = up ] && [ "$UTIL_SLEEP" -gt 0 ] && [ $((idx+1)) -lt "${#TOOLS[@]}" ]; then
    printf '   %s… cooling down %ss before the next tool (UTIL_SLEEP=%s; set 0 to disable)%s\n' "$DIM" "$UTIL_SLEEP" "$UTIL_SLEEP" "$RST"
    sleep "$UTIL_SLEEP"
  fi
  idx=$((idx+1))
done
RUN_EL=$((SECONDS - RUN_START))

# ---- result summary ---------------------------------------------------------
n_ok=0; n_fail=0; n_skip=0
for j in "${!RESULTS[@]}"; do case "${RESULTS[j]}" in OK) n_ok=$((n_ok+1));; FAILED*) n_fail=$((n_fail+1));; SKIP*) n_skip=$((n_skip+1));; esac; done
printf '\n%s%s%s\n' "$MAG" "$DRULE" "$RST"
printf '%s  %s — summary  ·  %s %s%s\n' "$BOLD" "$SERVER_LABEL" "$VARIANT" "$ACTION" "$RST"
printf '%s%s%s\n' "$MAG" "$DRULE" "$RST"
for j in "${!NAMES[@]}"; do
  case "${RESULTS[j]}" in OK) mark="$GRN✓$RST";; FAILED*) mark="$RED✗$RST";; *) mark="$YLW•$RST";; esac
  printf '   %b  %-16s %-20s %s%s%s\n' "$mark" "${NAMES[j]}" "${RESULTS[j]}" "$DIM" "$(fmt_dur "${DURS[j]}")" "$RST"
done
printf '   %s\n' "$RULE"
printf '   %s%d OK%s · %s%d FAILED%s · %s%d skipped%s   %s·  %d tools  ·  total %s%s\n' \
  "$GRN" "$n_ok" "$RST" "$RED" "$n_fail" "$RST" "$YLW" "$n_skip" "$RST" "$DIM" "${#NAMES[@]}" "$(fmt_dur "$RUN_EL")" "$RST"

# ---- credentials (bring-up only) — clean per-tool blocks --------------------
if [ "$ACTION" = up ]; then
  printf '\n%s%s%s\n' "$YLW" "$DRULE" "$RST"
  printf '%s  CREDENTIALS  (also: bash %s creds)%s\n' "$BOLD" "$(basename "$0")" "$RST"
  printf '%s%s%s\n' "$YLW" "$DRULE" "$RST"
  if [ "${UTIL_MASK_SECRETS:-0}" = 1 ]; then note "secrets MASKED (UTIL_MASK_SECRETS=1)."
  else warn "REAL secrets below — treat as sensitive. (UTIL_MASK_SECRETS=1 to mask.)"; fi
  for j in "${!NAMES[@]}"; do [ "${RESULTS[j]}" = OK ] || continue; tool_creds "${NAMES[j]}" "${ENVS[j]}" "$HOST_IP"; done
  printf '\n%s%s%s\n' "$YLW" "$DRULE" "$RST"
  printf '\n%sNext steps%s\n' "$BOLD" "$RST"
  printf '   credentials only        : %sbash %s creds%s\n' "$BOLD" "$(basename "$0")" "$RST"
  printf '   status of everything    : %sbash %s status%s\n' "$BOLD" "$(basename "$0")" "$RST"
  printf '   stop (keep data)        : %sbash %s down%s\n' "$BOLD" "$(basename "$0")" "$RST"
  printf '   stop + DELETE data      : %sbash %s purge%s\n' "$BOLD" "$(basename "$0")" "$RST"
fi

[ "$n_fail" -gt 0 ] && exit 1
exit 0
