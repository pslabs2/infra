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

## Homelab Dashboard

The root Argo CD Application deploys Dashboard into the `dashboard` namespace
with a Traefik ingress for `dashboard.pukarsubedi.com`. Commit and push the
change to the GitOps `main` branch for Argo CD to sync it.

The Cloudflare Tunnel is remotely managed. Configure its public hostname
`dashboard.pukarsubedi.com` to route to
`http://traefik.traefik.svc.cluster.local:80`, preserving the original Host
header, and configure its DNS record. Cloudflare terminates public HTTPS;
the ingress itself serves HTTP.

Dashboard exposes cluster state without authentication. A Cloudflare Access
policy can protect the public hostname, but direct access to the published
Traefik port bypasses it. Restrict network access to that port separately.

## Homelab Observability

The root Argo CD Application manages Grafana, Prometheus, Loki, and the
OpenTelemetry Collector in the `observability` namespace. On an existing
cluster, run `bash ./argocd.sh observability` before syncing the new apps from
GitOps `main`. It creates the namespace and generates the Grafana admin
Secret if missing, without replacing existing credentials. Fresh installs
do this as part of `bash ./argocd.sh install`.

Grafana and Prometheus have Traefik ingress at
`https://grafana.pukarsubedi.com` and `https://prometheus.pukarsubedi.com`.
In the remotely managed Cloudflare Tunnel, publish both hostnames to
`http://traefik.traefik.svc.cluster.local:80`, preserving the original Host
header, and configure their DNS records. Cloudflare terminates public TLS;
restrict direct access to the plain HTTP Traefik port.

Grafana uses its own login. Prometheus uses Traefik Basic Auth. Create its
Secret before opening the route; Traefik won't serve it without the Secret.
`htpasswd` prompts for a separate, strong password:

```sh
htpasswd -nB prometheus | \
  kubectl --context k3d-homelab -n observability \
    create secret generic prometheus-ingress-auth --from-file=users=/dev/stdin
```

Sign in to Prometheus as `prometheus` and only send credentials over HTTPS.
Cloudflare Access can further restrict who reaches either hostname.

For Grafana, log in as `admin`. Retrieve the initial password with:

```sh
kubectl --context k3d-homelab -n observability get secret grafana-admin \
  -o jsonpath='{.data.admin-password}' | base64 -d
echo
```

Grafana comes with both data sources configured. In **Explore**, query `up`
in Prometheus or `{k8s_namespace_name="argocd"}` in Loki. Prometheus scrapes
Kubernetes targets, node-exporter, and kube-state-metrics. The Collector
ships container logs to Loki and accepts application logs and metrics over
OTLP (`opentelemetry-collector.observability.svc.cluster.local:4317` for
gRPC or `http://opentelemetry-collector.observability.svc.cluster.local:4318`
for HTTP). Traces are not collected; no trace backend is installed. The
Collector, Loki, and direct access to the Prometheus Service remain internal
and unauthenticated.

Grafana, Prometheus, and Loki use k3s `local-path` volumes. Prometheus and Loki
retain up to seven days of data, with an additional 8 GB retention size limit
for Prometheus. This is a single-cluster setup without high availability or
backups; monitor node disk usage, especially for Loki, whose retention is
time-based. Deleting the k3d cluster can delete the stored data.