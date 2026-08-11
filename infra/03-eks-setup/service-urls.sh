#!/usr/bin/env bash
# Print every service's browsable URL over the VPN (NodePort = 30000+NN).
# Each service serves: /docs (Swagger UI), /openapi.json, /ready, /health, /data, /metrics
set -euo pipefail
IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
printf "%-22s %-28s %s\n" "SERVICE" "BASE URL (over VPN)" "DOCS"
for e in 00:support 01:auth 02:profile 03:seller 04:catalog 05:search 06:cart 07:coupon 08:review \
         09:payment 10:wallet 11:reporting 12:media 13:order 14:notification 15:api-gateway \
         16:recommendation 17:shipping 18:risk-trust; do
  nn=${e%%:*}; svc=${e##*:}
  printf "%-22s http://%s:300%s          http://%s:300%s/docs\n" "$nn-$svc" "$IP" "$nn" "$IP" "$nn"
done
printf "%-22s http://%s:30020\n" "frontend (shop)" "$IP"
printf "%-22s http://%s:30080\n" "argocd ui" "$IP"
