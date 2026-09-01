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
skip_parts = {".git", ".omo", "node_modules"}
for path in sorted(Path(".").rglob("*.yaml")) + sorted(Path(".").rglob("*.yml")):
    if any(part in skip_parts for part in path.parts):
        continue
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
    $(find . \( -path './.git' -o -path './.omo' -o -path './node_modules' \) -prune -o \( -name '*.yaml' -o -name '*.yml' \) -print | sort)
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

echo "== authentik administrator account policy =="
./scripts/test-authentik-admin-account-policy.sh

echo "== kubectl kustomize argocd sso =="
kubectl kustomize platform/argocd/sso >/tmp/jjinbbang-lab-argocd-sso.yaml

echo "== kubectl kustomize jjinbbang-api dev =="
kubectl kustomize apps/jjinbbang-api/overlays/dev >/tmp/jjinbbang-lab-jjinbbang-api-dev.yaml

echo "== kubectl kustomize jjinbbang-api prod =="
kubectl kustomize apps/jjinbbang-api/overlays/prod >/tmp/jjinbbang-lab-jjinbbang-api-prod.yaml

echo "== kubectl kustomize jjinbbang-api legacy =="
kubectl kustomize apps/jjinbbang-api/overlays/legacy >/tmp/jjinbbang-lab-jjinbbang-api-legacy.yaml

echo "== jjinbbang-api runtime contract =="
ruby -ryaml -e '
  manifests = YAML.load_stream(File.read(ARGV.fetch(0)))
  deployment = manifests.find { |doc| doc.is_a?(Hash) && doc["kind"] == "Deployment" && doc.dig("metadata", "name") == "jjinbbang-api" }
  path = deployment&.dig("spec", "template", "spec", "containers", 0, "startupProbe", "httpGet", "path")
  automount = deployment&.dig("spec", "template", "spec", "automountServiceAccountToken")
  seccomp = deployment&.dig("spec", "template", "spec", "securityContext", "seccompProfile", "type")
  abort "startup probe must use /actuator/health/liveness, got #{path.inspect}" unless path == "/actuator/health/liveness"
  abort "service account token automount must be false, got #{automount.inspect}" unless automount == false
  abort "pod seccomp profile must be RuntimeDefault, got #{seccomp.inspect}" unless seccomp == "RuntimeDefault"
' /tmp/jjinbbang-lab-jjinbbang-api-legacy.yaml

echo "== kubectl kustomize jjinbbang-admin dev =="
kubectl kustomize apps/jjinbbang-admin/overlays/dev >/tmp/jjinbbang-lab-jjinbbang-admin-dev.yaml

echo "== kubectl kustomize jjinbbang-admin prod =="
kubectl kustomize apps/jjinbbang-admin/overlays/prod >/tmp/jjinbbang-lab-jjinbbang-admin-prod.yaml

echo "== kubectl kustomize jjinbbang-admin compatibility path =="
kubectl kustomize apps/jjinbbang-admin >/tmp/jjinbbang-lab-jjinbbang-admin.yaml

echo "== jjinbbang-admin web runtime contract =="
ruby -ryaml -e '
  rendered_manifests = {
    "dev" => YAML.load_stream(File.read(ARGV.fetch(0))),
    "prod" => YAML.load_stream(File.read(ARGV.fetch(1))),
    "compatibility" => YAML.load_stream(File.read(ARGV.fetch(2)))
  }
  missing = []

  rendered_manifests.each do |environment, manifests|
    if manifests.empty?
      missing << "#{environment}: rendered manifests are empty"
      next
    end

    web_deployment = manifests.find do |doc|
      doc.is_a?(Hash) && doc["kind"] == "Deployment" && doc.dig("metadata", "name") == "jjinbbang-admin-web"
    end
    web_service = manifests.find do |doc|
      doc.is_a?(Hash) && doc["kind"] == "Service" && doc.dig("metadata", "name") == "jjinbbang-admin-web"
    end
    ingress = manifests.find do |doc|
      doc.is_a?(Hash) && doc["kind"] == "Ingress" && doc.dig("metadata", "name") == "jjinbbang-admin"
    end
    ingress_paths = ingress&.dig("spec", "rules")&.flat_map { |rule| rule.dig("http", "paths") || [] } || []

    missing << "#{environment}: web Deployment missing" unless web_deployment
    missing << "#{environment}: web Service missing" unless web_service
    missing << "#{environment}: web Ingress path / missing" unless ingress_paths.any? { |path| path["path"] == "/" }

    next unless ["dev", "prod"].include?(environment)

   web_image = web_deployment&.dig("spec", "template", "spec", "containers", 0, "image")
   missing << "#{environment}: web image missing" if web_image.to_s.strip.empty?

    ["jjinbbang-admin-web", "jjinbbang-admin-server"].each do |name|
      deployment = manifests.find do |doc|
        doc.is_a?(Hash) && doc["kind"] == "Deployment" && doc.dig("metadata", "name") == name
      end
      pull_secrets = deployment&.dig("spec", "template", "spec", "imagePullSecrets") || []
      unless pull_secrets.any? { |secret| secret.is_a?(Hash) && secret["name"] == "ghcr-pull" }
        missing << "#{environment}: #{name} imagePullSecrets ghcr-pull missing"
      end
    end
 end

  abort "web-resource-missing: #{missing.join("; ")}" unless missing.empty?
' /tmp/jjinbbang-lab-jjinbbang-admin-dev.yaml \
  /tmp/jjinbbang-lab-jjinbbang-admin-prod.yaml \
  /tmp/jjinbbang-lab-jjinbbang-admin.yaml

echo "== kubectl kustomize app applications =="
kubectl kustomize platform/applications/apps >/tmp/jjinbbang-lab-applications-apps.yaml

echo "validation ok"
