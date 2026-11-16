#!/usr/bin/env bash
#
# cluster.sh — bootstrap a local k3d cluster with Traefik and metrics-server
# disabled, so both can be installed and owned by ArgoCD later.
#
# Usage:
#   ./cluster.sh [create|delete|recreate|status]
#
# Configuration (environment variables):
#   CLUSTER_NAME   cluster name                         (default: homelab)
#   SERVERS        number of server (control-plane) nodes (default: 1)
#   AGENTS         number of agent (worker) nodes        (default: 2)
#   K3S_IMAGE      k3s image, e.g. rancher/k3s:v1.31.4-k3s1 (default: k3d's default)
#   API_PORT       host port for the Kubernetes API      (default: 6443)
#   HTTP_PORT      host port mapped to LB port 80        (default: 8080)
#   HTTPS_PORT     host port mapped to LB port 443       (default: 8443)
#   WAIT_TIMEOUT   readiness timeout                     (default: 180s)

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-homelab}"
SERVERS="${SERVERS:-1}"
AGENTS="${AGENTS:-2}"
K3S_IMAGE="${K3S_IMAGE:-}"
API_PORT="${API_PORT:-6443}"
HTTP_PORT="${HTTP_PORT:-8080}"
HTTPS_PORT="${HTTPS_PORT:-8443}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-180s}"

KUBE_CONTEXT="k3d-${CLUSTER_NAME}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require() {
  local bin
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || die "'$bin' is required but not installed"
  done
}

preflight() {
  require docker k3d kubectl
  docker info >/dev/null 2>&1 || die "Docker daemon is not reachable"
}

cluster_exists() {
  k3d cluster list --no-headers 2>/dev/null | awk '{print $1}' | grep -qx "$CLUSTER_NAME"
}

kc() { kubectl --context "$KUBE_CONTEXT" "$@"; }

create() {
  if cluster_exists; then
    log "Cluster '${CLUSTER_NAME}' already exists — skipping create"
  else
    log "Creating cluster '${CLUSTER_NAME}' (${SERVERS} server / ${AGENTS} agent)"

    local args=(
      cluster create "$CLUSTER_NAME"
      --servers "$SERVERS"
      --agents "$AGENTS"
      --api-port "127.0.0.1:${API_PORT}"
      # Ports land on the k3d load balancer, ready for the ArgoCD-managed
      # Traefik (LoadBalancer Service via the built-in ServiceLB) later.
      --port "${HTTP_PORT}:80@loadbalancer"
      --port "${HTTPS_PORT}:443@loadbalancer"
      # Packaged components ArgoCD will own instead of k3s.
      --k3s-arg "--disable=traefik@server:*"
      --k3s-arg "--disable=metrics-server@server:*"
      --kubeconfig-update-default
      --kubeconfig-switch-context
      --wait
      --timeout "$WAIT_TIMEOUT"
    )
    [[ -n "$K3S_IMAGE" ]] && args+=(--image "$K3S_IMAGE")

    k3d "${args[@]}"
  fi

  log "Waiting for nodes to be Ready"
  kc wait --for=condition=Ready nodes --all --timeout="$WAIT_TIMEOUT"

  log "Waiting for core system deployments"
  kc -n kube-system rollout status deployment/coredns --timeout="$WAIT_TIMEOUT"
  kc -n kube-system rollout status deployment/local-path-provisioner --timeout="$WAIT_TIMEOUT"

  verify
  status
}

# Fail loudly if k3s deployed the components we asked it to skip
# (e.g. the script was run against a pre-existing cluster created without the flags).
verify() {
  log "Verifying Traefik and metrics-server are not deployed by k3s"
  local failed=0

  if kc -n kube-system get deployment traefik >/dev/null 2>&1 \
     || kc -n kube-system get helmchart traefik >/dev/null 2>&1; then
    warn "Traefik is present in kube-system"
    failed=1
  fi

  if kc -n kube-system get deployment metrics-server >/dev/null 2>&1; then
    warn "metrics-server is present in kube-system"
    failed=1
  fi

  ((failed == 0)) || die "Cluster has k3s-managed components that should be disabled — run './cluster.sh recreate'"
  log "OK — both are absent and free for ArgoCD to manage"
}

delete() {
  if cluster_exists; then
    log "Deleting cluster '${CLUSTER_NAME}'"
    k3d cluster delete "$CLUSTER_NAME"
  else
    log "Cluster '${CLUSTER_NAME}' does not exist — nothing to delete"
  fi
}

status() {
  cluster_exists || die "Cluster '${CLUSTER_NAME}' does not exist"
  log "Cluster '${CLUSTER_NAME}' (context: ${KUBE_CONTEXT})"
  kc get nodes -o wide
  echo
  kc -n kube-system get pods
  echo
  log "API:   https://127.0.0.1:${API_PORT}"
  log "HTTP:  http://localhost:${HTTP_PORT}   (served once ArgoCD deploys Traefik)"
  log "HTTPS: https://localhost:${HTTPS_PORT}"
}

usage() {
  sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
  local cmd="${1:-create}"
  case "$cmd" in
    create)   preflight; create ;;
    delete)   preflight; delete ;;
    recreate) preflight; delete; create ;;
    status)   preflight; status ;;
    -h|--help|help) usage ;;
    *) usage; die "Unknown command: $cmd" ;;
  esac
}

main "$@"
