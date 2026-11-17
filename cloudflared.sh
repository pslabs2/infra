#!/usr/bin/env bash
#
# cloudflared.sh — manage the Cloudflare Tunnel that exposes Traefik publicly.
#
# Everything on the Cloudflare side is driven through the Cloudflare API:
# the remotely-managed tunnel, its public hostnames (all routed to Traefik,
# which routes on the Host header), the proxied DNS records and, optionally,
# a Cloudflare Access login in front of a hostname. The cloudflared
# Deployment itself lives in Git (infrastructure/cloudflared/) and only needs
# the tunnel token Secret created here. Kubernetes Ingresses stay in Git too.
#
# Usage:
#   ./cloudflared.sh [command] [args]
#
#   tunnel                     create the tunnel if missing, print its ID
#   secret                     create or update the tunnel token Secret (default)
#   publish HOST [options]     route https://HOST through the tunnel to Traefik
#       --service URL          origin (default: $TRAEFIK_SERVICE)
#       --access EMAILS        protect with Cloudflare Access; comma-separated
#                              emails and/or @domains allowed to log in
#   unpublish HOST             remove the route, DNS record and Access app
#   list                       show the tunnel's public hostnames
#   verify [HOST]              request https://HOST until it answers through the
#                              tunnel (default: global.domain of ArgoCD)
#
# Configuration (environment, or a git-ignored .env next to this script;
# missing values are prompted for when run interactively):
#   CLOUDFLARE_API_TOKEN     API token, permissions:
#                              Account > Cloudflare Tunnel > Edit
#                              Zone    > DNS > Edit, Zone > Read
#                              Account > Access: Apps and Policies > Edit (--access)
#   CLOUDFLARE_ACCOUNT_ID    Cloudflare account ID
#   CLOUDFLARE_TUNNEL_NAME   tunnel name                 (default: $CLUSTER_NAME)
#   CLOUDFLARE_TUNNEL_TOKEN  optional; if set, 'secret' uses it instead of the API
#   TRAEFIK_SERVICE          default origin  (default: http://traefik.traefik.svc.cluster.local:80)
#   CLUSTER_NAME             k3d cluster name            (default: homelab)
#   VERIFY_TIMEOUT           seconds to wait in 'verify' (default: 180)
#   FORCE                    set to 1 to overwrite a DNS CNAME pointing elsewhere

set -euo pipefail
shopt -s inherit_errexit

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${ROOT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "${ROOT_DIR}/.env"
  set +a
fi

CLUSTER_NAME="${CLUSTER_NAME:-homelab}"
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-180}"
CLOUDFLARE_TUNNEL_NAME="${CLOUDFLARE_TUNNEL_NAME:-$CLUSTER_NAME}"
TRAEFIK_SERVICE="${TRAEFIK_SERVICE:-http://traefik.traefik.svc.cluster.local:80}"
FORCE="${FORCE:-0}"

KUBE_CONTEXT="k3d-${CLUSTER_NAME}"
NAMESPACE="cloudflared"
SECRET="cloudflared-token"
VALUES_FILE="${ROOT_DIR}/bootstrap/argocd-values.yaml"
CF_API="https://api.cloudflare.com/client/v4"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

kc() { kubectl --context "$KUBE_CONTEXT" "$@"; }

require() {
  local bin
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || die "'$bin' is required but not installed"
  done
}

# prompt VAR "description" [secret] — fill VAR from the terminal if it is empty.
prompt() {
  local -n _ref="$1"
  local desc="$2" hidden="${3:-}" value=""
  [[ -n "${_ref:-}" ]] && return 0
  [[ -t 0 ]] || die "$1 is not set (export it, or put it in ${ROOT_DIR}/.env)"
  if [[ -n "$hidden" ]]; then
    read -r -s -p "${desc}: " value; echo >&2
  else
    read -r -p "${desc}: " value
  fi
  [[ -n "$value" ]] || die "$1 is required"
  _ref="$value"
}

cf_init() {
  require curl jq
  prompt CLOUDFLARE_API_TOKEN "Cloudflare API token" hidden
  prompt CLOUDFLARE_ACCOUNT_ID "Cloudflare account ID"
}

# cf METHOD PATH [JSON] — call the Cloudflare API and print .result.
cf() {
  local method="$1" path="$2" data="${3:-}" body
  local args=(-sS -X "$method" "${CF_API}${path}"
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"
    -H "Content-Type: application/json")
  [[ -n "$data" ]] && args+=(--data "$data")
  body="$(curl "${args[@]}")" || die "Cloudflare API request failed: ${method} ${path}"
  if [[ "$(jq -r '.success // false' <<<"$body" 2>/dev/null)" != "true" ]]; then
    die "Cloudflare API ${method} ${path}: $(jq -c '.errors // .' <<<"$body" 2>/dev/null || echo "$body")"
  fi
  jq -c '.result' <<<"$body"
}

acct() { printf '/accounts/%s' "$CLOUDFLARE_ACCOUNT_ID"; }

uri() { jq -rn --arg v "$1" '$v|@uri'; }

valid_host() {
  [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] \
    || die "'$1' is not a valid hostname"
}

# Prints the tunnel ID, creating a remotely-managed tunnel if none exists.
ensure_tunnel() {
  local tunnels id
  tunnels="$(cf GET "$(acct)/cfd_tunnel?is_deleted=false&name=$(uri "$CLOUDFLARE_TUNNEL_NAME")")"
  id="$(jq -r --arg n "$CLOUDFLARE_TUNNEL_NAME" '[.[] | select(.name == $n)][0].id // empty' <<<"$tunnels")"
  if [[ -z "$id" ]]; then
    log "Creating tunnel '${CLOUDFLARE_TUNNEL_NAME}'"
    id="$(cf POST "$(acct)/cfd_tunnel" \
      "$(jq -cn --arg n "$CLOUDFLARE_TUNNEL_NAME" '{name: $n, config_src: "cloudflare"}')" \
      | jq -r '.id')"
  elif [[ "$(jq -r --arg id "$id" '.[] | select(.id == $id) | .remote_config' <<<"$tunnels")" != "true" ]]; then
    die "Tunnel '${CLOUDFLARE_TUNNEL_NAME}' is locally managed (config file); migrate it to remote management in the dashboard first"
  fi
  [[ -n "$id" && "$id" != "null" ]] || die "Could not determine the tunnel ID"
  echo "$id"
}

# Prints the zone ID that owns HOST, trying each parent domain in turn.
zone_for() {
  local name="$1" id
  while [[ "$name" == *.* ]]; do
    id="$(cf GET "/zones?name=$(uri "$name")&account.id=${CLOUDFLARE_ACCOUNT_ID}" | jq -r '.[0].id // empty')"
    [[ -n "$id" ]] && { echo "$id"; return 0; }
    name="${name#*.}"
  done
  die "No Cloudflare zone in this account covers '$1'"
}

tunnel_config() { cf GET "$(acct)/cfd_tunnel/$1/configurations" | jq -c '.config // {}'; }

# put_ingress TUNNEL_ID CONFIG RULES — write RULES (hostname rules only) back,
# keeping other config keys and ending with the mandatory catch-all rule.
put_ingress() {
  local payload
  payload="$(jq -cn --argjson cfg "$2" --argjson rules "$3" \
    '{config: ($cfg + {ingress: ($rules + [{service: "http_status:404"}])})}')"
  cf PUT "$(acct)/cfd_tunnel/$1/configurations" "$payload" >/dev/null
}

ensure_dns() {
  local zone="$1" host="$2" target="$3" records rec_id rec_type rec_content payload
  payload="$(jq -cn --arg n "$host" --arg c "$target" \
    '{type: "CNAME", name: $n, content: $c, proxied: true, comment: "Cloudflare Tunnel (cloudflared.sh)"}')"
  records="$(cf GET "/zones/${zone}/dns_records?name=$(uri "$host")")"
  rec_id="$(jq -r '.[0].id // empty' <<<"$records")"
  rec_type="$(jq -r '.[0].type // empty' <<<"$records")"
  rec_content="$(jq -r '.[0].content // empty' <<<"$records")"

  if [[ -z "$rec_id" ]]; then
    log "Creating DNS record ${host} -> ${target}"
    cf POST "/zones/${zone}/dns_records" "$payload" >/dev/null
  elif [[ "$rec_type" == "CNAME" && "$rec_content" == "$target" \
          && "$(jq -r '.[0].proxied' <<<"$records")" == "true" ]]; then
    log "DNS record ${host} already points at the tunnel"
  elif [[ "$rec_type" == "CNAME" && ( "$rec_content" == *.cfargotunnel.com || "$FORCE" == "1" ) ]]; then
    log "Updating DNS record ${host} (${rec_content} -> ${target})"
    cf PUT "/zones/${zone}/dns_records/${rec_id}" "$payload" >/dev/null
  else
    die "${host} already has a conflicting ${rec_type} record (${rec_content}); remove it, or set FORCE=1 to overwrite a CNAME"
  fi
}

access_app_id() {
  cf GET "$(acct)/access/apps?domain=$(uri "$1")&exact=true" \
    | jq -r --arg d "$1" '[.[] | select(.domain == $d)][0].id // empty'
}

ensure_access() {
  local host="$1" emails="$2" include policy_id app_id
  app_id="$(access_app_id "$host")"
  if [[ -n "$app_id" ]]; then
    log "Access application for ${host} already exists — leaving its policies unchanged"
    return 0
  fi
  include="$(jq -cn --arg e "$emails" '
    [$e | split(",")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0)
     | if startswith("@") then {email_domain: {domain: .[1:]}} else {email: {email: .}} end]')"
  [[ "$(jq 'length' <<<"$include")" -gt 0 ]] || die "--access needs at least one email or @domain"

  log "Creating Access policy and application for ${host}"
  policy_id="$(cf POST "$(acct)/access/policies" "$(jq -cn --arg n "${host} allow" --argjson i "$include" \
    '{name: $n, decision: "allow", include: $i}')" | jq -r '.id')"
  cf POST "$(acct)/access/apps" "$(jq -cn --arg h "$host" --arg p "$policy_id" \
    '{name: $h, domain: $h, type: "self_hosted", session_duration: "24h",
      policies: [{id: $p, precedence: 1}]}')" >/dev/null
}

remove_access() {
  local host="$1" app_id policy_ids id
  app_id="$(access_app_id "$host")"
  [[ -n "$app_id" ]] || return 0
  log "Deleting Access application for ${host}"
  cf DELETE "$(acct)/access/apps/${app_id}" >/dev/null
  # Only the reusable policy publish created, matched by its name.
  policy_ids="$(cf GET "$(acct)/access/policies?per_page=100" \
    | jq -r --arg n "${host} allow" '.[] | select(.name == $n) | .id')"
  for id in $policy_ids; do
    cf DELETE "$(acct)/access/policies/${id}" >/dev/null || warn "Could not delete Access policy ${id}"
  done
}

tunnel_cmd() {
  cf_init
  local id
  id="$(ensure_tunnel)"
  log "Tunnel '${CLOUDFLARE_TUNNEL_NAME}': ${id}"
  echo "$id"
}

secret() {
  require kubectl
  kc cluster-info >/dev/null 2>&1 \
    || die "Cannot reach context '${KUBE_CONTEXT}' — run ./cluster.sh first"

  local token="${CLOUDFLARE_TUNNEL_TOKEN:-}"
  if [[ -z "$token" ]]; then
    cf_init
    local id
    id="$(ensure_tunnel)"
    log "Fetching token for tunnel '${CLOUDFLARE_TUNNEL_NAME}' (${id})"
    token="$(cf GET "$(acct)/cfd_tunnel/${id}/token" | jq -r '.')"
    [[ -n "$token" && "$token" != "null" ]] || die "Empty tunnel token returned"
  fi

  kc get namespace "$NAMESPACE" >/dev/null 2>&1 || kc create namespace "$NAMESPACE"

  log "Applying tunnel token Secret '${NAMESPACE}/${SECRET}'"
  kc -n "$NAMESPACE" create secret generic "$SECRET" \
    --from-literal=token="$token" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
  # The connector reads the token at start-up only.
  if kc -n "$NAMESPACE" get deployment cloudflared >/dev/null 2>&1; then
    kc -n "$NAMESPACE" rollout restart deployment/cloudflared >/dev/null
  fi
}

publish() {
  local host="" service="$TRAEFIK_SERVICE" access=""
  while (($#)); do
    case "$1" in
      --service) service="${2:-}"; shift 2 || die "--service needs a value" ;;
      --access)  access="${2:-}";  shift 2 || die "--access needs a value" ;;
      -*) die "Unknown option: $1" ;;
      *) [[ -z "$host" ]] || die "Only one hostname per publish"; host="$1"; shift ;;
    esac
  done
  cf_init
  prompt host "Public hostname (e.g. app.example.com)"
  host="${host,,}"
  valid_host "$host"
  [[ -n "$service" ]] || die "--service must not be empty"

  local id zone config rules
  id="$(ensure_tunnel)"
  zone="$(zone_for "$host")"

  # DNS first: it fails on conflicting records before the tunnel is touched.
  ensure_dns "$zone" "$host" "${id}.cfargotunnel.com"

  config="$(tunnel_config "$id")"
  rules="$(jq -c --arg h "$host" --arg s "$service" \
    '[(.ingress // [])[] | select(.hostname != null and .hostname != $h)] + [{hostname: $h, service: $s}]' \
    <<<"$config")"
  log "Routing ${host} -> ${service} on tunnel '${CLOUDFLARE_TUNNEL_NAME}'"
  put_ingress "$id" "$config" "$rules"
  [[ -n "$access" ]] && ensure_access "$host" "$access"

  log "Published https://${host}"
  log "Traefik still needs an Ingress for host '${host}' (add it in Git), then: $0 verify ${host}"
}

unpublish() {
  local host="${1:-}"
  cf_init
  prompt host "Public hostname to remove"
  host="${host,,}"
  valid_host "$host"

  local id zone config rules records rec_id
  id="$(ensure_tunnel)"
  zone="$(zone_for "$host")"

  config="$(tunnel_config "$id")"
  rules="$(jq -c --arg h "$host" '[(.ingress // [])[] | select(.hostname != null and .hostname != $h)]' <<<"$config")"
  log "Removing route for ${host}"
  put_ingress "$id" "$config" "$rules"

  records="$(cf GET "/zones/${zone}/dns_records?type=CNAME&name=$(uri "$host")")"
  rec_id="$(jq -r --arg c "${id}.cfargotunnel.com" '[.[] | select(.content == $c)][0].id // empty' <<<"$records")"
  if [[ -n "$rec_id" ]]; then
    log "Deleting DNS record ${host}"
    cf DELETE "/zones/${zone}/dns_records/${rec_id}" >/dev/null
  else
    log "No DNS record for ${host} points at this tunnel — leaving DNS unchanged"
  fi

  remove_access "$host"
  log "Unpublished ${host}"
}

list() {
  cf_init
  local id
  id="$(ensure_tunnel)"
  log "Public hostnames on tunnel '${CLOUDFLARE_TUNNEL_NAME}' (${id})"
  tunnel_config "$id" \
    | jq -r '(.ingress // [])[] | select(.hostname != null) | "  \(.hostname) -> \(.service)"'
}

# 2xx/3xx means Cloudflare reached the origin (or answered with the Access
# login redirect). 5xx — typically 502/530 — means the tunnel or route is down.
verify() {
  require curl
  local host="${1:-}"
  if [[ -z "$host" ]]; then
    host="$(awk '/^[[:space:]]+domain:/ {print $2; exit}' "$VALUES_FILE")"
    [[ -n "$host" ]] || die "No global.domain found in ${VALUES_FILE}"
  fi

  log "Checking https://${host}"
  local deadline=$((SECONDS + VERIFY_TIMEOUT)) result="" code=""
  while true; do
    result="$(curl -sS -o /dev/null --max-time 10 \
      -w '%{http_code} %{redirect_url}' "https://${host}" 2>/dev/null || true)"
    code="${result%% *}"
    if [[ "$code" =~ ^[23] ]]; then
      case "$result" in
        *cloudflareaccess.com*) log "OK — HTTP ${code}, protected by Cloudflare Access" ;;
        *) log "OK — HTTP ${code}. No Access redirect seen: ${host} is public" ;;
      esac
      return 0
    fi
    ((SECONDS < deadline)) || die "https://${host} not reachable after ${VERIFY_TIMEOUT}s (last response: ${result:-none})"
    sleep 5
  done
}

usage() { sed -n '3,38p' "$0" | sed 's/^# \{0,1\}//'; }

cmd="${1:-secret}"
(($#)) && shift
case "$cmd" in
  tunnel)    tunnel_cmd ;;
  secret)    secret ;;
  publish)   publish "$@" ;;
  unpublish) unpublish "$@" ;;
  list)      list ;;
  verify)    verify "$@" ;;
  -h|--help|help) usage ;;
  *) usage; die "Unknown command: $cmd" ;;
esac
