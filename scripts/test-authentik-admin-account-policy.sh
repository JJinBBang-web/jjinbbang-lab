#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
blueprint="$root/platform/authentik/bootstrap/admin-enrollment-blueprint-configmap.yaml"
sso_blueprint="$root/platform/authentik/bootstrap/sso-blueprint-configmap.yaml"

test -f "$blueprint" || {
  echo "missing administrator enrollment blueprint: $blueprint" >&2
  exit 1
}

ruby -ryaml -e '
  configmap = YAML.safe_load(File.read(ARGV.fetch(0)))
  Psych.parse_stream(configmap.fetch("data").fetch("jjinbbang-admin-enrollment.yaml"))
' "$blueprint"

grep -Eq 'slug: jjinbbang-admin-invitation-enrollment' "$blueprint"
grep -Eq 'model: authentik_stages_invitation\.invitationstage' "$blueprint"
grep -Eq 'continue_flow_without_invitation: false' "$blueprint"
grep -Eq 'user_path_template: users/jjinbbang/pending' "$blueprint"

if grep -Eq 'create_users_group|jjinbbang-backoffice-admins|authentik Admins' "$blueprint"; then
  echo "enrollment must not grant administrator groups" >&2
  exit 1
fi

grep -Eq 'group: !KeyOf jjinbbang-backoffice-admins$' "$sso_blueprint"
grep -Eq 'group: !KeyOf jjinbbang-backoffice-admins-dev$' "$sso_blueprint"

echo "authentik administrator account policy ok"
