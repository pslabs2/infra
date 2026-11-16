#!/usr/bin/env bash
#
# argocd.sh — install ArgoCD on the k3d cluster and hand control to Git.
#
# Does exactly two imperative things, then stops:
#   1. Installs ArgoCD from the official Helm chart (pinned version).
#   2. Applies one root Application (app-of-apps) pointing at the GitOps repo.
# Everything else (Traefik, metrics-server, ArgoCD itself) is managed from Git.
#
# Usage:
#   ./argocd.sh [install|status|password|uninstall]
#
# Configuration (environment variables):
#   CLUSTER_NAME          k3d cluster name                  (default: homelab)
#   ARGOCD_NAMESPACE      namespace for ArgoCD              (default: argocd)
#   ARGOCD_RELEASE        Helm release name                 (default: argocd)
#   ARGOCD_CHART_VERSION  argo-cd Helm chart version        (default: 10.18.0)
#   REPO_URL              GitOps repository                 (default: https://github.com/pslabs2/infra)
#   REPO_REVISION         branch, tag or commit to track    (default: main)
#   ROOT_APP_PATH         repo path holding Application manifests
#                                                           (default: clusters/<CLUSTER_NAME>)
#   ROOT_APP_NAME         name of the root Application      (default: root)
#   GIT_USERNAME          only for a private repo           (default: git)
#   GIT_TOKEN             only for a private repo; a read-only access token
#   WAIT_TIMEOUT          readiness timeout                 (default: 300s)

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-homelab}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_RELEASE="${ARGOCD_RELEASE:-argocd}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-10.18.0}"
REPO_URL="${REPO_URL:-https://github.com/pslabs2/infra}"
REPO_REVISION="${REPO_REVISION:-main}"
ROOT_APP_PATH="${ROOT_APP_PATH:-clusters/${CLUSTER_NAME}}"
ROOT_APP_NAME="${ROOT_APP_NAME:-root}"
GIT_USERNAME="${GIT_USERNAME:-git}"
GIT_TOKEN="${GIT_TOKEN:-}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300s}"

KUBE_CONTEXT="k3d-${CLUSTER_NAME}"
HELM_REPO_URL="https://argoproj.github.io/argo-helm"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require() {
  local bin
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || die "'$bin' is required but not installed"
  done
}

kc() { kubectl --context "$KUBE_CONTEXT" "$@"; }
hc() { helm --kube-context "$KUBE_CONTEXT" "$@"; }

preflight() {
  require kubectl helm
  kc cluster-info >/dev/null 2>&1 \
    || die "Cannot reach context '${KUBE_CONTEXT}' — run ./cluster.sh first"
}

install_argocd() {
  log "Installing ArgoCD (chart ${ARGOCD_CHART_VERSION}) into namespace '${ARGOCD_NAMESPACE}'"
  hc upgrade --install "$ARGOCD_RELEASE" argo-cd \
    --repo "$HELM_REPO_URL" \
    --version "$ARGOCD_CHART_VERSION" \
    --namespace "$ARGOCD_NAMESPACE" \
    --create-namespace \
    --wait \
    --timeout "$WAIT_TIMEOUT"

  log "Waiting for the Application CRD"
  kc wait --for=condition=Established crd/applications.argoproj.io --timeout="$WAIT_TIMEOUT"
}

# Only needed when the GitOps repo is private.
configure_repo_credentials() {
  [[ -n "$GIT_TOKEN" ]] || return 0
  log "Registering credentials for ${REPO_URL}"
  kc -n "$ARGOCD_NAMESPACE" create secret generic gitops-repo \
    --from-literal=type=git \
    --from-literal=url="$REPO_URL" \
    --from-literal=username="$GIT_USERNAME" \
    --from-literal=password="$GIT_TOKEN" \
    --dry-run=client -o yaml \
    | kc label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
    | kc apply -f -
}

apply_root_app() {
  log "Applying root Application '${ROOT_APP_NAME}' -> ${REPO_URL} @ ${REPO_REVISION} : ${ROOT_APP_PATH}"
  kc apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${ROOT_APP_NAME}
  namespace: ${ARGOCD_NAMESPACE}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${REPO_REVISION}
    path: ${ROOT_APP_PATH}
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: ${ARGOCD_NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
}

install() {
  install_argocd
  configure_repo_credentials
  apply_root_app
  status
  echo
  log "UI:       kubectl --context ${KUBE_CONTEXT} -n ${ARGOCD_NAMESPACE} port-forward svc/${ARGOCD_RELEASE}-server 8081:443"
  log "          then open https://localhost:8081 (user: admin)"
  log "Password: ./argocd.sh password"
}

status() {
  log "ArgoCD pods (context: ${KUBE_CONTEXT})"
  kc -n "$ARGOCD_NAMESPACE" get pods
  echo
  log "Applications"
  kc -n "$ARGOCD_NAMESPACE" get applications.argoproj.io 2>/dev/null \
    || warn "No Applications found"
}

password() {
  kc -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d \
    || die "Initial admin secret not found (it may have been deleted after a password change)"
  echo
}

uninstall() {
  warn "Removing the root Application also prunes everything it manages"
  kc -n "$ARGOCD_NAMESPACE" delete applications.argoproj.io "$ROOT_APP_NAME" \
    --ignore-not-found --timeout="$WAIT_TIMEOUT"
  hc uninstall "$ARGOCD_RELEASE" --namespace "$ARGOCD_NAMESPACE" --ignore-not-found --wait
  kc delete namespace "$ARGOCD_NAMESPACE" --ignore-not-found
}

usage() {
  sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
  local cmd="${1:-install}"
  case "$cmd" in
    install)   preflight; install ;;
    status)    preflight; status ;;
    password)  preflight; password ;;
    uninstall) preflight; uninstall ;;
    -h|--help|help) usage ;;
    *) usage; die "Unknown command: $cmd" ;;
  esac
}

main "$@"
