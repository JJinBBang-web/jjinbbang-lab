#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

SSH_KEY="${JJINBBANG_LAB_SSH_KEY:-}"
CORE_PUBLIC_IP="${CORE_PUBLIC_IP:-}"
WORKER_1_PUBLIC_IP="${WORKER_1_PUBLIC_IP:-}"
WORKER_2_PUBLIC_IP="${WORKER_2_PUBLIC_IP:-}"
ZONE_NAME="${JJINBBANG_DNS_ZONE:-jjinbbang.kr}"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "$name is required. Copy .env.example to .env and fill it first." >&2
    exit 1
  fi
}

ssh_core() {
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 ubuntu@"$CORE_PUBLIC_IP" "$@"
}

http_status() {
  local host="$1"
  local ip="$2"
  local path="$3"
  curl --max-time 10 -k -sS -o /dev/null -w '%{http_code}' \
    --resolve "$host:443:$ip" "https://$host$path"
}

redirect_target() {
  local host="$1"
  local ip="$2"
  local path="$3"
  curl --max-time 10 -k -sS -o /dev/null -w '%{redirect_url}' \
    --resolve "$host:443:$ip" "https://$host$path"
}

redact_url() {
  sed -E 's/([?&](client_id|state|code|session)=)[^&]+/\1<redacted>/g'
}

require curl
require ssh
require_env JJINBBANG_LAB_SSH_KEY
require_env CORE_PUBLIC_IP
require_env WORKER_1_PUBLIC_IP
require_env WORKER_2_PUBLIC_IP

echo "== cluster =="
ssh_core 'sudo k3s kubectl get nodes -o wide'

echo "== platform pods =="
ssh_core 'sudo k3s kubectl -n authentik get pods -o wide; sudo k3s kubectl -n n8n get pods -o wide; sudo k3s kubectl -n argocd get pods -o wide'

echo "== certificates =="
ssh_core 'sudo k3s kubectl get certificates -A; sudo k3s kubectl get challenges -A'

echo "== sso endpoints with DNS override =="
for ip in "$WORKER_1_PUBLIC_IP" "$WORKER_2_PUBLIC_IP"; do
  auth_status="$(http_status "auth.$ZONE_NAME" "$ip" "/if/flow/initial-setup/")"
  n8n_ping_status="$(http_status "n8n.$ZONE_NAME" "$ip" "/outpost.goauthentik.io/ping")"
  n8n_root_status="$(http_status "n8n.$ZONE_NAME" "$ip" "/")"
  n8n_redirect="$(redirect_target "n8n.$ZONE_NAME" "$ip" "/" | redact_url)"
  argo_status="$(http_status "argo.$ZONE_NAME" "$ip" "/")"
  argocd_oidc_status="$(http_status "auth.$ZONE_NAME" "$ip" "/application/o/argocd/.well-known/openid-configuration")"
  echo "$ip auth=$auth_status n8n_ping=$n8n_ping_status n8n_root=$n8n_root_status argo=$argo_status argocd_oidc=$argocd_oidc_status"
  echo "$ip n8n_redirect=$n8n_redirect"
done
