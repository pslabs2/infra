
#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-homelab}"
CONTEXT="k3d-${CLUSTER_NAME}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES="$ROOT_DIR/bootstrap/argocd-values.yaml"
ROOT_APP="$ROOT_DIR/bootstrap/root.yaml"
ARGOCD_APP="$ROOT_DIR/clusters/$CLUSTER_NAME/argocd.yaml"

case "${1:-install}" in
  install)
    # Ensure required configuration exists
    for file in "$VALUES" "$ROOT_APP" "$ARGOCD_APP"; do
      [[ -f "$file" ]] || { echo "Missing: $file"; exit 1; }
    done

    # Read chart version from GitOps configuration
    VERSION=$(awk '
      /chart:[[:space:]]*argo-cd/ { found=1 }
      found && /targetRevision:/ { print $2; exit }
    ' "$ARGOCD_APP")

    [[ -n "$VERSION" ]] || { echo "Chart version not found"; exit 1; }

    # Create namespace
    kubectl --context "$CONTEXT" \
      create namespace argocd --dry-run=client -o yaml |
      kubectl --context "$CONTEXT" apply -f -

    # Create Redis password if missing
    if ! kubectl --context "$CONTEXT" -n argocd \
      get secret argocd-redis &>/dev/null; then

      PASSWORD=$(openssl rand -hex 32)

      kubectl --context "$CONTEXT" -n argocd \
        create secret generic argocd-redis \
        --from-literal=auth="$PASSWORD"
    fi

    # Install Argo CD
    helm --kube-context "$CONTEXT" upgrade --install argocd argo-cd \
      --repo https://argoproj.github.io/argo-helm \
      --version "$VERSION" \
      --namespace argocd \
      --values "$VALUES" \
      --wait \
      --timeout 5m

    # Hand control to GitOps
    kubectl --context "$CONTEXT" \
      apply -f "$ROOT_APP"

    echo "Argo CD installed. Root Application applied."
    ;;

  status)
    kubectl --context "$CONTEXT" -n argocd get pods
    kubectl --context "$CONTEXT" -n argocd get applications
    ;;

  password)
    kubectl --context "$CONTEXT" -n argocd \
      get secret argocd-initial-admin-secret \
      -o jsonpath='{.data.password}' | base64 -d
    echo
    ;;

  *)
    echo "Usage: $0 [install|status|password]"
    exit 1
    ;;
esac
