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
HOSTED_ZONE_ID="${ROUTE53_HOSTED_ZONE_ID:-}"
AWS_PROFILE_ARG=()
WORKER_1_PUBLIC_IP="${WORKER_1_PUBLIC_IP:-}"
WORKER_2_PUBLIC_IP="${WORKER_2_PUBLIC_IP:-}"
read -r -a RECORDS <<<"${JJINBBANG_DNS_RECORDS:-auth argo n8n}"
ALLOW_API_CUTOVER="${ALLOW_API_CUTOVER:-false}"

if [[ -n "${AWS_PROFILE:-}" ]]; then
  AWS_PROFILE_ARG=(--profile "$AWS_PROFILE")
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

TARGET_IPS=("$WORKER_1_PUBLIC_IP" "$WORKER_2_PUBLIC_IP")
require_env WORKER_1_PUBLIC_IP
require_env WORKER_2_PUBLIC_IP

for record in "${RECORDS[@]}"; do
  if [[ "$record" == "api" && "$ALLOW_API_CUTOVER" != "true" ]]; then
    echo "refusing to update api.$ZONE_NAME without ALLOW_API_CUTOVER=true" >&2
    exit 1
  fi
done

require aws
require jq

if [[ -z "$HOSTED_ZONE_ID" ]]; then
  HOSTED_ZONE_ID="$(aws "${AWS_PROFILE_ARG[@]}" route53 list-hosted-zones-by-name \
    --dns-name "$ZONE_NAME" \
    --output json | jq -r --arg name "$ZONE_NAME." \
    '.HostedZones[] | select(.Name == $name) | .Id' | head -n 1)"
  HOSTED_ZONE_ID="${HOSTED_ZONE_ID#/hostedzone/}"
fi

if [[ -z "$HOSTED_ZONE_ID" || "$HOSTED_ZONE_ID" == "None" ]]; then
  echo "Route53 hosted zone not found for $ZONE_NAME" >&2
  exit 1
fi

changes="$(mktemp)"
trap 'rm -f "$changes"' EXIT

jq -n '{Changes: []}' >"$changes"

for record in "${RECORDS[@]}"; do
  fqdn="$record.$ZONE_NAME."
  rr_values="$(printf '%s\n' "${TARGET_IPS[@]}" | jq -R '{Value: .}' | jq -s '.')"
  tmp="$(mktemp)"
  jq --arg name "$fqdn" --argjson rr_values "$rr_values" \
    '.Changes += [{
      Action: "UPSERT",
      ResourceRecordSet: {
        Name: $name,
        Type: "A",
        TTL: 300,
        ResourceRecords: $rr_values
      }
    }]' "$changes" >"$tmp"
  mv "$tmp" "$changes"
done

aws "${AWS_PROFILE_ARG[@]}" route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch "file://$changes"

echo "submitted Route53 UPSERT for ${RECORDS[*]} in $ZONE_NAME"
