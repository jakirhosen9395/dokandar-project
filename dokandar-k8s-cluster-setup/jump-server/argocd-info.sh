#!/usr/bin/env bash
# One command → ArgoCD URL + username + password. VPN must be connected
# (all nodes are private). `./argocd-info.sh forward` = local tunnel instead.
set -euo pipefail
PW=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)
IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
PORT=$(kubectl -n argocd get svc argocd-server -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null || echo 30080)
echo "──────────────── ArgoCD access ────────────────"
echo "username : admin"
echo "password : ${PW:-<not found — is ArgoCD installed?>}"
echo "url      : http://${IP:-<node-ip>}:${PORT}   (over the VPN)"
echo "fallback : kubectl -n argocd port-forward svc/argocd-server 8080:80 → http://localhost:8080"
echo "───────────────────────────────────────────────"
[ "${1:-}" = "forward" ] && exec kubectl -n argocd port-forward svc/argocd-server 8080:80 || true
