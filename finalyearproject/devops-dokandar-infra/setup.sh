#!/usr/bin/env bash
#==============================================================================
# devops-dokandar-infra — FLEET ORCHESTRATOR (one script, whole fleet, zero conflicts)
#------------------------------------------------------------------------------
# Drives the ENTIRE 2-server utility fleet (or a single box carrying everything)
# from ONE command on your laptop. For remote targets it SSHes into the server,
# syncs this folder there if missing, and re-invokes itself; `all` fans out to
# every server and prints ONE combined, copy-paste-from-anywhere CREDENTIALS
# report. Every utility uses a FIXED CANONICAL HOST PORT (see the map below) so
# nothing ever collides — co-hosted on one box or split across servers.
#
#   Usage:   bash setup.sh [target] [variant] [action] [--flags]
#            (positional tokens are recognised by WHAT they are — any order)
#
#     target   all (default) | infra1 | infra2 | local | <utility-name>
#     variant  docker-single-node-setup (default; other variants come later)
#     action   up (default) | down (stop, KEEP data) | purge (stop + DELETE data)
#              status | creds | restart | logs | test
#
#   Examples:
#     bash setup.sh                       # all servers, everything up
#     bash setup.sh infra1 up             # only the observability/messaging box
#     bash setup.sh all creds             # ONE combined fleet credential sheet
#     bash setup.sh postgresql status     # one utility, auto-routed to its server
#     bash setup.sh infra2 test           # run test.sh for every datastore tool
#     bash setup.sh kafka logs            # recent logs of one utility
#     bash setup.sh all down              # stop the whole fleet (data kept)
#
#   Long flags: --host H  --only "a b"  --skip "a b"  --sleep N  --mask  --force
#               --no-color  --public-host H  --key PATH  --no-pull  -h/--help
#
#   Tunable environment variables (flags override them):
#     INFRA1_HOST / INFRA2_HOST   the server IPs (dynamic — edit here or export)
#     SSH_KEY / SSH_USER          how to reach the servers
#     UTIL_SLEEP=5                cooldown seconds before booting each utility
#     UTIL_ONLY / UTIL_SKIP       include-only / exclude tool name tokens
#     UTIL_MASK_SECRETS=1         mask secrets in credential output
#     UTIL_FORCE=1                override the RAM guardrail
#     UTIL_NO_PULL=1              skip the pull-all-images-first phase
#     PUBLIC_HOST=IP              force the IP printed in credential endpoints
#     NO_COLOR=1                  disable ANSI colour
#==============================================================================
set -uo pipefail   # NOT -e: one utility failing must NOT kill the fleet

#==============================================================================
# FLEET HOST MAP — public IPs are DYNAMIC (no Elastic IP): edit these two lines
# (or export INFRA1_HOST/INFRA2_HOST) whenever the servers get new IPs.
#
#   SINGLE-MACHINE MODE (current): both point at the SAME box — the canonical
#   port map guarantees all 13 utilities co-exist with zero collisions.
#   TWO-SERVER SPLIT (former layout): infra1=52.77.240.60 infra2=13.250.6.47.
#==============================================================================
INFRA1_HOST="${INFRA1_HOST:-52.77.234.48}"     # observability + messaging box
INFRA2_HOST="${INFRA2_HOST:-52.77.234.48}"     # datastores box
INFRA1_TOOLS="elastic-apm-stack kafka schema-registry rabbitmq redis"
INFRA2_TOOLS="postgresql timescaledb mongodb opensearch clickhouse neo4j rustfs scylladb"
SSH_KEY="${SSH_KEY:-/home/jakir/final-year-project/test.pem}"
SSH_USER="${SSH_USER:-ubuntu}"
REMOTE_DIR="${REMOTE_DIR:-devops-dokandar-infra}"   # under \$HOME on each server

#==============================================================================
# CANONICAL HOST-PORT MAP — the no-conflict guarantee. Every utility's .env
# defaults to exactly these host ports; the preflight FAILS LOUDLY if any live
# .env diverges. Container-internal ports stay default — only the published
# host port is fixed here.
#   moved ports: timescaledb 5433 (postgres keeps 5432) · schema-registry 8081
#   (kafka-ui keeps 8080) · clickhouse native 9004 (rustfs keeps 9000) ·
#   opensearch 9201 (elastic-apm ES keeps 9200).
#   reserved, not published: ES transport 9300 · opensearch transport 9301 ·
#   scylla monitoring 9180 (single-node teaching setups don't expose them, but
#   no other utility may claim those ports).
#==============================================================================
CANON="
postgresql:POSTGRES_PORT:5432
timescaledb:TSDB_PORT:5433
redis:REDIS_PORT:6379
mongodb:MONGO_PORT:27017
kafka:KAFKA_EXTERNAL_PORT:9092
kafka:KAFKA_UI_PORT:8080
schema-registry:APICURIO_PORT:8081
rabbitmq:RABBITMQ_AMQP_PORT:5672
rabbitmq:RABBITMQ_MGMT_PORT:15672
clickhouse:CLICKHOUSE_HTTP_PORT:8123
clickhouse:CLICKHOUSE_TCP_PORT:9004
neo4j:NEO4J_HTTP_PORT:7474
neo4j:NEO4J_BOLT_PORT:7687
opensearch:OPENSEARCH_PORT:9201
elastic-apm-stack:ES_PORT:9200
elastic-apm-stack:KIBANA_PORT:5601
elastic-apm-stack:APM_PORT:8200
rustfs:RUSTFS_API_PORT:9000
rustfs:RUSTFS_CONSOLE_PORT:9001
scylladb:SCYLLA_CQL_PORT:9042
"

UTIL_SLEEP="${UTIL_SLEEP:-5}"; case "$UTIL_SLEEP" in ''|*[!0-9]*) UTIL_SLEEP=5;; esac
UTIL_MASK_SECRETS="${UTIL_MASK_SECRETS:-0}"
UTIL_FORCE="${UTIL_FORCE:-0}"
UTIL_NO_PULL="${UTIL_NO_PULL:-0}"
SERVER_LABEL="${SERVER_LABEL:-}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
ALL_TOOLS="$INFRA1_TOOLS $INFRA2_TOOLS"

# ---- palette -----------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RST=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
  RED=$'\033[1;31m'; GRN=$'\033[32m'; YLW=$'\033[1;33m'
  BLU=$'\033[1;34m'; MAG=$'\033[1;35m'; CYN=$'\033[1;36m'
else
  RST=''; BOLD=''; DIM=''; RED=''; GRN=''; YLW=''; BLU=''; MAG=''; CYN=''
fi
RULE="$(printf '─%.0s' $(seq 1 78))"
DRULE="$(printf '═%.0s' $(seq 1 78))"

step(){ printf '\n%s==>%s %s%s%s\n' "$BLU" "$RST" "$BOLD" "$*" "$RST"; }
ok(){   printf '   %s✓%s %s\n' "$GRN" "$RST" "$*"; }
warn(){ printf '   %s!%s %s\n' "$YLW" "$RST" "$*"; }
err(){  printf '   %s✗%s %s\n' "$RED" "$RST" "$*"; }
die(){  err "$*"; exit 2; }
note(){ printf '   %s%s%s\n' "$DIM" "$*" "$RST"; }
fmt_dur(){ local s="$1"; if [ "$s" -ge 60 ]; then printf '%dm%02ds' $((s/60)) $((s%60)); else printf '%ds' "$s"; fi; }

# collapse docker image-pull layer spam into a single line inside tool frames
indent_filter(){
  local line pulling=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*[0-9a-f]{12,}[[:space:]] ]] || [[ "$line" =~ (Pulling fs layer|Downloading|Extracting|Download complete|Pull complete|Waiting|Verifying Checksum) ]]; then
      [ "$pulling" -eq 0 ] && { printf '   %s│   … downloading image layers (progress hidden)%s\n' "$DIM" "$RST"; pulling=1; }
      continue
    fi
    pulling=0
    printf '   %s│%s %s\n' "$DIM" "$RST" "$line"
  done
}

# ---- token filtering (UTIL_ONLY / UTIL_SKIP) ----------------------------------
lc(){ printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
token_match(){ local list tok; list="$(printf '%s' "$2" | tr ',' ' ' | tr '[:upper:]' '[:lower:]')"
  for tok in $list; do [ -n "$tok" ] && case "$1" in *"$tok"*) return 0;; esac; done; return 1; }
EXCL_REASON=""
is_excluded(){ local nm; nm="$(lc "$1")"
  if [ -n "${UTIL_ONLY:-}" ] && ! token_match "$nm" "${UTIL_ONLY}"; then EXCL_REASON="not in UTIL_ONLY"; return 0; fi
  if [ -n "${UTIL_SKIP:-}" ] &&   token_match "$nm" "${UTIL_SKIP}"; then EXCL_REASON="UTIL_SKIP";       return 0; fi
  EXCL_REASON=""; return 1; }

#==============================================================================
# ARGUMENT PARSING — positional tokens classified by what they match, any order
#==============================================================================
ACTIONS="up down purge status creds restart logs test"
TARGETS_FIXED="all infra1 infra2 local"
VARIANTS="docker-single-node-setup native-single-node native-multi-node-cluster docker-multi-node-cluster"

usage(){
cat <<EOF
${BOLD}devops-dokandar-infra fleet orchestrator${RST}

  bash setup.sh [target] [variant] [action] [--flags]     (any order)

  target   all (default) | infra1 | infra2 | local | one of:
           $(echo "$ALL_TOOLS" | fold -s -w 66 | sed '2,$s/^/           /')
  variant  docker-single-node-setup (default)
  action   up | down | purge | status | creds | restart | logs | test

  flags    --host H          override the target server IP for this run
           --only "a b"      only tools whose name contains a token
           --skip "a b"      skip tools whose name contains a token
           --sleep N         cooldown before each boot (default 5; 0 = off)
           --mask            mask secrets in credential output
           --force           override the RAM guardrail
           --no-pull         skip the pull-all-images-first phase
           --public-host H   force the IP printed in endpoints
                             (default: the machine's PRIVATE/VPC IP)
           --key PATH        SSH key (default: $SSH_KEY)
           --no-color        plain output

  examples
    bash setup.sh                     # whole fleet up
    bash setup.sh all creds           # combined fleet credential sheet
    bash setup.sh infra2 test         # contract-test every datastore tool
    bash setup.sh postgresql status   # one utility, auto-routed
    bash setup.sh all down            # stop everything (data kept)
EOF
}

TARGET=""; VARIANT=""; ACTION=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0;;
    --host)        shift; [ $# -gt 0 ] || die "--host needs a value"; INFRA1_HOST="$1"; INFRA2_HOST="$1";;
    --only)        shift; [ $# -gt 0 ] || die "--only needs a value"; UTIL_ONLY="$1";;
    --skip)        shift; [ $# -gt 0 ] || die "--skip needs a value"; UTIL_SKIP="$1";;
    --sleep)       shift; [ $# -gt 0 ] || die "--sleep needs a value"; UTIL_SLEEP="$1";;
    --mask)        UTIL_MASK_SECRETS=1;;
    --force)       UTIL_FORCE=1;;
    --no-pull)     UTIL_NO_PULL=1;;
    --no-color)    NO_COLOR=1; RST=''; BOLD=''; DIM=''; RED=''; GRN=''; YLW=''; BLU=''; MAG=''; CYN='';;
    --public-host) shift; [ $# -gt 0 ] || die "--public-host needs a value"; PUBLIC_HOST="$1";;
    --key)         shift; [ $# -gt 0 ] || die "--key needs a value"; SSH_KEY="$1";;
    --*)           die "unknown flag '$1' (see --help)";;
    *)
      tok="$(lc "$1")"
      if   printf ' %s ' "$ACTIONS"       | grep -q " $tok "; then [ -z "$ACTION" ]  || die "two actions given ('$ACTION' and '$tok')";  ACTION="$tok"
      elif printf ' %s ' "$TARGETS_FIXED" | grep -q " $tok "; then [ -z "$TARGET" ]  || die "two targets given ('$TARGET' and '$tok')";  TARGET="$tok"
      elif printf ' %s ' "$ALL_TOOLS"     | grep -q " $tok "; then [ -z "$TARGET" ]  || die "two targets given ('$TARGET' and '$tok')";  TARGET="$tok"
      elif printf ' %s ' "$VARIANTS"      | grep -q " $tok "; then [ -z "$VARIANT" ] || die "two variants given ('$VARIANT' and '$tok')"; VARIANT="$tok"
      else die "unrecognised token '$1' — not a target, variant or action (see --help)"; fi;;
  esac
  shift
done
TARGET="${TARGET:-all}"; VARIANT="${VARIANT:-docker-single-node-setup}"; ACTION="${ACTION:-up}"
case "$UTIL_SLEEP" in ''|*[!0-9]*) die "--sleep expects a number";; esac

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=12 -o BatchMode=yes -o ServerAliveInterval=15)

#==============================================================================
# CREDENTIAL FORMATTER — reads a utility's .env, prints ready-to-paste
# connection strings on the PUBLIC host. Never hardcodes a secret.
#==============================================================================
_ENV=""
gv(){ printf '%s\n' "$_ENV" | awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,"");gsub(/^"|"$/,"");print;exit}'; }
sec(){ if [ "$UTIL_MASK_SECRETS" = 1 ] && [ -n "$1" ]; then printf '••••••••'; else printf '%s' "$1"; fi; }
row(){ [ -n "$2" ] && printf '   %-14s %s\n' "$1" "$2"; }

tool_creds(){ # $1 = utility name, $2 = .env path, $3 = public host
  local n="$1" H="$3"
  _ENV="$(cat "$2" 2>/dev/null)" || true
  [ -n "$_ENV" ] || { printf '\n%s### %s%s  %s(no .env yet — run: bash setup.sh %s up)%s\n' "$CYN" "$n" "$RST" "$DIM" "$n" "$RST"; return; }
  printf '\n%s### %s%s\n' "$CYN" "$n" "$RST"
  case "$n" in
    postgresql) local u p pt d dbs db var pw
      u=$(gv POSTGRES_USER); p=$(gv POSTGRES_PASSWORD); pt=$(gv POSTGRES_PORT); d=$(gv POSTGRES_DB)
      row endpoint "postgresql://${u}:$(sec "$p")@${H}:${pt:-5432}/${d}"
      row host:port "${H}:${pt:-5432}"; row superuser "$u"; row password "$(sec "$p")"
      dbs="$(gv DKD_DATABASES | tr ',' ' ')"
      for db in $dbs; do
        var="DKD_PASSWORD_$(printf '%s' "$db" | tr '[:lower:]' '[:upper:]')"; pw="$(gv "$var")"
        [ -n "$pw" ] && row "db ${db}" "postgresql://${db}:$(sec "$pw")@${H}:${pt:-5432}/${db}"
      done;;
    timescaledb) local u p pt d; u=$(gv TSDB_USER); p=$(gv TSDB_PASSWORD); pt=$(gv TSDB_PORT); d=$(gv TSDB_DB)
      row endpoint "postgresql://${u}:$(sec "$p")@${H}:${pt:-5433}/${d}"
      row host:port "${H}:${pt:-5433}"; row user "$u"; row password "$(sec "$p")";;
    redis) local p pt; p=$(gv REDIS_PASSWORD); pt=$(gv REDIS_PORT)
      row endpoint "redis://default:$(sec "$p")@${H}:${pt:-6379}/0"
      row host:port "${H}:${pt:-6379}"; row user default; row password "$(sec "$p")";;
    mongodb) local u p pt; u=$(gv MONGO_ROOT_USER); p=$(gv MONGO_ROOT_PASSWORD); pt=$(gv MONGO_PORT)
      row endpoint "mongodb://${u}:$(sec "$p")@${H}:${pt:-27017}/?authSource=admin"
      row host:port "${H}:${pt:-27017}"; row user "$u"; row password "$(sec "$p")";;
    kafka) local bp up; bp=$(gv KAFKA_EXTERNAL_PORT); up=$(gv KAFKA_UI_PORT)
      row bootstrap "${H}:${bp:-9092}  (PLAINTEXT)"; row ui "http://${H}:${up:-8080}"; row auth "none";;
    schema-registry) local pt; pt=$(gv APICURIO_PORT)
      row api "http://${H}:${pt:-8081}/apis"; row ui "http://${H}:${pt:-8081}/ui/"; row auth "none (in-memory registry)";;
    rabbitmq) local u p ap mp; u=$(gv RABBITMQ_USER); p=$(gv RABBITMQ_PASSWORD); ap=$(gv RABBITMQ_AMQP_PORT); mp=$(gv RABBITMQ_MGMT_PORT)
      row amqp-url "amqp://${u}:$(sec "$p")@${H}:${ap:-5672}/"
      row host:port "${H}:${ap:-5672}"; row user "$u"; row password "$(sec "$p")"; row mgmt-ui "http://${H}:${mp:-15672}";;
    clickhouse) local u p hp tp; u=$(gv CLICKHOUSE_USER); p=$(gv CLICKHOUSE_PASSWORD); hp=$(gv CLICKHOUSE_HTTP_PORT); tp=$(gv CLICKHOUSE_TCP_PORT)
      row http "http://${H}:${hp:-8123}"; row native-tcp "${H}:${tp:-9004}"
      row user "${u:-default}"; row password "$(sec "$p")"; row play-ui "http://${H}:${hp:-8123}/play";;
    neo4j) local p hp bp; p=$(gv NEO4J_PASSWORD); hp=$(gv NEO4J_HTTP_PORT); bp=$(gv NEO4J_BOLT_PORT)
      row bolt "bolt://${H}:${bp:-7687}"; row browser-ui "http://${H}:${hp:-7474}"
      row user neo4j; row password "$(sec "$p")";;
    opensearch) local pt; pt=$(gv OPENSEARCH_PORT)
      row endpoint "http://${H}:${pt:-9201}"; row auth "none (security off — learning config)"
      row note "canonical port 9201 (9200 belongs to elastic-apm ES)";;
    elastic-apm-stack) local ep app es ap kp; ep=$(gv ELASTIC_PASSWORD); app=$(gv APM_SECRET_TOKEN)
      es=$(gv ES_PORT); ap=$(gv APM_PORT); kp=$(gv KIBANA_PORT)
      row elasticsearch "http://elastic:$(sec "$ep")@${H}:${es:-9200}"
      row apm-ingest "http://${H}:${ap:-8200}  (Authorization: Bearer <apm-token>)"
      row kibana-ui "http://${H}:${kp:-5601}  (login: elastic)"
      row elastic-pass "$(sec "$ep")"; row apm-token "$(sec "$app")";;
    rustfs) local ak sk ap cp; ak=$(gv RUSTFS_ACCESS_KEY); sk=$(gv RUSTFS_SECRET_KEY); ap=$(gv RUSTFS_API_PORT); cp=$(gv RUSTFS_CONSOLE_PORT)
      row s3-endpoint "http://${H}:${ap:-9000}"
      row console-ui "http://${H}:${cp:-9001}/rustfs/console/index.html"
      row access-key "$ak"; row secret-key "$(sec "$sk")";;
    scylladb) local pt; pt=$(gv SCYLLA_CQL_PORT)
      row cql "${H}:${pt:-9042}"; row auth "none (learning config)";;
    *) printf '%s' "$_ENV" | grep -iE '^[A-Z0-9_]*(USER|PASS|TOKEN|SECRET|KEY|PORT)[A-Z0-9_]*=' \
         | grep -ivE 'IMAGE|VERSION|ENCRYPTION|MEM|HEAP' | sed 's/^/   /';;
  esac
}

#==============================================================================
# LOCAL LEG — runs ON a server (UTIL_LOCAL=1 via SSH, or target=local)
#==============================================================================
resolve_endpoint_host(){
  # The IP printed in every endpoint/credential: PRIVATE (VPC) by default.
  # PUBLIC_HOST / --public-host overrides it (e.g. for off-VPC laptop access).
  if [ -n "${PUBLIC_HOST:-}" ]; then printf '%s' "$PUBLIC_HOST"; return; fi
  local tok ip
  tok="$(curl -s -m 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
  ip="$(curl -s -m 2 -H "X-aws-ec2-metadata-token: ${tok}" http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null || true)"
  case "$ip" in *[!0-9.]*|'') ip="";; esac
  [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  printf '%s' "${ip:-127.0.0.1}"
}

preflight_ports(){   # verify EVERY utility's live ports match the canonical map + no duplicates
  step "Preflight — canonical host-port map (the no-conflict guarantee)"
  local bad=0 lines="" t vdir envf k v canon_v
  for t in $ALL_TOOLS; do
    vdir="$ROOT/$t/$VARIANT"; [ -d "$vdir" ] || continue
    envf="$vdir/.env"; [ -f "$envf" ] || envf="$vdir/.env.example"; [ -f "$envf" ] || continue
    while IFS='=' read -r k v; do
      v="${v%%[[:space:]]*}"
      [ -n "$v" ] || continue
      canon_v="$(printf '%s\n' "$CANON" | awk -F: -v t="$t" -v k="$k" '$1==t && $2==k {print $3}')"
      if [ -n "$canon_v" ] && [ "$v" != "$canon_v" ]; then
        err "$t: $k=$v DIVERGES from the canonical map (expected $canon_v) — fix ${envf#"$ROOT"/}"
        bad=1
      fi
      lines+="${v}|${t}|${k}"$'\n'
    done < <(grep -E '^[A-Z_0-9]*PORT[A-Z_0-9]*=[0-9]+' "$envf" 2>/dev/null)
  done
  local dups; dups="$(printf '%s' "$lines" | awk -F'|' 'NF>=2{c[$1]++; who[$1]=who[$1]"  "$2"("$3")"} END{for(p in c) if(c[p]>1) printf "   port %-7s claimed by BOTH:%s\n", p, who[p]}')"
  if [ -n "$dups" ]; then err "host-port collision(s):"; printf '%s\n' "$dups"; bad=1; fi
  [ "$bad" -eq 0 ] || die "port preflight FAILED — restore the canonical ports above and re-run"
  ok "all host ports match the canonical map — no collisions possible"
}

preflight_host(){
  step "Preflight — docker + RAM guardrail"
  command -v docker >/dev/null 2>&1 || die "docker not found on $(hostname) — install Docker Engine first"
  docker compose version >/dev/null 2>&1 || die "the 'docker compose' plugin is missing"
  docker info >/dev/null 2>&1 || die "cannot reach the Docker daemon (user not in 'docker' group?)"
  local mem_kib avail_kib mem_gib avail_gib n
  mem_kib="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"; avail_kib="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)"
  mem_gib="$(awk -v k="$mem_kib" 'BEGIN{printf "%.1f", k/1048576}')"
  avail_gib="$(awk -v k="$avail_kib" 'BEGIN{printf "%.1f", k/1048576}')"
  n="$(printf '%s\n' "${SEL_TOOLS[@]}" | wc -l)"
  ok "docker $(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) · compose OK · host ${mem_gib} GiB RAM (${avail_gib} GiB available) · $n tools selected"
  if [ "$n" -gt 8 ] && awk -v m="$mem_gib" 'BEGIN{exit !(m<6.0)}'; then
    if [ "$UTIL_FORCE" = 1 ]; then warn "UTIL_FORCE=1 — proceeding on a ${mem_gib} GiB host with $n tools (expect OOM kills)"
    else die "the full fleet (~6.5 GiB RSS) will NOT fit a ${mem_gib} GiB host — split it (infra1/infra2), skip tools, or --force"; fi
  elif [ "$n" -gt 8 ] && awk -v m="$mem_gib" 'BEGIN{exit !(m<12.0)}'; then
    warn "full fleet on a ${mem_gib} GiB host ≈ 80-90% RAM once warm — fine for a lab; every service is mem_limit-capped"
  fi
  if awk -v a="$avail_gib" 'BEGIN{exit !(a<1.0)}' && [ "$UTIL_FORCE" != 1 ]; then
    die "only ${avail_gib} GiB RAM available right now — free memory or re-run with --force"
  fi
}

phase_pull(){   # PHASE 0 — pull EVERY selected utility's images BEFORE booting anything
  step "PHASE 0 — pulling all images first ($(printf '%s\n' "${SEL_TOOLS[@]}" | wc -l) utilities; --no-pull skips)"
  local t vdir i=0 n rc done_n=0
  n="$(printf '%s\n' "${SEL_TOOLS[@]}" | wc -l)"
  for t in "${SEL_TOOLS[@]}"; do
    i=$((i+1)); vdir="$ROOT/$t/$VARIANT"
    [ -f "$vdir/docker-compose.yml" ] || { note "[$i/$n] $t — no compose file, skipped"; continue; }
    # .env must exist before pull (image tags are ${VAR}-interpolated from it)
    ( cd "$vdir" && bash setup_env.sh ) >/dev/null 2>&1
    [ -n "$PUB" ] && sed -i "s|^SERVER_IP=.*|SERVER_IP=${PUB}|" "$vdir/.env" 2>/dev/null
    local t0=$SECONDS
    docker compose --project-directory "$vdir" pull -q >/dev/null 2>&1; rc=$?
    if [ "$rc" -eq 0 ]; then ok "[$i/$n] $t images ready ($(fmt_dur $((SECONDS-t0))))"; done_n=$((done_n+1))
    else warn "[$i/$n] $t pull failed (rc=$rc) — the boot phase will retry"; fi
  done
  ok "images ready ($done_n/$n)"
}

run_tool(){   # $1=tool  $2=index  $3=total   → sets RUN_RC
  local t="$1" i="$2" n="$3" vdir="$ROOT/$1/$VARIANT" rc=0 t0=$SECONDS
  printf '\n%s%s%s\n' "$CYN" "$RULE" "$RST"
  printf '%s ▸ [%d/%d] %s%s   %s· %s %s%s\n' "$CYN" "$i" "$n" "$t" "$RST" "$DIM" "$VARIANT" "$ACTION" "$RST"
  if [ ! -d "$vdir" ] || [ ! -f "$vdir/setup.sh" ]; then
    warn "no '$VARIANT' variant built for $t — skipped"; RUN_RC=99; return
  fi
  case "$ACTION" in
    up)
      ( cd "$vdir" && bash setup_env.sh ) 2>&1 | indent_filter
      [ -n "$PUB" ] && sed -i "s|^SERVER_IP=.*|SERVER_IP=${PUB}|" "$vdir/.env" 2>/dev/null
      ( cd "$vdir" && SERVER_IP="$PUB" bash setup.sh up ) 2>&1 | indent_filter; rc=${PIPESTATUS[0]};;
    test)
      ( cd "$ROOT/$t" && bash test.sh "$VARIANT" ) 2>&1 | indent_filter; rc=${PIPESTATUS[0]};;
    *)
      # seed/complete .env first so pre-first-up verbs (status/logs/...) can
      # interpolate the compose file; idempotent and quiet.
      ( cd "$vdir" && bash setup_env.sh ) >/dev/null 2>&1
      [ -n "$PUB" ] && sed -i "s|^SERVER_IP=.*|SERVER_IP=${PUB}|" "$vdir/.env" 2>/dev/null
      ( cd "$vdir" && SERVER_IP="$PUB" bash setup.sh "$ACTION" ) 2>&1 | indent_filter; rc=${PIPESTATUS[0]};;
  esac
  RUN_DUR=$((SECONDS-t0)); RUN_RC=$rc
}

local_leg(){
  local label="${SERVER_LABEL:-local}"
  PUB="$(resolve_endpoint_host)"
  # which tools run here
  local sel=() t
  for t in $ALL_TOOLS; do is_excluded "$t" && continue; sel+=("$t"); done
  if [ "${#sel[@]}" -eq 0 ]; then die "no tools selected (UTIL_ONLY='${UTIL_ONLY:-}' UTIL_SKIP='${UTIL_SKIP:-}')"; fi
  SEL_TOOLS=("${sel[@]}")

  printf '\n%s%s%s\n' "$MAG" "$DRULE" "$RST"
  printf '%s  DOKANDAR fleet · %s · %s %s · %d tools · endpoints %s%s\n' "$BOLD" "$label" "$VARIANT" "$ACTION" "${#SEL_TOOLS[@]}" "$PUB" "$RST"
  printf '%s%s%s\n' "$MAG" "$DRULE" "$RST"
  note "tools: ${SEL_TOOLS[*]}"

  # ---- creds is read-only: no preflight, no boots ----
  if [ "$ACTION" = creds ]; then
    if [ "$UTIL_MASK_SECRETS" = 1 ]; then note "secrets MASKED (UTIL_MASK_SECRETS=1)."
    else warn "REAL secrets below — treat this output as sensitive. (--mask to mask.)"; fi
    local vdir running
    for t in "${SEL_TOOLS[@]}"; do
      vdir="$ROOT/$t/$VARIANT"
      if [ ! -f "$vdir/.env" ]; then printf '\n%s### %s%s  %s(not configured — bash setup.sh %s up)%s\n' "$CYN" "$t" "$RST" "$DIM" "$t" "$RST"; continue; fi
      running="$(docker compose --project-directory "$vdir" ps -q 2>/dev/null | head -1)"
      if [ -z "$running" ]; then printf '\n%s### %s%s  %s(configured but NOT RUNNING — bash setup.sh %s up)%s\n' "$CYN" "$t" "$RST" "$DIM" "$t" "$RST"; continue; fi
      tool_creds "$t" "$vdir/.env" "$PUB"
    done
    printf '\n##FLEET## label=%s action=creds ok=%d fail=0 skip=0 dur=0s\n' "$label" "${#SEL_TOOLS[@]}"
    return 0
  fi

  # ---- preflights ----
  if [ "$ACTION" = up ]; then
    preflight_host
    preflight_ports
    [ "$UTIL_NO_PULL" = 1 ] && note "PHASE 0 skipped (--no-pull)" || phase_pull
  fi
  [ "$ACTION" = purge ] && warn "PURGE deletes every selected utility's DATA under /data/dki — this is the explicit data-loss action."

  # ---- PHASE 1 — one utility at a time ----
  step "PHASE 1 — ${ACTION} one utility at a time"
  local -a NAMES RESULTS DURS
  local idx=0 rc n="${#SEL_TOOLS[@]}" t0=$SECONDS
  for t in "${SEL_TOOLS[@]}"; do
    NAMES[idx]="$t"; DURS[idx]=0
    if { [ "$ACTION" = up ] || [ "$ACTION" = restart ]; } && [ "$UTIL_SLEEP" -gt 0 ]; then
      note "… cooling down ${UTIL_SLEEP}s before $t (UTIL_SLEEP=$UTIL_SLEEP; 0 disables)"
      sleep "$UTIL_SLEEP"
    fi
    RUN_RC=0; RUN_DUR=0
    run_tool "$t" "$((idx+1))" "$n"
    rc=$RUN_RC; DURS[idx]=$RUN_DUR
    if [ "$rc" -eq 99 ]; then RESULTS[idx]="SKIP (no variant)"
    elif [ "$rc" -eq 0 ]; then
      RESULTS[idx]="OK"; [ "$ACTION" = test ] && RESULTS[idx]="PASS"
      printf '   %s✓ %s %s%s   %s· %s%s\n' "$GRN" "$t" "${RESULTS[idx]}" "$RST" "$DIM" "$(fmt_dur "${DURS[idx]}")" "$RST"
    else
      RESULTS[idx]="FAILED (rc=$rc)"
      printf '   %s✗ %s FAILED (rc=%s)%s   %s· inspect: bash setup.sh %s logs%s\n' "$RED" "$t" "$rc" "$RST" "$DIM" "$t" "$RST"
    fi
    idx=$((idx+1))
  done
  local total_dur=$((SECONDS-t0))

  # ---- summary table ----
  local n_ok=0 n_fail=0 n_skip=0 j mark
  for j in "${!RESULTS[@]}"; do case "${RESULTS[j]}" in OK|PASS) n_ok=$((n_ok+1));; FAILED*) n_fail=$((n_fail+1));; *) n_skip=$((n_skip+1));; esac; done
  printf '\n%s%s%s\n' "$MAG" "$DRULE" "$RST"
  printf '%s  %s — summary · %s %s%s\n' "$BOLD" "$label" "$VARIANT" "$ACTION" "$RST"
  printf '%s%s%s\n' "$MAG" "$DRULE" "$RST"
  for j in "${!NAMES[@]}"; do
    case "${RESULTS[j]}" in OK|PASS) mark="$GRN✓$RST";; FAILED*) mark="$RED✗$RST";; *) mark="$YLW•$RST";; esac
    printf '   %b  %-18s %-18s %s%s%s\n' "$mark" "${NAMES[j]}" "${RESULTS[j]}" "$DIM" "$(fmt_dur "${DURS[j]}")" "$RST"
  done
  printf '   %s\n' "$RULE"
  printf '   %s%d OK%s · %s%d FAILED%s · %s%d skipped%s   %s· %d tools · total %s%s\n' \
    "$GRN" "$n_ok" "$RST" "$RED" "$n_fail" "$RST" "$YLW" "$n_skip" "$RST" "$DIM" "${#NAMES[@]}" "$(fmt_dur "$total_dur")" "$RST"
  printf '   %shost RAM now:%s %s\n' "$DIM" "$RST" "$(free -m | awk '/^Mem:/{printf "%d MiB used of %d MiB (%d%%)", $3, $2, $3*100/$2}')"

  # ---- end-of-up credentials ----
  if [ "$ACTION" = up ] && [ "$n_ok" -gt 0 ]; then
    printf '\n%s%s%s\n' "$YLW" "$DRULE" "$RST"
    printf '%s  CREDENTIALS · %s · endpoints on %s   (again later: bash setup.sh %s creds)%s\n' "$BOLD" "$label" "$PUB" "$label" "$RST"
    printf '%s%s%s\n' "$YLW" "$DRULE" "$RST"
    if [ "$UTIL_MASK_SECRETS" = 1 ]; then note "secrets MASKED (UTIL_MASK_SECRETS=1)."
    else warn "REAL secrets below — treat this output as sensitive. (--mask to mask.)"; fi
    for j in "${!NAMES[@]}"; do
      [ "${RESULTS[j]}" = OK ] || continue
      tool_creds "${NAMES[j]}" "$ROOT/${NAMES[j]}/$VARIANT/.env" "$PUB"
    done
    printf '\n%sNext steps%s\n' "$BOLD" "$RST"
    printf '   whole-fleet creds  : %sbash setup.sh all creds%s\n' "$BOLD" "$RST"
    printf '   fleet status       : %sbash setup.sh all status%s\n' "$BOLD" "$RST"
    printf '   contract tests     : %sbash setup.sh all test%s\n' "$BOLD" "$RST"
    printf '   stop (KEEP data)   : %sbash setup.sh all down%s\n' "$BOLD" "$RST"
  fi

  printf '\n##FLEET## label=%s action=%s ok=%d fail=%d skip=%d dur=%ds\n' "$label" "$ACTION" "$n_ok" "$n_fail" "$n_skip" "$total_dur"
  [ "$n_fail" -gt 0 ] && return 1
  return 0
}

#==============================================================================
# CONTROL SIDE — SSH fan-out to the fleet
# (a leg whose host IS this machine runs locally — no SSH, no key needed)
#==============================================================================
SELF_IPS=""
detect_self_ips(){   # every IP this machine answers to: local addrs + EC2 public IP
  [ -n "$SELF_IPS" ] && return
  local tok pub
  tok="$(curl -s -m 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
  pub="$(curl -s -m 2 -H "X-aws-ec2-metadata-token: ${tok}" http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)"
  case "$pub" in *[!0-9.]*) pub="";; esac
  SELF_IPS="$(hostname -I 2>/dev/null | tr '\n' ' ') $pub 127.0.0.1 localhost"
}
is_self_host(){ detect_self_ips; case " $SELF_IPS " in *" $1 "*) return 0;; *) return 1;; esac; }

sync_repo(){ # $1 = host
  local host="$1"
  if ssh "${SSH_OPTS[@]}" "$SSH_USER@$host" "test -f \$HOME/$REMOTE_DIR/setup.sh" 2>/dev/null; then
    note "repo present on $host — syncing updates"
  else
    note "repo MISSING on $host — shipping it (fresh box provisioning)"
  fi
  if command -v rsync >/dev/null 2>&1 && ssh "${SSH_OPTS[@]}" "$SSH_USER@$host" 'command -v rsync' >/dev/null 2>&1; then
    rsync -az --exclude '.git' --exclude '.env' --exclude 'test-result.txt' --exclude 'scratchpad' \
      -e "ssh $(printf '%q ' "${SSH_OPTS[@]}")" "$ROOT/" "$SSH_USER@$host:$REMOTE_DIR/" \
      && ok "synced → $host:~/$REMOTE_DIR (remote .env files preserved)" && return 0
    warn "rsync failed — falling back to tar-over-ssh"
  fi
  tar -C "$(dirname "$ROOT")" -czf - --exclude='.git' --exclude='*/.env' --exclude='*.env' --exclude='test-result.txt' --exclude='scratchpad' "$(basename "$ROOT")" \
    | ssh "${SSH_OPTS[@]}" "$SSH_USER@$host" "tar -xzf - -C \$HOME && [ \"$(basename "$ROOT")\" = \"$REMOTE_DIR\" ] || { rm -rf \$HOME/$REMOTE_DIR; mv \$HOME/$(basename "$ROOT") \$HOME/$REMOTE_DIR; }" \
    && ok "shipped (tar) → $host:~/$REMOTE_DIR" || { err "could not ship the repo to $host"; return 1; }
}

run_leg(){ # $1=label  $2=host  $3=tools   → appends to LEG_* arrays
  local label="$1" host="$2" tools="$3" rc tmp t0=$SECONDS
  tmp="$(mktemp)"
  printf '\n%s%s%s\n' "$BLU" "$DRULE" "$RST"
  printf '%s  ── %s (%s) ──  %s%s%s\n' "$BOLD" "$label" "$host" "$DIM" "$tools" "$RST"
  printf '%s%s%s\n' "$BLU" "$DRULE" "$RST"
  if is_self_host "$host"; then
    note "target $host is THIS machine — running locally (no SSH needed)"
    ( UTIL_LOCAL=1 SERVER_LABEL="$label" PUBLIC_HOST="${PUBLIC_HOST:-}" UTIL_ONLY="$tools" UTIL_SKIP="${UTIL_SKIP:-}" \
      UTIL_SLEEP="$UTIL_SLEEP" UTIL_MASK_SECRETS="$UTIL_MASK_SECRETS" UTIL_FORCE="$UTIL_FORCE" \
      UTIL_NO_PULL="$UTIL_NO_PULL" bash "$ROOT/setup.sh" local "$VARIANT" "$ACTION" ) 2>&1 | tee "$tmp"
    rc=${PIPESTATUS[0]}
  else
    if [ ! -f "$SSH_KEY" ]; then
      err "SSH key not found: $SSH_KEY (--key PATH to override) — needed to reach $host"
      LEG_LABELS+=("$label"); LEG_HOSTS+=("$host"); LEG_RCS+=(2); LEG_SUMS+=("no SSH key"); rm -f "$tmp"; return 2
    fi
    sync_repo "$host" || { LEG_LABELS+=("$label"); LEG_HOSTS+=("$host"); LEG_RCS+=(3); LEG_SUMS+=("ship failed"); rm -f "$tmp"; return 1; }
    ssh "${SSH_OPTS[@]}" "$SSH_USER@$host" \
      "cd \$HOME/$REMOTE_DIR && UTIL_LOCAL=1 SERVER_LABEL='$label' PUBLIC_HOST='${PUBLIC_HOST:-}' UTIL_ONLY='$tools' UTIL_SKIP='${UTIL_SKIP:-}' UTIL_SLEEP='$UTIL_SLEEP' UTIL_MASK_SECRETS='$UTIL_MASK_SECRETS' UTIL_FORCE='$UTIL_FORCE' UTIL_NO_PULL='$UTIL_NO_PULL' bash setup.sh local $VARIANT $ACTION" \
      2>&1 | tee "$tmp"
    rc=${PIPESTATUS[0]}
  fi
  local sum; sum="$(grep -a '##FLEET##' "$tmp" | tail -1 | sed 's/.*##FLEET## //')"
  rm -f "$tmp"
  LEG_LABELS+=("$label"); LEG_HOSTS+=("$host"); LEG_RCS+=("$rc"); LEG_SUMS+=("${sum:-no summary} · $(fmt_dur $((SECONDS-t0)))")
  return "$rc"
}

control(){
  local -a LEG_LABELS=() LEG_HOSTS=() LEG_RCS=() LEG_SUMS=()

  printf '\n%s%s%s\n' "$MAG" "$DRULE" "$RST"
  printf '%s  DOKANDAR fleet orchestrator · target %s · %s %s%s\n' "$BOLD" "$TARGET" "$VARIANT" "$ACTION" "$RST"
  printf '%s%s%s\n' "$MAG" "$DRULE" "$RST"
  printf '   %-8s %s (%s)\n' infra1 "$INFRA1_HOST" "$INFRA1_TOOLS"
  printf '   %-8s %s (%s)\n' infra2 "$INFRA2_HOST" "$INFRA2_TOOLS"
  [ "$INFRA1_HOST" = "$INFRA2_HOST" ] && note "single-machine mode: infra1 = infra2 — one box carries the whole fleet (canonical ports keep it collision-free)"

  case "$TARGET" in
    all)
      if [ "$INFRA1_HOST" = "$INFRA2_HOST" ]; then
        run_leg "infra1+infra2" "$INFRA1_HOST" "$INFRA1_TOOLS $INFRA2_TOOLS"
      else
        run_leg "infra1" "$INFRA1_HOST" "$INFRA1_TOOLS"
        if [ "$UTIL_SLEEP" -gt 0 ] && [ "$ACTION" = up ]; then note "… cooling down ${UTIL_SLEEP}s between servers"; sleep "$UTIL_SLEEP"; fi
        run_leg "infra2" "$INFRA2_HOST" "$INFRA2_TOOLS"
      fi;;
    infra1) run_leg "infra1" "$INFRA1_HOST" "$INFRA1_TOOLS";;
    infra2) run_leg "infra2" "$INFRA2_HOST" "$INFRA2_TOOLS";;
    *)  # single utility — auto-route to the server that owns it
      local owner_host owner_label
      if printf ' %s ' "$INFRA1_TOOLS" | grep -q " $TARGET "; then owner_host="$INFRA1_HOST"; owner_label="infra1"
      else owner_host="$INFRA2_HOST"; owner_label="infra2"; fi
      run_leg "$owner_label/$TARGET" "$owner_host" "$TARGET";;
  esac

  # ---- fleet-wide roll-up ----
  local j any_fail=0
  printf '\n%s%s%s\n' "$MAG" "$DRULE" "$RST"
  printf '%s  FLEET ROLL-UP · %s %s%s\n' "$BOLD" "$TARGET" "$ACTION" "$RST"
  printf '%s%s%s\n' "$MAG" "$DRULE" "$RST"
  for j in "${!LEG_LABELS[@]}"; do
    if [ "${LEG_RCS[j]}" -eq 0 ]; then printf '   %s✓%s %-16s %-16s %s\n' "$GRN" "$RST" "${LEG_LABELS[j]}" "${LEG_HOSTS[j]}" "${LEG_SUMS[j]}"
    else printf '   %s✗%s %-16s %-16s rc=%s · %s\n' "$RED" "$RST" "${LEG_LABELS[j]}" "${LEG_HOSTS[j]}" "${LEG_RCS[j]}" "${LEG_SUMS[j]}"; any_fail=1; fi
  done
  [ "$any_fail" -eq 0 ] || exit 1
  exit 0
}

#==============================================================================
# ENTRY
#==============================================================================
if [ "${UTIL_LOCAL:-0}" = 1 ] || [ "$TARGET" = local ]; then
  # running ON a server (the remote leg), or explicitly local
  if [ "${UTIL_LOCAL:-0}" != 1 ] && [ -z "${UTIL_ONLY:-}" ]; then
    # bare `local` run: only the tools this host owns (any of its IPs matching the map)
    OWN=""
    is_self_host "$INFRA1_HOST" && OWN="$INFRA1_TOOLS"
    is_self_host "$INFRA2_HOST" && [ "$INFRA1_HOST" != "$INFRA2_HOST" ] && OWN="${OWN:+$OWN }$INFRA2_TOOLS"
    is_self_host "$INFRA2_HOST" && [ "$INFRA1_HOST" = "$INFRA2_HOST" ] && OWN="${OWN:+$OWN }$INFRA2_TOOLS"
    [ -n "$OWN" ] || die "this host is not in the fleet map — use --only \"<tools>\" or fix INFRA1_HOST/INFRA2_HOST"
    UTIL_ONLY="$OWN"
    SERVER_LABEL="${SERVER_LABEL:-local($(resolve_endpoint_host))}"
  fi
  local_leg
  exit $?
fi
control
