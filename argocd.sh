#!/usr/bin/env bash
set -euo pipefail

# Configuration
CLUSTER_NAME="${CLUSTER_NAME:-homelab}"
CONTEXT="k3d-${CLUSTER_NAME}"
NAMESPACE="argocd"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES="$ROOT_DIR/bootstrap/argocd-values.yaml"
ROOT_APP="$ROOT_DIR/bootstrap/root.yaml"
ARGOCD_APP="$ROOT_DIR/clusters/$CLUSTER_NAME/argocd.yaml"


# Create Redis secret if missing
create_redis_secret() {
  if kubectl --context "$CONTEXT" -n "$NAMESPACE" \
    get secret argocd-redis &>/dev/null; then
    return
  fi

  echo "Creating Redis secret..."

  kubectl --context "$CONTEXT" -n "$NAMESPACE" \
    create secret generic argocd-redis \
    --from-literal=auth="$(openssl rand -hex 32)"
}


# Install Argo CD and bootstrap GitOps
install_argocd() {
  echo "Bootstrapping Argo CD..."

  # Verify configuration files
  for file in "$VALUES" "$ROOT_APP" "$ARGOCD_APP"; do
    [[ -f "$file" ]] || {
      echo "Missing configuration: $file"
      exit 1
    }
  done

  # Verify cluster connectivity
  kubectl --context "$CONTEXT" cluster-info >/dev/null

  # Check whether Argo CD is already installed
  local release
  release=$(helm --kube-context "$CONTEXT" \
    list -n "$NAMESPACE" -q -f '^argocd$')

  if [[ -z "$release" ]]; then
    echo "Installing Argo CD..."

    # Read chart version from GitOps Application
    local version
    version=$(awk '
      /chart:[[:space:]]*argo-cd/ { found=1 }
      found && /targetRevision:/ { print $2; exit }
    ' "$ARGOCD_APP")

    [[ -n "$version" ]] || {
      echo "Argo CD chart version not found."
      exit 1
    }

    # Create namespace
    kubectl --context "$CONTEXT" \
      create namespace "$NAMESPACE" --dry-run=client -o yaml |
      kubectl --context "$CONTEXT" apply -f -

    create_redis_secret

    # Install Helm chart
    helm --kube-context "$CONTEXT" \
      upgrade --install argocd argo-cd \
      --repo https://argoproj.github.io/argo-helm \
      --version "$version" \
      --namespace "$NAMESPACE" \
      --values "$VALUES" \
      --wait \
      --timeout 5m

    echo "Argo CD installed successfully."
  else
    echo "Argo CD Helm release exists. Skipping installation."
  fi

  # Hand control to GitOps
  echo "Applying root Application..."
  kubectl --context "$CONTEXT" apply -f "$ROOT_APP"

  echo "GitOps bootstrap complete."
}


# Wait for Argo CD Applications
wait_argocd() {
  echo "Waiting for Argo CD Applications..."

  # Wait until the root Application is created
  kubectl --context "$CONTEXT" -n "$NAMESPACE" \
    wait --for=create applications.argoproj.io/root \
    --timeout=5m

  # Wait until Applications are synced
  kubectl --context "$CONTEXT" -n "$NAMESPACE" \
    wait --for=jsonpath='{.status.sync.status}'=Synced \
    applications.argoproj.io --all \
    --timeout=5m

  # Wait until Applications are healthy
  kubectl --context "$CONTEXT" -n "$NAMESPACE" \
    wait --for=jsonpath='{.status.health.status}'=Healthy \
    applications.argoproj.io --all \
    --timeout=5m

  echo "Argo CD Applications are Synced and Healthy."
}


# Show first-time login information
show_login() {
  local password

  password=$(kubectl --context "$CONTEXT" -n "$NAMESPACE" \
    get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d) || true

  cat <<EOF

========================================
             Argo CD Login
========================================

Username: admin
Password: ${password:-Unavailable (use existing password)}

1. Start port-forwarding:

   kubectl --context $CONTEXT -n $NAMESPACE port-forward svc/argocd-server 8081:80

2. Open:

   http://localhost:8081

========================================
EOF
}


# Show Argo CD status
show_status() {
  echo "Argo CD Pods:"
  kubectl --context "$CONTEXT" -n "$NAMESPACE" get pods

  echo
  echo "Argo CD Applications:"
  kubectl --context "$CONTEXT" -n "$NAMESPACE" get applications
}


# Show everything
show_argocd() {
  show_status
  show_login
}


# Command entry point
case "${1:-install}" in
  install)       install_argocd ;;
  wait)          wait_argocd ;;
  show)          show_argocd ;;
  status)        show_status ;;
  instructions)  show_login ;;
  *)
    echo "Usage: $0 [install|wait|show|status|instructions]"
    exit 1
    ;;
esac