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
DNS_FORWARDERS="${DNS_FORWARDERS:-1.1.1.1 8.8.8.8}"
MODE="${1:-apply}"
RESTORE_BACKUP="${2:-}"

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

require ssh
require_env JJINBBANG_LAB_SSH_KEY
require_env CORE_PUBLIC_IP

case "$MODE" in
  --check|check)
    ssh_core "sudo k3s kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' | grep -E '^[[:space:]]*forward \\. '"
    ;;
  --restore|restore)
    if [[ -z "$RESTORE_BACKUP" ]]; then
      echo "usage: $0 --restore /tmp/coredns-before-YYYYMMDD-HHMMSS.yaml" >&2
      exit 1
    fi
    ssh_core "test -f '$RESTORE_BACKUP'"
    ssh_core "sudo k3s kubectl apply -f '$RESTORE_BACKUP'"
    ssh_core "sudo k3s kubectl -n kube-system rollout restart deployment/coredns"
    ssh_core "sudo k3s kubectl -n kube-system rollout status deployment/coredns --timeout=120s"
    ;;
  apply|"")
    ssh_core "DNS_FORWARDERS='$DNS_FORWARDERS' bash -s" <<'REMOTE'
set -euo pipefail

command -v jq >/dev/null 2>&1 || {
  echo "remote host is missing jq" >&2
  exit 1
}

ts=$(date +%Y%m%d-%H%M%S)
backup="/tmp/coredns-before-${ts}.yaml"
sudo k3s kubectl -n kube-system get configmap coredns -o yaml > "$backup"

corefile=$(
  sudo k3s kubectl -n kube-system get configmap coredns -o json |
    jq -r '.data.Corefile' |
    sed -E "s#^([[:space:]]*)forward \\. .*\$#\\1forward . ${DNS_FORWARDERS}#"
)
patch=$(jq -n --arg corefile "$corefile" '{data:{Corefile:$corefile}}')

sudo k3s kubectl -n kube-system patch configmap coredns --type=merge -p "$patch"
sudo k3s kubectl -n kube-system rollout restart deployment/coredns
sudo k3s kubectl -n kube-system rollout status deployment/coredns --timeout=120s

echo "backup: $backup"
REMOTE
    ;;
  *)
    echo "usage: $0 [--check|--restore BACKUP]" >&2
    exit 1
    ;;
esac
