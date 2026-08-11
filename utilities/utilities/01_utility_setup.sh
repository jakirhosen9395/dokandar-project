#!/usr/bin/env bash
#==============================================================================
# DOKANDAR utilities — SERVER A (utility1) fleet orchestrator
#------------------------------------------------------------------------------
# Brings up EVERY Server-A tool in one chosen install variant, then prints a
# single CONSOLIDATED CREDENTIALS report. Each tool's own setup.sh auto-generates
# its password/token/key (empty in .env.example) and saves it to its .env (0600);
# this wrapper just drives them in order and re-collects the secrets at the end.
#
#   Usage:   bash 01_utility_setup.sh <variant> [action]
#
#     <variant>  01_native_single | 02_native_cluster | 03_docker_single | 04_docker_cluster
#     [action]   up (default) | down | purge | status
#
#   Examples:
#     bash 01_utility_setup.sh 03_docker_single          # bring the fleet up (Docker, single-node)  <-- recommended
#     bash 01_utility_setup.sh 01_native_single          # bring the fleet up (native pkgs, uses sudo)
#     bash 01_utility_setup.sh 03_docker_single status   # show each tool's status
#     bash 01_utility_setup.sh 03_docker_single down      # stop containers   (DATA PRESERVED)
#     bash 01_utility_setup.sh 03_docker_single purge     # stop + DELETE data
#
#   Server A tools: PostgreSQL · Redis · Elastic APM · Prometheus · ClickHouse · ScyllaDB
#   (OpenBao was moved to Server B (02_utility_setup.sh) — its default port 8200 clashed with Elastic APM here.)
#
#   Notes:
#     * By DEFAULT Prometheus (monitoring) and OpenBao (secrets) are SKIPPED to cut load
#       (Elastic APM is kept; see UTIL_SKIP). Run everything with UTIL_SKIP="".
#     * One tool failing does NOT abort the rest — you get a result table at the end.
#     * 02_native_cluster is an unbuilt slot (no setup.sh) and is skipped automatically.
#     * A port-uniqueness PREFLIGHT runs before bring-up so colliding host ports
#       fail fast with a clear message instead of a cryptic mid-run Docker error.
#     * A RAM PREFLIGHT guards 04_docker_cluster: the full fleet needs ~21 GB in
#       cluster mode and will OOM an 8 GB box. Use 03_docker_single, or set
#       UTIL_FORCE=1 to override (see "Tunable environment variables" below).
#     * Bundle is auto-located: $UTIL_BUNDLE, else ./utility1, else this dir itself.
#
#   Tunable environment variables:
#     UTIL_BUNDLE=/path     point at a tool bundle in a non-default location
#     UTIL_SKIP="a b"       skip tools whose name contains any token. DEFAULT skips
#                           monitoring + secrets ("prometheus openbao"); Elastic APM is
#                           kept. Set UTIL_SKIP="" to run the FULL fleet.
#     UTIL_ONLY="a b"       run ONLY tools whose name contains a token (takes precedence)
#     UTIL_SLEEP=N          seconds to pause between tool bring-ups (default 15) so a small box
#                           isn't overwhelmed by many simultaneous starts; 0 disables.
#     UTIL_FORCE=1          proceed with 04_docker_cluster even on an under-resourced host
#     UTIL_MASK_SECRETS=1   mask secret values in the CONSOLIDATED CREDENTIALS block
#     NO_COLOR=1            disable ANSI colour (also auto-disabled when not a TTY)
#==============================================================================
set -uo pipefail   # deliberately NOT -e: a single tool's failure must not kill the fleet

BUNDLE_NAME="utility1"
SERVER_LABEL="Server A"

# Tools SKIPPED BY DEFAULT: monitoring (Prometheus) plus secrets (OpenBao).
# Elastic APM is KEPT — it is the application's tracing/observability backend.
# These are substring tokens; only the ones present in THIS bundle take effect, so
# the same list is correct for both servers. Every lifecycle command (up/down/
# purge/status) still works on the remaining tools — only the TOOLS are filtered.
#   UTIL_SKIP="" bash 01_utility_setup.sh 03_docker_single   # run the FULL fleet (skip nothing)
#   UTIL_SKIP="prometheus openbao neo4j" ...                 # skip a different set instead
DEFAULT_SKIP="prometheus openbao"
UTIL_SKIP="${UTIL_SKIP-$DEFAULT_SKIP}"   # unset → default; set (even to "") → honored verbatim

# Seconds to pause between tool bring-ups so a small box isn't hit by many simultaneous
# container/JVM starts (eases CPU/RAM pressure). 0 disables. Bring-up (up/install) only.
UTIL_SLEEP="${UTIL_SLEEP:-15}"; case "$UTIL_SLEEP" in ''|*[!0-9]*) UTIL_SLEEP=15;; esac

# ---- palette (honours NO_COLOR and non-TTY) ---------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RST=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
  RED=$'\033[1;31m'; GRN=$'\033[32m'; YLW=$'\033[1;33m'
  BLU=$'\033[1;34m'; MAG=$'\033[1;35m'; CYN=$'\033[1;36m'
else
  RST=''; BOLD=''; DIM=''; RED=''; GRN=''; YLW=''; BLU=''; MAG=''; CYN=''
fi
RULE="$(printf '─%.0s' $(seq 1 78))"     # light rule
DRULE="$(printf '═%.0s' $(seq 1 78))"    # heavy rule

# ---- output helpers ---------------------------------------------------------
step(){ printf '\n%s==>%s %s%s%s\n' "$BLU" "$RST" "$BOLD" "$*" "$RST"; }
ok(){   printf '   %s✓%s %s\n' "$GRN" "$RST" "$*"; }
warn(){ printf '   %s!%s %s\n' "$YLW" "$RST" "$*"; }
err(){  printf '   %s✗%s %s\n' "$RED" "$RST" "$*"; }
die(){  err "$*"; exit 2; }
note(){ printf '   %s%s%s\n' "$DIM" "$*" "$RST"; }
fmt_dur(){ local s="$1"; if [ "$s" -ge 60 ]; then printf '%dm%02ds' $((s/60)) $((s%60)); else printf '%ds' "$s"; fi; }

# Stream a child tool's output indented under the per-tool frame, but COLLAPSE the
# noisy `docker compose` image-pull progress: drop every per-layer line (a 12+ hex
# layer id followed by Downloading/Extracting/Pull complete/…) and replace each pull
# burst with a single "downloading layers" note. Image-, network- and container-level
# lines are kept, so you still see what was pulled and which containers started.
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

# ---- tool filtering (UTIL_SKIP / UTIL_ONLY) ---------------------------------
# Case-insensitive substring match against the tool's dir name, so any of
# "07_Elastic_APM", "elastic_apm", "apm", or "07" all select that tool. Tokens
# are space- or comma-separated. Useful to drop the observability/monitoring
# stack (Elastic APM, Prometheus) and secrets (OpenBao) to cut load:
#     UTIL_SKIP="elastic_apm prometheus openbao" bash 01_utility_setup.sh 03_docker_single
lc(){ printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
token_match(){ # $1 = lowercased tool name, $2 = token list ; 0 if any token is a substring
  local list tok; list="$(printf '%s' "$2" | tr ',' ' ' | tr '[:upper:]' '[:lower:]')"
  for tok in $list; do [ -n "$tok" ] && case "$1" in *"$tok"*) return 0;; esac; done; return 1; }
EXCL_REASON=""
is_excluded(){ # $1 = tool dir name ; sets EXCL_REASON, returns 0 when the tool must be skipped
  local nm; nm="$(lc "$1")"
  if [ -n "${UTIL_ONLY:-}" ] && ! token_match "$nm" "${UTIL_ONLY}"; then EXCL_REASON="not in UTIL_ONLY"; return 0; fi
  if [ -n "${UTIL_SKIP:-}" ] &&   token_match "$nm" "${UTIL_SKIP}"; then EXCL_REASON="UTIL_SKIP";       return 0; fi
  EXCL_REASON=""; return 1; }

# ---- args -------------------------------------------------------------------
VALID="01_native_single 02_native_cluster 03_docker_single 04_docker_cluster"
VARIANT="${1:-}"; ACTION="${2:-up}"
if [ -z "$VARIANT" ]; then
  printf '%sUsage:%s bash %s <variant> [up|down|purge|status]\n' "$BOLD" "$RST" "$(basename "$0")"
  printf '   variant : %s\n' "$VALID"
  printf '   tip     : on a 2 vCPU / 8 GB box use %s03_docker_single%s (the fleet fits ~5 GB).\n' "$BOLD" "$RST"
  exit 2
fi
case " $VALID " in *" $VARIANT "*) ;; *) die "invalid variant '$VARIANT' (expected: $VALID)";; esac
case "$ACTION" in up|down|purge|status) ;; *) die "invalid action '$ACTION' (expected: up | down | purge | status)";; esac

# ---- locate the tool bundle (beside this script, inside it, or via $UTIL_BUNDLE) ----
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if   [ -n "${UTIL_BUNDLE:-}" ];                   then BUNDLE_DIR="$UTIL_BUNDLE"
elif [ -d "$SCRIPT_DIR/$BUNDLE_NAME" ];           then BUNDLE_DIR="$SCRIPT_DIR/$BUNDLE_NAME"
elif ls -d "$SCRIPT_DIR"/[0-9]*/ >/dev/null 2>&1; then BUNDLE_DIR="$SCRIPT_DIR"
else die "cannot find the '$BUNDLE_NAME' tool bundle near $SCRIPT_DIR (set UTIL_BUNDLE=/path)"; fi

mapfile -t TOOLS < <(ls -d "$BUNDLE_DIR"/[0-9]*/ 2>/dev/null | sort)
[ "${#TOOLS[@]}" -gt 0 ] || die "no numbered tool directories found under $BUNDLE_DIR"

# ---- variant kind + verb + privilege ---------------------------------------
case "$VARIANT" in *native*) KIND=native;; *) KIND=docker;; esac
case "$KIND:$ACTION" in
  native:up)  VERB=install;;   native:down) VERB=uninstall;;
  docker:up)  VERB=up;;        docker:down) VERB=down;;
  *:purge)    VERB=purge;;     *:status)    VERB=status;;
esac
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

# ---- host facts (for the header + RAM guardrail) ----------------------------
HOST_NAME="$(hostname -s 2>/dev/null || echo "$(hostname 2>/dev/null)")"
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"; [ -n "$HOST_IP" ] || HOST_IP="?"
CPU_N="$(nproc 2>/dev/null || echo '?')"
MEM_KIB="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
SWAP_KIB="$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
gib(){ awk -v k="$1" 'BEGIN{printf "%.1f", k/1048576}'; }
MEM_GIB="$(gib "$MEM_KIB")"; SWAP_GIB="$(gib "$SWAP_KIB")"

# ---- header -----------------------------------------------------------------
printf '\n%s%s%s\n' "$MAG" "$DRULE" "$RST"
printf '%s  DOKANDAR utilities  ·  %s fleet bring-up%s\n' "$BOLD" "$SERVER_LABEL" "$RST"
printf '%s%s%s\n' "$MAG" "$DRULE" "$RST"
printf '   %-9s %s%s%s   %saction%s %s%s%s   %sverb%s %s   %skind%s %s\n' \
  'variant' "$BOLD" "$VARIANT" "$RST" "$DIM" "$RST" "$BOLD" "$ACTION" "$RST" "$DIM" "$RST" "$VERB" "$DIM" "$RST" "$KIND"
printf '   %-9s %s  %s(%d tools)%s\n' 'bundle' "$BUNDLE_DIR" "$DIM" "${#TOOLS[@]}" "$RST"
printf '   %-9s %s  %s%s  ·  %s vCPU · %s GiB RAM · %s GiB swap%s\n' \
  'host' "$HOST_NAME" "$DIM" "$HOST_IP" "$CPU_N" "$MEM_GIB" "$SWAP_GIB" "$RST"
# active tool filter (UTIL_SKIP / UTIL_ONLY)
if [ -n "${UTIL_ONLY:-}" ] || [ -n "${UTIL_SKIP:-}" ]; then
  _excl=""
  for _t in "${TOOLS[@]}"; do _tn="$(basename "$_t")"; is_excluded "$_tn" && _excl="$_excl $_tn"; done
  [ -n "${UTIL_ONLY:-}" ] && printf '   %-9s only = %s%s%s\n' 'filter' "$BOLD" "$UTIL_ONLY" "$RST"
  [ -n "${UTIL_SKIP:-}" ] && printf '   %-9s skip = %s%s%s\n' 'filter' "$BOLD" "$UTIL_SKIP" "$RST"
  if [ -n "$_excl" ]; then printf '   %-9s %sexcluded:%s%s   %s(run all: UTIL_SKIP="")%s\n' '' "$DIM" "$_excl" "$RST" "$DIM" "$RST"
  else                     printf '   %-9s %s(filter matches no tool in this bundle)%s\n' '' "$DIM" "$RST"; fi
fi

# ---- preflight: runtime availability ---------------------------------------
PREFIX=""    # command prefix used to invoke each tool's setup.sh
if [ "$KIND" = docker ]; then
  command -v docker >/dev/null 2>&1 || die "docker not found — install Docker Engine first"
  docker compose version >/dev/null 2>&1 || die "the 'docker compose' plugin is not installed"
  if ! docker info >/dev/null 2>&1; then
    if [ -n "$SUDO" ] && $SUDO docker info >/dev/null 2>&1; then
      PREFIX="$SUDO"; warn "current user can't reach the Docker daemon — using sudo for docker"
    else
      die "cannot reach the Docker daemon (add your user to the 'docker' group, or run with sudo)"
    fi
  fi
  # Quieter, cleaner child output: silence cross-tool "orphan container" warnings
  # (every tool's compose shares the '$VARIANT' project name) and docker's CLI hints.
  export COMPOSE_IGNORE_ORPHANS=true DOCKER_CLI_HINTS=false
else
  PREFIX="$SUDO"   # native installers call apt/systemctl directly → need root
  [ -n "$SUDO" ] && { sudo -v 2>/dev/null || warn "native variant needs root; sudo will prompt"; }
  warn "native variant installs system packages (apt/systemd) directly on THIS host"
fi
[ "$VARIANT" = 02_native_cluster ] && warn "02_native_cluster is an unbuilt slot — every tool will be SKIPPED"

# ---- preflight: RAM guardrail for cluster mode (bring-up only) --------------
# The full fleet in 04_docker_cluster needs ~21 GB. On a small box it OOM-locks
# (an unresponsive host, half-formed clusters). Gate it unless UTIL_FORCE=1.
if [ "$VARIANT" = 04_docker_cluster ] && [ "$ACTION" = up ] && [ "$MEM_KIB" -gt 0 ] \
   && [ "$MEM_KIB" -lt $((16*1048576)) ]; then
  step "Preflight — cluster-mode RAM check"
  err  "04_docker_cluster runs 3–6 nodes PER tool; the whole ${#TOOLS[@]}-tool bundle needs ~21 GB."
  err  "This host has only ${MEM_GIB} GiB RAM and ${SWAP_GIB} GiB swap — the fleet will almost certainly OOM."
  printf '   %sFor a 2 vCPU / 8 GB box use single-node mode (fits ~5 GB, already load-balanced):%s\n' "$DIM" "$RST"
  printf '       %sbash %s 03_docker_single%s\n' "$BOLD" "$(basename "$0")" "$RST"
  printf '   %sTo exercise a single tool in cluster mode, run just that tool on a bigger box:%s\n' "$DIM" "$RST"
  printf '       %scd %s/<tool>/04_docker_cluster && bash setup.sh up%s\n' "$BOLD" "$BUNDLE_NAME" "$RST"
  if [ "${UTIL_FORCE:-0}" = 1 ]; then
    warn "UTIL_FORCE=1 set — proceeding in cluster mode despite limited RAM (you have been warned)."
  else
    die "refusing to OOM this host. Re-run with 03_docker_single, or UTIL_FORCE=1 to override."
  fi
fi

# ---- preflight: host-port uniqueness (bring-up only) ------------------------
# Reads each tool's *PORT* vars from its .env (if present) or .env.example and
# aborts if two tools would publish the SAME host port on this single machine.
if [ "$ACTION" = up ]; then
  step "Preflight — checking host-port uniqueness across the bundle"
  port_lines=""
  for tdir in "${TOOLS[@]}"; do
    tname="$(basename "$tdir")"; vdir="${tdir%/}/$VARIANT"; envf=""
    is_excluded "$tname" && continue   # a filtered-out tool publishes no ports
    [ -f "$vdir/.env" ] && envf="$vdir/.env" || envf="$vdir/.env.example"
    [ -f "$envf" ] || continue
    while IFS='=' read -r k v; do
      v="${v%%[[:space:]]*}"
      [ -n "$v" ] && port_lines+="${v}|${tname}|${k}"$'\n'
    done < <(grep -E '^[A-Z_0-9]*PORT[A-Z_0-9]*=[0-9]+' "$envf" 2>/dev/null)
  done
  dup_report="$(printf '%s' "$port_lines" | awk -F'|' 'NF>=2{c[$1]++; who[$1]=who[$1]"  "$2"("$3")"} END{for(p in c) if(c[p]>1) printf "   port %-7s used by:%s\n", p, who[p]}')"
  if [ -n "$dup_report" ]; then
    err "host-port collision(s) — these tools cannot share one machine until you edit the offending .env"
    err "(per policy: move one of the clashing tools to the OTHER server, or change its *_PORT):"
    printf '%s\n' "$dup_report"
    die "fix the duplicate port(s) above and re-run"
  fi
  ok "no host-port collisions"
fi

# ---- run each tool ----------------------------------------------------------
# Each tool's setup.sh output is streamed live, indented under a per-tool banner.
# Piping makes the child non-TTY, so 'docker compose' prints clean plain progress
# (one line per container) instead of the redrawing animated bars.
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

  if [ ! -d "$vdir" ];          then warn "no '$VARIANT' variant for $tname — skipped";          RESULTS[idx]="SKIP (no variant)";   idx=$((idx+1)); continue; fi
  if [ ! -f "$vdir/setup.sh" ]; then warn "no setup.sh in $tname/$VARIANT (unbuilt) — skipped";  RESULTS[idx]="SKIP (no setup.sh)";  idx=$((idx+1)); continue; fi
  # bring-up needs a .env; seed it from the committed template if absent (creds auto-generate on first run)
  if [ "$ACTION" = up ] && [ ! -f "$vdir/.env" ]; then
    if [ -f "$vdir/.env.example" ]; then cp "$vdir/.env.example" "$vdir/.env"; ok ".env seeded from .env.example"
    else warn "no .env.example to seed .env — setup.sh may refuse to start"; fi
  fi

  t0=$SECONDS
  $PREFIX bash "$vdir/setup.sh" "$VERB" 2>&1 | indent_filter
  rc=${PIPESTATUS[0]}
  el=$((SECONDS - t0)); DURS[idx]=$el

  if [ "$rc" -eq 0 ]; then
    printf '   %s✓ %s OK%s   %s· %s%s\n' "$GRN" "$tname" "$RST" "$DIM" "$(fmt_dur "$el")" "$RST"
    RESULTS[idx]="OK"
  else
    printf '   %s✗ %s FAILED (rc=%s)%s   %s· %s%s\n' "$RED" "$tname" "$rc" "$RST" "$DIM" "$(fmt_dur "$el")" "$RST"
    printf '   %s  ↳ inspect: bash %s/%s/%s/setup.sh status   (or: ... logs)%s\n' "$DIM" "$BUNDLE_NAME" "$tname" "$VARIANT" "$RST"
    RESULTS[idx]="FAILED (rc=$rc)"
  fi
  # cooldown: let this tool settle before starting the next, so a small box isn't
  # hit by many simultaneous container/JVM starts (bring-up only; skip after the last tool)
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
  case "${RESULTS[j]}" in
    OK)      mark="$GRN✓$RST";;
    FAILED*) mark="$RED✗$RST";;
    *)       mark="$YLW•$RST";;
  esac
  printf '   %b  %-16s %-20s %s%s%s\n' "$mark" "${NAMES[j]}" "${RESULTS[j]}" "$DIM" "$(fmt_dur "${DURS[j]}")" "$RST"
done
printf '   %s\n' "$RULE"
printf '   %s%d OK%s · %s%d FAILED%s · %s%d skipped%s   %s·  %d tools  ·  total %s%s\n' \
  "$GRN" "$n_ok" "$RST" "$RED" "$n_fail" "$RST" "$YLW" "$n_skip" "$RST" "$DIM" "${#NAMES[@]}" "$(fmt_dur "$RUN_EL")" "$RST"

# ---- consolidated credentials (bring-up only) -------------------------------
if [ "$ACTION" = up ]; then
  printf '\n%s%s%s\n' "$YLW" "$DRULE" "$RST"
  printf '%s  %s — CONSOLIDATED CREDENTIALS%s\n' "$BOLD" "$SERVER_LABEL" "$RST"
  printf '%s%s%s\n' "$YLW" "$DRULE" "$RST"
  if [ "${UTIL_MASK_SECRETS:-0}" = 1 ]; then
    note "secret values are MASKED (UTIL_MASK_SECRETS=1). Read them in each tool's .env, or re-run without it."
  else
    warn "REAL secrets below (auto-generated, chmod 600 in each tool's .env). Treat this output as sensitive."
    note "tip: set UTIL_MASK_SECRETS=1 to hide secret values here."
  fi
  for j in "${!NAMES[@]}"; do
    [ "${RESULTS[j]}" = "OK" ] || continue
    f="${ENVS[j]}"
    printf '\n%s### %s%s   %s%s%s\n' "$CYN" "${NAMES[j]}" "$RST" "$DIM" "$f" "$RST"
    # read non-comment KEY=VALUE lines (via sudo if the .env isn't world-readable)
    if [ -r "$f" ]; then content="$(grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null)"
    else content="$($SUDO cat "$f" 2>/dev/null | grep -vE '^[[:space:]]*(#|$)')"; fi
    if [ -z "$content" ]; then note "(could not read $f — try: sudo cat '$f')"; continue; fi
    # align on '=' and optionally mask secret-looking keys
    printf '%s' "$content" | awk -v mask="${UTIL_MASK_SECRETS:-0}" '
      { i=index($0,"="); if(i==0){print "     " $0; next}
        k=substr($0,1,i-1); v=substr($0,i+1)
        if(length(k)>w) w=length(k); K[NR]=k; V[NR]=v }
      END{ for(n=1;n<=NR;n++){ kk=K[n]; vv=V[n]
            if(mask=="1" && kk ~ /(PASS|PASSWORD|TOKEN|SECRET|KEY|UNSEAL)/) vv="••••••••  (masked)"
            printf "     %-*s = %s\n", w, kk, vv } }'
  done
  printf '\n%s%s%s\n' "$YLW" "$DRULE" "$RST"
  printf '\n%sNext steps%s\n' "$BOLD" "$RST"
  printf '   re-print connection details for one tool : %sbash %s/<tool>/%s/setup.sh status%s\n' "$BOLD" "$BUNDLE_NAME" "$VARIANT" "$RST"
  printf '   re-print this whole report             : %sbash %s %s status%s\n' "$BOLD" "$(basename "$0")" "$VARIANT" "$RST"
  printf '   stop the fleet (keep data)             : %sbash %s %s down%s\n' "$BOLD" "$(basename "$0")" "$VARIANT" "$RST"
  printf '   stop + DELETE data                     : %sbash %s %s purge%s\n' "$BOLD" "$(basename "$0")" "$VARIANT" "$RST"
fi

# ---- exit non-zero if anything failed ---------------------------------------
[ "$n_fail" -gt 0 ] && exit 1
exit 0
