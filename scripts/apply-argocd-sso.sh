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
DNS_SERVER="${DNS_SERVER:-}"
CHECK_ONLY=false

if [[ "${1:-}" == "--check" ]]; then
  CHECK_ONLY=true
fi

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

join_sorted() {
  sort -u | paste -sd ',' -
}

expect_dns() {
  local host="$1"
  local expected
  local actual
  expected="$(printf '%s\n' "$WORKER_1_PUBLIC_IP" "$WORKER_2_PUBLIC_IP" | join_sorted)"
  if [[ -n "$DNS_SERVER" ]]; then
    actual="$(dig "@$DNS_SERVER" +short A "$host" | join_sorted)"
  else
    actual="$(dig +short A "$host" | join_sorted)"
  fi
  if [[ "$actual" != "$expected" ]]; then
    echo "dns not ready: $host -> ${actual:-<empty>} expected $expected" >&2
    return 1
  fi
}

expect_https() {
  local url="$1"
  local expected="$2"
  local host
  local ip
  local status
  local curl_args=(--max-time 10 -sS -o /dev/null -w '%{http_code}')
  host="${url#https://}"
  host="${host%%/*}"
  if [[ -n "$DNS_SERVER" ]]; then
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
}

expect_certificate_ready() {
  local namespace="$1"
  local name="$2"
  local ready
  ready="$(ssh_core "sudo k3s kubectl -n '$namespace' get certificate '$name' -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'")"
  if [[ "$ready" != "True" ]]; then
    echo "certificate not ready: $namespace/$name -> ${ready:-<empty>}" >&2
    return 1
  fi
}

sync_argocd_oidc_secret() {
  ssh_core 'bash -s' <<'REMOTE'
set -euo pipefail

client_secret="$(sudo k3s kubectl -n argocd get secret argocd-oidc-secret -o jsonpath="{.data.clientSecret}")"
sudo k3s kubectl -n argocd patch secret argocd-secret --type merge \
  -p "{\"data\":{\"oidc.authentik.clientSecret\":\"$client_secret\"}}" >/dev/null
REMOTE
}

expect_argocd_oidc_secret_resolvable() {
  ssh_core 'bash -s' <<'REMOTE'
set -euo pipefail

source_secret="$(sudo k3s kubectl -n argocd get secret argocd-oidc-secret -o jsonpath="{.data.clientSecret}" | base64 -d | sha256sum | awk "{print \$1}")"
resolved_secret="$(sudo k3s kubectl -n argocd get secret argocd-secret -o jsonpath="{.data.oidc\\.authentik\\.clientSecret}" 2>/dev/null | base64 -d | sha256sum | awk "{print \$1}")"

if [[ -z "$resolved_secret" || "$source_secret" != "$resolved_secret" ]]; then
  echo "argocd-secret/oidc.authentik.clientSecret is missing or does not match argocd-oidc-secret/clientSecret" >&2
  exit 1
fi
REMOTE
}

require curl
require dig
require kubectl
require ssh
require_env JJINBBANG_LAB_SSH_KEY
require_env CORE_PUBLIC_IP
require_env WORKER_1_PUBLIC_IP
require_env WORKER_2_PUBLIC_IP

echo "== preflight: dns =="
expect_dns "auth.$ZONE_NAME"
expect_dns "argo.$ZONE_NAME"
expect_dns "n8n.$ZONE_NAME"

echo "== preflight: tls certificates =="
expect_certificate_ready authentik authentik-public-tls
expect_certificate_ready argocd argocd-public-tls
expect_certificate_ready n8n n8n-public-tls

echo "== preflight: kubernetes secrets =="
ssh_core 'sudo k3s kubectl -n argocd get secret argocd-oidc-secret >/dev/null'
ssh_core 'sudo k3s kubectl -n authentik get secret authentik-sso-bootstrap >/dev/null'
if [[ "$CHECK_ONLY" == true ]]; then
  expect_argocd_oidc_secret_resolvable
fi

echo "== preflight: public oidc =="
expect_https "https://auth.$ZONE_NAME/application/o/argocd/.well-known/openid-configuration" 200

echo "== preflight: render overlay =="
kubectl kustomize platform/argocd/sso >/tmp/jjinbbang-lab-argocd-sso.yaml

if [[ "$CHECK_ONLY" == true ]]; then
  echo "argocd sso preflight ok"
  exit 0
fi

echo "== sync argocd oidc secret =="
sync_argocd_oidc_secret

echo "== apply argocd sso overlay =="
ssh_core 'cat >/tmp/jjinbbang-lab-argocd-sso.yaml && sudo k3s kubectl apply -f /tmp/jjinbbang-lab-argocd-sso.yaml' \
  </tmp/jjinbbang-lab-argocd-sso.yaml

echo "== restart argocd-server =="
ssh_core 'sudo k3s kubectl -n argocd rollout restart deployment/argocd-server'
ssh_core 'sudo k3s kubectl -n argocd rollout status deployment/argocd-server --timeout=180s'

echo "== verify argocd public endpoint =="
expect_https "https://argo.$ZONE_NAME/" 200

echo "argocd sso overlay applied"
