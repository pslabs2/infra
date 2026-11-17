#!/usr/bin/env bash
# Bootstrap a remotely-managed Cloudflare Tunnel in Kubernetes and publish routes.
# Requirements: bash, curl, jq, kubectl, an API token with Zone:Read, DNS:Edit,
# and Account:Cloudflare Tunnel:Edit permissions.
#
# Usage:
#   ./cloudflare-homelab.sh setup     # create/reuse tunnel, deploy connector, publish
#   ./cloudflare-homelab.sh publish   # add/update another hostname route
#
# Environment:
#   CF_API_TOKEN, CF_ZONE_NAME (default pukarsubedi.com), CF_TUNNEL_NAME (default homelab),
#   CF_ACCOUNT_ID + CF_ZONE_ID (optional; skip zone discovery if BOTH supplied),
#   KUBE_CONTEXT (default k3d-homelab), CF_NAMESPACE (default cloudflared),
#   CLOUDFLARED_IMAGE (default cloudflare/cloudflared:latest)
set -Eeuo pipefail
umask 077

MODE="${1:-setup}"
case "$MODE" in
  setup|publish) ;;
  *) printf 'Usage: %s [setup|publish]\n' "$0" >&2; exit 2 ;;
esac

CF_API_BASE="https://api.cloudflare.com/client/v4"
ZONE="${CF_ZONE_NAME:-pukarsubedi.com}"
TUNNEL_NAME="${CF_TUNNEL_NAME:-homelab}"
KUBE_CONTEXT="${KUBE_CONTEXT:-k3d-homelab}"
NAMESPACE="${CF_NAMESPACE:-cloudflared}"
IMAGE="${CLOUDFLARED_IMAGE:-cloudflare/cloudflared:latest}"
DEPLOYMENT="cloudflared-homelab"
SECRET="cloudflared-homelab-token"
CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-}"
CF_ZONE_ID="${CF_ZONE_ID:-}"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }

confirm() {
  local reply
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^([yY]|[yY][eE][sS])$ ]]
}

for bin in curl jq kubectl; do
  command -v "$bin" >/dev/null 2>&1 || fail "Missing dependency: $bin"
done

if [[ -z "${CF_API_TOKEN:-}" ]]; then
  read -r -s -p 'Cloudflare API token (hidden): ' CF_API_TOKEN
  printf '\n'
fi
[[ -n "$CF_API_TOKEN" ]] || fail 'Cloudflare API token is required'

[[ "$ZONE" =~ ^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$ ]] || fail "Invalid zone: $ZONE"
[[ "$TUNNEL_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]] || fail "Invalid tunnel name: $TUNNEL_NAME"
[[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail "Invalid namespace: $NAMESPACE"

# Never print tokens, including on API errors. Cloudflare error messages are still printed.
cf_request() {
  local method="$1" path="$2" body="${3:-}" raw status response
  local -a options=(--silent --show-error --connect-timeout 10 --max-time 45 --retry 2
    --request "$method" --header "Authorization: Bearer $CF_API_TOKEN"
    --header 'Content-Type: application/json' --write-out $'\n%{http_code}')
  if [[ -n "$body" ]]; then options+=(--data-binary "$body"); fi
  raw=$(curl "${options[@]}" "${CF_API_BASE}${path}") || fail "Failed calling Cloudflare API: $method $path"
  status="${raw##*$'\n'}"
  response="${raw%$'\n'*}"
  if [[ ! "$status" =~ ^2[0-9][0-9]$ ]] || ! jq -e '.success == true' >/dev/null 2>&1 <<< "$response"; then
    local errors
    errors=$(jq -r '[.errors[]? | "\(.code): \(.message)"] | join("; ")' <<< "$response" 2>/dev/null || true)
    printf 'Cloudflare API %s %s failed (HTTP %s): %s\n' "$method" "$path" "$status" "${errors:-unknown error}" >&2
    return 1
  fi
  printf '%s\n' "$response"
}

info "Zone: $ZONE | Tunnel: $TUNNEL_NAME | Mode: $MODE"

if [[ -n "$CF_ACCOUNT_ID" && -n "$CF_ZONE_ID" ]]; then
  info 'Using supplied Cloudflare account and zone IDs'
elif [[ -z "$CF_ACCOUNT_ID" && -z "$CF_ZONE_ID" ]]; then
  info 'Discovering Cloudflare account and zone IDs'
  zone_result=$(cf_request GET "/zones?name=${ZONE}&per_page=50")
  zone_count=$(jq --arg zone "$ZONE" '[.result[] | select(.name == $zone)] | length' <<< "$zone_result")
  [[ "$zone_count" == 1 ]] || fail "Expected exactly one Cloudflare zone named $ZONE; found $zone_count"
  CF_ZONE_ID=$(jq -r --arg zone "$ZONE" '.result[] | select(.name == $zone) | .id' <<< "$zone_result")
  CF_ACCOUNT_ID=$(jq -r --arg zone "$ZONE" '.result[] | select(.name == $zone) | .account.id' <<< "$zone_result")
else
  fail 'Specify both CF_ACCOUNT_ID and CF_ZONE_ID, or neither'
fi
[[ "$CF_ACCOUNT_ID" =~ ^[0-9a-fA-F]{32}$ && "$CF_ZONE_ID" =~ ^[0-9a-fA-F]{32}$ ]] || fail 'Could not resolve valid Cloudflare account/zone IDs'

# Preflight Kubernetes before creating any remote Cloudflare resource.
if [[ "$MODE" == setup ]]; then
  info "Checking Kubernetes context $KUBE_CONTEXT"
  kubectl config get-contexts -o name | grep -Fxq "$KUBE_CONTEXT" || fail "Kubernetes context does not exist: $KUBE_CONTEXT"
