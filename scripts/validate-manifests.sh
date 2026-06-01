#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "== YAML parse =="
if python3 -c "import yaml" >/dev/null 2>&1; then
  python3 - <<'PY'
from pathlib import Path
import sys
import yaml

failed = False
for path in sorted(Path(".").rglob("*.yaml")) + sorted(Path(".").rglob("*.yml")):
    try:
        with path.open() as handle:
            list(yaml.safe_load_all(handle))
    except Exception as exc:
        failed = True
        print(f"{path}: {exc}")

if failed:
    sys.exit(1)
print("yaml parse ok")
PY
else
  ruby -ryaml -e 'ARGV.each { |path| YAML.load_stream(File.read(path)) }; puts "yaml parse ok"' \
    $(find . -name '*.yaml' -o -name '*.yml' | sort)
fi

echo "== shell syntax =="
bash -n scripts/*.sh

echo "== kubectl kustomize platform =="
kubectl kustomize platform >/tmp/jjinbbang-lab-platform.yaml

echo "== kubectl kustomize n8n =="
kubectl kustomize platform/workloads/n8n >/tmp/jjinbbang-lab-n8n.yaml

echo "== kubectl kustomize authentik =="
kubectl kustomize platform/authentik >/tmp/jjinbbang-lab-authentik.yaml

echo "== kubectl kustomize authentik bootstrap =="
kubectl kustomize platform/authentik/bootstrap >/tmp/jjinbbang-lab-authentik-bootstrap.yaml

echo "== kubectl kustomize argocd sso =="
kubectl kustomize platform/argocd/sso >/tmp/jjinbbang-lab-argocd-sso.yaml

echo "== kubectl kustomize jjinbbang-api dev =="
kubectl kustomize apps/jjinbbang-api/overlays/dev >/tmp/jjinbbang-lab-jjinbbang-api-dev.yaml

echo "== kubectl kustomize jjinbbang-api prod =="
kubectl kustomize apps/jjinbbang-api/overlays/prod >/tmp/jjinbbang-lab-jjinbbang-api-prod.yaml

echo "== kubectl kustomize app applications =="
kubectl kustomize platform/applications/apps >/tmp/jjinbbang-lab-applications-apps.yaml

echo "validation ok"
