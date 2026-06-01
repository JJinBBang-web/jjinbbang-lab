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
ROOT_APP_PATH="${ROOT_APP_PATH:-platform/bootstrap/root-app.yaml}"
ROOT_APP_URL="${ROOT_APP_URL:-https://raw.githubusercontent.com/JJinBBang-web/jjinbbang-lab/main/$ROOT_APP_PATH}"
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

require curl
require diff
require kubectl
require ssh
require_env JJINBBANG_LAB_SSH_KEY
require_env CORE_PUBLIC_IP

remote_root="$(mktemp)"
local_platform="$(mktemp)"
trap 'rm -f "$remote_root" "$local_platform"' EXIT

echo "== preflight: local manifests =="
test -f "$ROOT_APP_PATH"
kubectl kustomize platform >"$local_platform"

echo "== preflight: remote main root app =="
if ! curl -fsSL "$ROOT_APP_URL" -o "$remote_root"; then
  echo "remote root app is not available yet: $ROOT_APP_URL" >&2
  echo "commit and merge/push this repo state to main before applying the root Application" >&2
  exit 1
fi

if ! diff -u "$ROOT_APP_PATH" "$remote_root" >/dev/null; then
  echo "remote root app differs from local $ROOT_APP_PATH" >&2
  echo "commit and merge/push the current root app to main before applying it" >&2
  exit 1
fi

echo "== preflight: live argocd =="
ssh_core 'sudo k3s kubectl get namespace argocd >/dev/null'
ssh_core 'sudo k3s kubectl get crd applications.argoproj.io >/dev/null'
ssh_core 'sudo k3s kubectl -n argocd rollout status deployment/argocd-server --timeout=60s'

if [[ "$CHECK_ONLY" == true ]]; then
  echo "root app preflight ok"
  exit 0
fi

echo "== apply root application =="
ssh_core 'cat >/tmp/jjinbbang-platform-root-app.yaml && sudo k3s kubectl apply -f /tmp/jjinbbang-platform-root-app.yaml' \
  <"$ROOT_APP_PATH"

echo "== root application status =="
ssh_core 'sudo k3s kubectl -n argocd get application jjinbbang-platform -o wide'

echo "root application applied"
