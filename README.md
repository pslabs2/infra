# Local ArgoCD UI

After creating the k3d cluster with `./cluster.sh` and installing ArgoCD with
`./argocd.sh`, open **http://localhost:8080** once ArgoCD has deployed Traefik
and synced its ingress. No port-forward or hosts-file entry is needed.
The existing `argocd.pukarsubedi.com` route remains available.

Log in as `admin`; retrieve the initial password with `./argocd.sh password`.
Run `./argocd.sh status` to see the pods, Applications, and local URL.

If you created the cluster with a custom `HTTP_PORT`, pass the same value to
`argocd.sh`, for example `HTTP_PORT=9080 ./argocd.sh status`. This setting
reports the existing host port; it does not change the cluster's port mapping.

The localhost rule lives in `bootstrap/argocd-values.yaml`, shared by bootstrap
and ArgoCD self-management. Commit and push changes to the GitOps `main` branch
so ArgoCD reconciliation preserves them on an existing cluster.

Local access uses plain HTTP and bypasses any Cloudflare Access policy on the
public hostname; ArgoCD authentication still applies. The rule matches the
`localhost` hostname but does not restrict network access to loopback:
`cluster.sh` currently publishes ingress ports on all host interfaces.