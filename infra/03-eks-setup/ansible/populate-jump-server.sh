#!/usr/bin/env bash
# Take the rendered .envs/*.env (render-envs.sh output — the SAME env each service
# gets on Docker) and populate dokandar-k8s-cluster-setup/jump-server/secrets/,
# rewriting every east-west address from host:100NN/200NN to Kubernetes DNS:
#   <ip>:100NN -> http://dokandar-<svc>.<ns>.svc.cluster.local:8000  (REST)
#   <ip>:200NN -> dokandar-<svc>.<ns>.svc.cluster.local:8001         (gRPC)
# Infra addresses (utilities host: 5432/27017/6379/9092/...) are left UNTOUCHED —
# the databases live outside the cluster.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# Overridable via env so this runs from the jump-server workspace too.
ENVS="${ENVS_OUT:-$HERE/.envs}"
JS="${JS:-$HERE/../../../dokandar-k8s-cluster-setup/jump-server}"
[ -d "$ENVS" ] || { echo "ERROR: $ENVS missing — run render-envs.sh first"; exit 1; }
[ -d "$JS" ]   || { echo "ERROR: $JS missing"; exit 1; }

declare -A SVC=( [00]=support [01]=auth [02]=profile [03]=seller [04]=catalog [05]=search
  [06]=cart [07]=coupon [08]=review [09]=payment [10]=wallet [11]=reporting [12]=media
  [13]=order [14]=notification [15]=api-gateway [16]=recommendation [17]=shipping [18]=risk-trust )
ns_of() { case "$1" in 00) echo support;; 15) echo gateway;; *) echo backend;; esac; }

rewrite() { # stdin -> stdout with k8s DNS for every 100NN/200NN reference
  local sed_args=()
  for nn in "${!SVC[@]}"; do
    local svc="${SVC[$nn]}" ns; ns="$(ns_of "$nn")"
    local dns="dokandar-${svc}.${ns}.svc.cluster.local"
    # Match http(s)://ANY-HOST-OR-IP:100NN — the http:// prefix between = and hostname
    # was breaking the old [=,] anchor pattern; use a scheme-aware match instead.
    sed_args+=(-e "s|https\?://[A-Za-z0-9_.:-]*:100${nn}|http://${dns}:8000|g")
    # Match bare =HOST:100NN (no scheme)
    sed_args+=(-e "s|=\([A-Za-z0-9_.:-]*\):100${nn}|=http://${dns}:8000|g")
    # Match gRPC ADDR vars: HOST:200NN -> dns:8001
    sed_args+=(-e "s|[A-Za-z0-9_.:-]*:200${nn}|${dns}:8001|g")
  done
  # support uses port 10099, not 10000 (non-standard — handle separately)
  sed_args+=(-e "s|https\?://[A-Za-z0-9_.:-]*:10099|http://dokandar-support.support.svc.cluster.local:8000|g")
  # seller has HOST-only gRPC vars with no port — port-based patterns can't reach them
  sed_args+=(-e "s|^\(AUTH_GRPC_HOST\)=.*|\1=dokandar-auth.backend.svc.cluster.local|")
  sed_args+=(-e "s|^\(MEDIA_GRPC_HOST\)=.*|\1=dokandar-media.backend.svc.cluster.local|")
  sed_args+=(-e "s|^\(COUPON_GRPC_HOST\)=.*|\1=dokandar-coupon.backend.svc.cluster.local|")
  # JWKS_URL trailing-slash variant — belt-and-suspenders for auth path with /
  sed_args+=(-e "s|https\?://[A-Za-z0-9_.:-]*:10001/|http://dokandar-auth.backend.svc.cluster.local:8000/|g")
  sed "${sed_args[@]}"
}

for f in "$ENVS"/[0-9][0-9]-*.env; do
  base="$(basename "$f" .env)"        # e.g. 01-auth
  nn="${base%%-*}"; svc="${SVC[$nn]}"
  dir="$JS/secrets/$base"; mkdir -p "$dir"
  { echo "# GENERATED from render-envs.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ) — full service env (k8s east-west rewritten)";
    rewrite < "$f" | sed 's/^TENANT=.*/TENANT=cloud/'; } > "$dir/dokandar-${svc}.env"
  chmod 600 "$dir/dokandar-${svc}.env"
  echo "secrets/$base/dokandar-${svc}.env"
done

# Frontend: k8s-native env (BFF -> gateway via cluster DNS)
mkdir -p "$JS/secrets/frontend"
SC="$(grep -m1 '^SESSION_COOKIE_SECRET=' "$ENVS/frontend.env" 2>/dev/null | cut -d= -f2- || true)"
[ -n "$SC" ] || SC="$(openssl rand -hex 32)"
cat > "$JS/secrets/frontend/dokandar-frontend.env" <<EOF
# GENERATED — frontend secrets for EKS
SESSION_COOKIE_SECRET=${SC}
EOF
chmod 600 "$JS/secrets/frontend/dokandar-frontend.env"
echo "secrets/frontend/dokandar-frontend.env"
echo "DONE — jump-server secrets populated. Config files (non-sensitive) are already committed."
