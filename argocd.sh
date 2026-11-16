#!/usr/bin/env bash
#
# cloudflared.sh — the one cloudflared piece that cannot live in Git.
#
# Creates the tunnel-token Secret that the ArgoCD-managed cloudflared
# Deployment (apps/cloudflared/) reads. The tunnel, its public hostname and
# the Access policy already exist on the Cloudflare side.
#
# Usage:
#   ./cloudflared.sh [secret|verify]
#
#   secret   create or update the token Secret (default)
#   verify   request the public ArgoCD URL until it answers through the tunnel
#
# Configuration:
#   CLOUDFLARE_TUNNEL_TOKEN  tunnel token; read from the environment, or from a
#                            git-ignored .env file next to this script
#   CLUSTER_NAME             k3d cluster name            (default: homelab)
#   VERIFY_TIMEOUT           seconds to wait in 'verify' (default: 180)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${ROOT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "${ROOT_DIR}/.env"
  set +a
fi

CLUSTER_NAME="${CLUSTER_NAME:-homelab}"
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-180}"

KUBE_CONTEXT="k3d-${CLUSTER_NAME}"
NAMESPACE="cloudflared"
SECRET="cloudflared-token"
VALUES_FILE="${ROOT_DIR}/bootstrap/argocd-values.yaml"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

kc() { kubectl --context "$KUBE_CONTEXT" "$@"; }

secret() {
  command -v kubectl >/dev/null 2>&1 || die "'kubectl' is required but not installed"
  [[ -n "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]] \
    || die "CLOUDFLARE_TUNNEL_TOKEN is not set (export it, or put it in ${ROOT_DIR}/.env)"
  kc cluster-info >/dev/null 2>&1 \
    || die "Cannot reach context '${KUBE_CONTEXT}' — run ./cluster.sh first"

  kc get namespace "$NAMESPACE" >/dev/null 2>&1 || kc create namespace "$NAMESPACE"

  log "Applying tunnel token Secret '${NAMESPACE}/${SECRET}'"
  kc -n "$NAMESPACE" create secret generic "$SECRET" \
    --from-literal=token="$CLOUDFLARE_TUNNEL_TOKEN" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
}

# 2xx/3xx means Cloudflare reached ArgoCD (or answered with the Access login
# redirect). 5xx — typically 502/530 — means the tunnel or the route is down.
verify() {
  command -v curl >/dev/null 2>&1 || die "'curl' is required but not installed"
  local host
  host="$(awk '/^[[:space:]]+domain:/ {print $2; exit}' "$VALUES_FILE")"
  [[ -n "$host" ]] || die "No global.domain found in ${VALUES_FILE}"

  log "Checking https://${host}"
  local deadline=$((SECONDS + VERIFY_TIMEOUT)) result="" code=""
  while true; do
    result="$(curl -sS -o /dev/null --max-time 10 \
      -w '%{http_code} %{redirect_url}' "https://${host}" 2>/dev/null || true)"
    code="${result%% *}"
    if [[ "$code" =~ ^[23] ]]; then
      case "$result" in
        *cloudflareaccess.com*) log "OK — HTTP ${code}, protected by Cloudflare Access" ;;
        *) log "OK — HTTP ${code}. No Access redirect seen: check the Access policy covers ${host}" ;;
      esac
      return 0
    fi
    ((SECONDS < deadline)) || die "https://${host} not reachable after ${VERIFY_TIMEOUT}s (last response: ${result:-none})"
    sleep 5
  done
}

usage() { sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-secret}" in
  secret) secret ;;
  verify) verify ;;
  -h|--help|help) usage ;;
  *) usage; die "Unknown command: $1" ;;
esac