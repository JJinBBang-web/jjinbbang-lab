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
ZONE_NAME="${JJINBBANG_DNS_ZONE:-jjinbbang.kr}"
CERT_WAIT_TIMEOUT="${CERT_WAIT_TIMEOUT:-600s}"

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

expect_https() {
  local url="$1"
  local expected="$2"
  local host
  local ip
  local status
  local curl_args=(--max-time 15 -sS -o /dev/null -w '%{http_code}')
  host="${url#https://}"
  host="${host%%/*}"
  if [[ -n "${DNS_SERVER:-}" ]]; then
    ip="$(dig "@$DNS_SERVER" +short A "$host" | head -n 1)"
    if [[ -z "$ip" ]]; then
      echo "https check failed: $host did not resolve via $DNS_SERVER" >&2
      return 1
    fi
    curl_args+=(--resolve "$host:443:$ip")
  fi
  status="$(curl "${curl_args[@]}" "$url")"
  if [[ "$status" != "$expected" ]]; then
    echo "https check failed: $url -> $status expected $expected" >&2
    return 1
  fi
  echo "$url -> $status"
}

require curl
require dig
require ssh
require_env JJINBBANG_LAB_SSH_KEY
require_env CORE_PUBLIC_IP

echo "== dns =="
./scripts/check-dns.sh

echo "== wait certificates =="
ssh_core "sudo k3s kubectl -n authentik wait --for=condition=Ready certificate/authentik-public-tls --timeout='$CERT_WAIT_TIMEOUT'"
ssh_core "sudo k3s kubectl -n argocd wait --for=condition=Ready certificate/argocd-public-tls --timeout='$CERT_WAIT_TIMEOUT'"
ssh_core "sudo k3s kubectl -n n8n wait --for=condition=Ready certificate/n8n-public-tls --timeout='$CERT_WAIT_TIMEOUT'"

echo "== public endpoints =="
expect_https "https://auth.$ZONE_NAME/if/flow/initial-setup/" 200
expect_https "https://auth.$ZONE_NAME/application/o/argocd/.well-known/openid-configuration" 200
expect_https "https://n8n.$ZONE_NAME/outpost.goauthentik.io/ping" 204
expect_https "https://n8n.$ZONE_NAME/" 302
expect_https "https://argo.$ZONE_NAME/" 200

echo "== argocd sso preflight =="
./scripts/apply-argocd-sso.sh --check

echo "post-dns readiness ok"
