#!/usr/bin/env bash
# DOKANDAR — create/update every Kubernetes Secret from the env files in ./secrets/.
# Run ON THE JUMP SERVER with kubeconfig pointing at the EKS cluster.
# Idempotent: dry-run render piped into `kubectl apply`.
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

missing=0
for svc in "${!SVC_NS[@]}"; do
  ns="${SVC_NS[$svc]}"
  f="secrets/${SVC_DIR[$svc]}/${svc}.env"
  if [[ ! -f "$f" ]]; then
    echo "MISSING  $f  (copy from ${f}.example and fill values)"
    missing=1
    continue
  fi
  kubectl create secret generic "${svc}-secret" \
    --namespace "$ns" \
    --from-env-file="$f" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "APPLIED  ${svc}-secret  (namespace: $ns)"
done

# Registry pull secret — ONLY needed if NOT pulling from ECR via the node IAM role.
# Uncomment and fill if required:
# for ns in gateway frontend backend support; do
#   kubectl create secret docker-registry dokandar-registry-cred \
#     --namespace "$ns" \
#     --docker-server="<ACCOUNT>.dkr.ecr.ap-southeast-1.amazonaws.com" \
#     --docker-username=AWS \
#     --docker-password="$(aws ecr get-login-password --region ap-southeast-1)" \
#     --dry-run=client -o yaml | kubectl apply -f -
# done

exit $missing
