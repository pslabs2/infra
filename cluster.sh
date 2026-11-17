
#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-homelab}"

case "${1:-create}" in
  create)
    if k3d cluster list --no-headers | awk '{print $1}' | grep -qx "$CLUSTER_NAME"; then
      echo "Cluster '$CLUSTER_NAME' already exists."
      exit 0
    fi

    k3d cluster create "$CLUSTER_NAME" \
      --servers 1 \
      --agents 2 \
      --port "8080:80@loadbalancer" \
      --port "8443:443@loadbalancer" \
      --k3s-arg "--disable=traefik@server:*" \
      --k3s-arg "--disable=metrics-server@server:*" \
      --wait

    kubectl --context "k3d-$CLUSTER_NAME" \
      wait --for=condition=Ready nodes --all --timeout=180s
    ;;

  delete)
    k3d cluster delete "$CLUSTER_NAME"
    ;;

  status)
    kubectl --context "k3d-$CLUSTER_NAME" get nodes
    ;;

  *)
    echo "Usage: $0 [create|delete|status]"
    exit 1
    ;;
esac
