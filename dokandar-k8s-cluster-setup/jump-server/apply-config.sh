#!/usr/bin/env bash
# DOKANDAR — create/update every ConfigMap from the env files in ./config/.
# Run ON THE JUMP SERVER with kubeconfig pointing at the EKS cluster. Idempotent.
set -euo pipefail
cd "$(dirname "$0")"

declare -A SVC_NS=(
  ["dokandar-support"]="support"
  ["dokandar-auth"]="backend"
  ["dokandar-profile"]="backend"
  ["dokandar-seller"]="backend"
  ["dokandar-catalog"]="backend"
  ["dokandar-search"]="backend"
  ["dokandar-cart"]="backend"
  ["dokandar-coupon"]="backend"
  ["dokandar-review"]="backend"
  ["dokandar-payment"]="backend"
  ["dokandar-wallet"]="backend"
  ["dokandar-reporting"]="backend"
  ["dokandar-media"]="backend"
  ["dokandar-order"]="backend"
  ["dokandar-notification"]="backend"
  ["dokandar-api-gateway"]="gateway"
  ["dokandar-recommendation"]="backend"
  ["dokandar-shipping"]="backend"
  ["dokandar-risk-trust"]="backend"
  ["dokandar-frontend"]="frontend"
)
declare -A SVC_DIR=(
  ["dokandar-support"]="00-support"
  ["dokandar-auth"]="01-auth"
  ["dokandar-profile"]="02-profile"
  ["dokandar-seller"]="03-seller"
  ["dokandar-catalog"]="04-catalog"
  ["dokandar-search"]="05-search"
  ["dokandar-cart"]="06-cart"
  ["dokandar-coupon"]="07-coupon"
  ["dokandar-review"]="08-review"
  ["dokandar-payment"]="09-payment"
  ["dokandar-wallet"]="10-wallet"
  ["dokandar-reporting"]="11-reporting"
  ["dokandar-media"]="12-media"
  ["dokandar-order"]="13-order"
  ["dokandar-notification"]="14-notification"
  ["dokandar-api-gateway"]="15-api-gateway"
  ["dokandar-recommendation"]="16-recommendation"
  ["dokandar-shipping"]="17-shipping"
  ["dokandar-risk-trust"]="18-risk-trust"
  ["dokandar-frontend"]="frontend"
)

for svc in "${!SVC_NS[@]}"; do
  ns="${SVC_NS[$svc]}"
  f="config/${SVC_DIR[$svc]}/${svc}.env"
  [[ -f "$f" ]] || { echo "MISSING  $f"; exit 1; }
  kubectl create configmap "${svc}-config" \
    --namespace "$ns" \
    --from-env-file="$f" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "APPLIED  ${svc}-config  (namespace: $ns)"
done
