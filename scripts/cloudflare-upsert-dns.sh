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
API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
ZONE_ID="${CLOUDFLARE_ZONE_ID:-}"
WORKER_1_PUBLIC_IP="${WORKER_1_PUBLIC_IP:-}"
WORKER_2_PUBLIC_IP="${WORKER_2_PUBLIC_IP:-}"
read -r -a RECORDS <<<"${JJINBBANG_DNS_RECORDS:-auth argo n8n}"
ALLOW_API_CUTOVER="${ALLOW_API_CUTOVER:-false}"

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

TARGET_IPS=("$WORKER_1_PUBLIC_IP" "$WORKER_2_PUBLIC_IP")
require_env WORKER_1_PUBLIC_IP
require_env WORKER_2_PUBLIC_IP

for record in "${RECORDS[@]}"; do
  if [[ "$record" == "api" && "$ALLOW_API_CUTOVER" != "true" ]]; then
    echo "refusing to update api.$ZONE_NAME without ALLOW_API_CUTOVER=true" >&2
    exit 1
  fi
done

cf() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  if [[ -n "$data" ]]; then
    curl -fsS -X "$method" "https://api.cloudflare.com/client/v4$path" \
      -H "Authorization: Bearer $API_TOKEN" \
      -H "Content-Type: application/json" \
      --data "$data"
  else
    curl -fsS -X "$method" "https://api.cloudflare.com/client/v4$path" \
      -H "Authorization: Bearer $API_TOKEN" \
      -H "Content-Type: application/json"
  fi
}

require curl
require jq

if [[ -z "$API_TOKEN" || "$API_TOKEN" == REPLACE_* ]]; then
  echo "CLOUDFLARE_API_TOKEN is required" >&2
  exit 1
fi

if [[ -z "$ZONE_ID" ]]; then
  ZONE_ID="$(cf GET "/zones?name=$ZONE_NAME" | jq -r '.result[0].id // empty')"
fi

if [[ -z "$ZONE_ID" ]]; then
  echo "Cloudflare zone not found: $ZONE_NAME" >&2
  exit 1
fi

for record in "${RECORDS[@]}"; do
  fqdn="$record.$ZONE_NAME"
  existing="$(cf GET "/zones/$ZONE_ID/dns_records?type=A&name=$fqdn")"
  for ip in "${TARGET_IPS[@]}"; do
    record_id="$(jq -r --arg ip "$ip" '.result[] | select(.content == $ip) | .id' <<<"$existing" | head -n 1)"
    payload="$(jq -nc --arg type A --arg name "$fqdn" --arg content "$ip" \
      '{type:$type,name:$name,content:$content,ttl:1,proxied:false}')"
    if [[ -n "$record_id" ]]; then
      cf PATCH "/zones/$ZONE_ID/dns_records/$record_id" "$payload" >/dev/null
      echo "updated $fqdn A $ip"
    else
      cf POST "/zones/$ZONE_ID/dns_records" "$payload" >/dev/null
      echo "created $fqdn A $ip"
    fi
  done
done

echo "done"
