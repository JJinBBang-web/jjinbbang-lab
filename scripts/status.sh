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
ROOT_APP_URL="${ROOT_APP_URL:-https://raw.githubusercontent.com/JJinBBang-web/jjinbbang-lab/main/platform/bootstrap/root-app.yaml}"
FAILED=false
ROOT_CHECK_LOG="$(mktemp)"
SSO_CHECK_LOG="$(mktemp)"
trap 'rm -f "$ROOT_CHECK_LOG" "$SSO_CHECK_LOG"' EXIT

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

section() {
  printf '\n== %s ==\n' "$1"
}

mark_failed() {
  FAILED=true
}

ssh_core() {
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 ubuntu@"$CORE_PUBLIC_IP" "$@"
}

require curl
require dig
require git
require ssh
require_env JJINBBANG_LAB_SSH_KEY
require_env CORE_PUBLIC_IP

section "repo"
echo "branch: $(git branch --show-current)"
git status --short --branch
remote_status="$(curl -sS -o /dev/null -w '%{http_code}' "$ROOT_APP_URL" || true)"
echo "remote root app on main: HTTP $remote_status"
if [[ "$remote_status" != "200" ]]; then
  echo "pending: root app manifest is not visible on GitHub main"
  mark_failed
fi

section "dns"
if ./scripts/check-dns.sh; then
  echo "dns: ok"
else
  echo "dns: pending"
  mark_failed
fi

section "cluster"
if ssh_core 'sudo k3s kubectl get nodes --no-headers'; then
  :
else
  echo "cluster: unable to read nodes"
  mark_failed
fi

section "certificates"
if ssh_core 'sudo k3s kubectl get certificates -A'; then
  :
else
  echo "certificates: unable to read certificate status"
  mark_failed
fi

section "applications"
if ssh_core 'sudo k3s kubectl -n argocd get applications.argoproj.io 2>/dev/null || true'; then
  :
else
  echo "applications: unable to read Argo CD applications"
  mark_failed
fi

section "guarded gates"
if ./scripts/apply-root-app.sh --check >"$ROOT_CHECK_LOG" 2>&1; then
  echo "root app preflight: ok"
else
  echo "root app preflight: pending"
  sed 's/^/  /' "$ROOT_CHECK_LOG"
  mark_failed
fi

if ./scripts/apply-argocd-sso.sh --check >"$SSO_CHECK_LOG" 2>&1; then
  echo "argocd sso preflight: ok"
else
  echo "argocd sso preflight: pending"
  sed 's/^/  /' "$SSO_CHECK_LOG"
  mark_failed
fi

if [[ "$FAILED" == true ]]; then
  echo
  echo "status: pending"
  exit 1
fi

echo
echo "status: ready"
