#!/usr/bin/env bash
#
# argocd.sh — install ArgoCD on the k3d cluster and hand control to Git.
#
# Four steps, then Git takes over:
#   1. Create the ArgoCD namespace.
#   2. Create the Redis password Secret (replaces the chart's init job).
#   3. Install ArgoCD from the official Helm chart.
#   4. Apply the root Application (bootstrap/root.yaml).
#
# The chart version is read from clusters/<cluster>/argocd.yaml and the Helm
# values from bootstrap/argocd-values.yaml — the same files ArgoCD uses to
# manage itself, so the bootstrap and the GitOps state cannot drift.
#
# Usage:
#   ./argocd.sh [install|status|password]
#
# Configuration (environment variables):
#   CLUSTER_NAME   k3d cluster name       (default: homelab)
#   WAIT_TIMEOUT   readiness timeout      (default: 300s)
#   DEBUG          set to 1 for Helm debug output

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-homelab}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300s}"
DEBUG="${DEBUG:-0}"

KUBE_CONTEXT="k3d-${CLUSTER_NAME}"
NAMESPACE="argocd"
RELEASE="argocd"
REDIS_SECRET="argocd-redis"
HELM_REPO_URL="https://argoproj.github.io/argo-helm"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="${ROOT_DIR}/bootstrap/argocd-values.yaml"
ROOT_APP_FILE="${ROOT_DIR}/bootstrap/root.yaml"
ARGOCD_APP_FILE="${ROOT_DIR}/clusters/${CLUSTER_NAME}/argocd.yaml"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

kc() { kubectl --context "$KUBE_CONTEXT" "$@"; }
hc() { helm --kube-context "$KUBE_CONTEXT" "$@"; }

preflight() {
  local bin
  for bin in kubectl helm; do
    command -v "$bin" >/dev/null 2>&1 || die "'$bin' is required but not installed"
  done
  kc cluster-info >/dev/null 2>&1 \
    || die "Cannot reach context '${KUBE_CONTEXT}' — run ./cluster.sh first"
}

# The argo-cd chart version pinned in the self-management Application.
chart_version() {
  local version
  version="$(awk '/chart:[[:space:]]*argo-cd/ {found=1}
                  found && /targetRevision:/ {print $2; exit}' "$ARGOCD_APP_FILE")"
  [[ -n "$version" ]] || die "No argo-cd chart version found in ${ARGOCD_APP_FILE}"
  echo "$version"
}

install() {
  local file
  for file in "$VALUES_FILE" "$ROOT_APP_FILE" "$ARGOCD_APP_FILE"; do
    [[ -f "$file" ]] || die "Missing ${file}"
  done
  local version
  version="$(chart_version)"

  kc get namespace "$NAMESPACE" >/dev/null 2>&1 || kc create namespace "$NAMESPACE"

  # Created here so the chart's redis-secret-init pre-install job, which Helm
  # blocks on, can stay disabled (see bootstrap/argocd-values.yaml).
  if ! kc -n "$NAMESPACE" get secret "$REDIS_SECRET" >/dev/null 2>&1; then
    log "Creating Redis secret '${REDIS_SECRET}'"
    local password
    password="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)"
    [[ ${#password} -eq 32 ]] || die "Failed to generate a Redis password"
    kc -n "$NAMESPACE" create secret generic "$REDIS_SECRET" \
      --from-literal=auth="$password" >/dev/null
  fi

  # An interrupted run leaves the release locked ("another operation is in progress").
  if hc list --namespace "$NAMESPACE" --pending --short | grep -qx "$RELEASE"; then
    log "Removing release left in a pending state by an earlier run"
    hc uninstall "$RELEASE" --namespace "$NAMESPACE" --no-hooks
  fi

  log "Installing ArgoCD (chart ${version})"
  local helm_args=(
    upgrade --install "$RELEASE" argo-cd
    --repo "$HELM_REPO_URL"
    --version "$version"
    --namespace "$NAMESPACE"
    --values "$VALUES_FILE"
    --hide-notes
    --wait
    --timeout "$WAIT_TIMEOUT"
  )
  [[ "$DEBUG" == "1" ]] && helm_args+=(--debug)
  hc "${helm_args[@]}"

  log "Applying root Application"
  kc wait --for=condition=Established crd/applications.argoproj.io --timeout="$WAIT_TIMEOUT" >/dev/null
  kc apply -f "$ROOT_APP_FILE"

  status
  echo
  log "UI:       kubectl --context ${KUBE_CONTEXT} -n ${NAMESPACE} port-forward svc/${RELEASE}-server 8081:443"
  log "          then open https://localhost:8081 (user: admin)"
  log "Password: $0 password"
}

status() {
  log "ArgoCD pods (context: ${KUBE_CONTEXT})"
  kc -n "$NAMESPACE" get pods
  echo
  log "Applications"
  kc -n "$NAMESPACE" get applications.argoproj.io
}

password() {
  kc -n "$NAMESPACE" get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d \
    || die "Initial admin secret not found (it may have been deleted after a password change)"
  echo
}

usage() { sed -n '3,21p' "$0" | sed 's/^# \{0,1\}//'; }

main() {
  case "${1:-install}" in
    install)  preflight; install ;;
    status)   preflight; status ;;
    password) preflight; password ;;
    -h|--help|help) usage ;;
    *) usage; die "Unknown command: $1" ;;
  esac
}

main "$@"
