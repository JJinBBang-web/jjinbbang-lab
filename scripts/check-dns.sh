#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

ZONE_NAME="${JJINBBANG_DNS_ZONE:-jjinbbang.kr}"
WORKER_1_PUBLIC_IP="${WORKER_1_PUBLIC_IP:-}"
WORKER_2_PUBLIC_IP="${WORKER_2_PUBLIC_IP:-}"
read -r -a RECORDS <<<"${JJINBBANG_DNS_RECORDS:-auth argo n8n}"
ALLOW_API_CUTOVER="${ALLOW_API_CUTOVER:-false}"
DNS_SERVER="${DNS_SERVER:-}"

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

join_sorted() {
  sort -u | paste -sd ',' -
}

port_open() {
  local ip="$1"
  local port="$2"
  nc -z -G 3 "$ip" "$port" >/dev/null 2>&1 || nc -z -w 3 "$ip" "$port" >/dev/null 2>&1
}

require dig
require nc
require_env WORKER_1_PUBLIC_IP
require_env WORKER_2_PUBLIC_IP

EXPECTED_IPS=("$WORKER_1_PUBLIC_IP" "$WORKER_2_PUBLIC_IP")
expected="$(printf '%s\n' "${EXPECTED_IPS[@]}" | join_sorted)"
dig_args=()
if [[ -n "$DNS_SERVER" ]]; then
  dig_args+=("@$DNS_SERVER")
fi

echo "== nameservers =="
ns="$(dig "${dig_args[@]}" +short NS "$ZONE_NAME" | join_sorted)"
echo "$ns"
if [[ "$ns" != *"ns.cloudflare.com"* ]]; then
  echo "warning: $ZONE_NAME is not delegated to Cloudflare nameservers yet" >&2
fi

echo "== A records =="
failed=false
for record in "${RECORDS[@]}"; do
  if [[ "$record" == "api" && "$ALLOW_API_CUTOVER" != "true" ]]; then
    echo "warning: checking api.$ZONE_NAME without ALLOW_API_CUTOVER=true; existing production DNS may differ" >&2
  fi

  fqdn="$record.$ZONE_NAME"
  actual="$(dig "${dig_args[@]}" +short A "$fqdn" | join_sorted)"
  echo "$fqdn -> ${actual:-<empty>}"
  if [[ "$actual" != "$expected" ]]; then
    echo "mismatch: expected $expected" >&2
    failed=true
  fi
done

echo "== edge ports =="
for ip in "${EXPECTED_IPS[@]}"; do
  for port in 80 443; do
    if port_open "$ip" "$port"; then
      echo "$ip:$port open"
    else
      echo "$ip:$port closed" >&2
      failed=true
    fi
  done
done

if [[ "$failed" == true ]]; then
  exit 1
fi

echo "dns check ok"
