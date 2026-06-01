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
N8N_OWNER_EMAIL="${N8N_OWNER_EMAIL:-}"
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

require ssh
require_env JJINBBANG_LAB_SSH_KEY
require_env CORE_PUBLIC_IP

if [[ "$CHECK_ONLY" == true ]]; then
  ssh_core 'bash -s' <<'REMOTE'
set -euo pipefail

pod="$(sudo k3s kubectl -n n8n get pod -l app.kubernetes.io/name=n8n -o jsonpath="{.items[0].metadata.name}")"
email="$(sudo k3s kubectl -n n8n get secret n8n-owner-bootstrap -o jsonpath="{.data.email}" | base64 -d)"

sudo k3s kubectl -n n8n exec -i "$pod" -- env OWNER_EMAIL="$email" node - <<'NODE'
const http = require("http");

function getSettings() {
  return new Promise((resolve, reject) => {
    http.get("http://127.0.0.1:5678/rest/settings", (res) => {
      let data = "";
      res.on("data", (chunk) => data += chunk);
      res.on("end", () => resolve(JSON.parse(data)));
    }).on("error", reject);
  });
}

function requestWithForwardAuth() {
  return new Promise((resolve, reject) => {
    const req = http.request({
      hostname: "127.0.0.1",
      port: 5678,
      path: "/",
      method: "GET",
      headers: { "X-authentik-email": process.env.OWNER_EMAIL },
    }, (res) => {
      const setCookie = res.headers["set-cookie"] ?? [];
      const cookies = Array.isArray(setCookie) ? setCookie : [setCookie];
      const hasAuthCookie = cookies.some((value) => /n8n-auth|n8n_token|session/i.test(value));
      res.resume();
      resolve({ statusCode: res.statusCode, hasAuthCookie });
    });
    req.on("error", reject);
    req.end();
  });
}

(async () => {
  const settings = await getSettings();
  const showSetup = settings.data.userManagement.showSetupOnFirstLoad;
  const forwardAuth = await requestWithForwardAuth();

  console.log(`showSetupOnFirstLoad=${showSetup}`);
  console.log(`forward_auth_status=${forwardAuth.statusCode}`);
  console.log(`forward_auth_cookie=${forwardAuth.hasAuthCookie ? "present" : "missing"}`);

  if (showSetup !== false || forwardAuth.statusCode !== 200 || !forwardAuth.hasAuthCookie) {
    process.exit(1);
  }
})().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
NODE
REMOTE
  echo "n8n owner bootstrap check ok"
  exit 0
fi

if [[ -n "$N8N_OWNER_EMAIL" && "$N8N_OWNER_EMAIL" != *@* ]]; then
  echo "N8N_OWNER_EMAIL must be an email address" >&2
  exit 1
fi

if [[ -n "$N8N_OWNER_EMAIL" ]]; then
  printf -v remote_owner_email "%q" "$N8N_OWNER_EMAIL"
else
  remote_owner_email=""
fi

ssh_core "N8N_OWNER_EMAIL=$remote_owner_email bash -s" <<'REMOTE'
set -euo pipefail

if [[ -n "${N8N_OWNER_EMAIL:-}" ]]; then
  email="$N8N_OWNER_EMAIL"
else
  email="$(sudo k3s kubectl -n authentik get secret authentik-bootstrap -o jsonpath="{.data.AUTHENTIK_BOOTSTRAP_EMAIL}" | base64 -d)"
fi

case "$email" in *@*) ;; *) echo "n8n owner email is not usable" >&2; exit 1;; esac

password="$(sudo k3s kubectl -n n8n get secret n8n-owner-bootstrap -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || true)"
if [[ -z "$password" ]]; then
  password="$(openssl rand -base64 36)"
fi

sudo k3s kubectl -n n8n create secret generic n8n-owner-bootstrap \
  --from-literal=email="$email" \
  --from-literal=password="$password" \
  --dry-run=client -o yaml | sudo k3s kubectl apply -f - >/dev/null

pod="$(sudo k3s kubectl -n n8n get pod -l app.kubernetes.io/name=n8n -o jsonpath="{.items[0].metadata.name}")"
sudo k3s kubectl -n n8n exec -i "$pod" -- env OWNER_EMAIL="$email" OWNER_PASSWORD="$password" node - <<'NODE'
const http = require("http");
const payload = JSON.stringify({
  email: process.env.OWNER_EMAIL,
  firstName: "Jjinbbang",
  lastName: "Admin",
  password: process.env.OWNER_PASSWORD,
});

const req = http.request({
  hostname: "127.0.0.1",
  port: 5678,
  path: "/rest/owner/setup",
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(payload),
  },
}, (res) => {
  let data = "";
  res.on("data", (chunk) => data += chunk);
  res.on("end", () => {
    if (res.statusCode === 200) {
      console.log("owner_setup=ok");
      return;
    }
    if (res.statusCode === 400 && data.includes("Instance owner already setup")) {
      console.log("owner_setup=already_present");
      return;
    }
    console.error(`owner_setup_status=${res.statusCode}`);
    console.error(data.slice(0, 500));
    process.exit(1);
  });
});
req.on("error", (error) => {
  console.error(error.message);
  process.exit(1);
});
req.write(payload);
req.end();
NODE
REMOTE

"$0" --check
