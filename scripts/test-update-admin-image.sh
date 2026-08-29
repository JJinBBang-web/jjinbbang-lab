#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATE_SCRIPT="$ROOT_DIR/scripts/update-admin-image.sh"
WORKFLOW="$ROOT_DIR/.github/workflows/update-admin-image.yml"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/jjinbbang-admin-image-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

WEB_IMAGE="ghcr.io/jjinbbang-web/jjinbbang-admin"
SERVER_IMAGE="ghcr.io/jjinbbang-web/jjinbbang-server"
WEB_SOURCE="JJinBBang-web/JJinBBang_Admin"
LEGACY_WEB_SOURCE="JJinBBang-web/jjinbbang-admin"
SERVER_SOURCE="JJinBBang-web/jjinbbang-server"
WEB_SHA="1111111111111111111111111111111111111111"
SERVER_SHA="2222222222222222222222222222222222222222"
WEB_DIGEST="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SERVER_DIGEST="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

new_fixture() {
  local fixture_name="$1"
  local fixture_dir="$TMP_DIR/$fixture_name"
  mkdir -p "$fixture_dir"
  cp -R "$ROOT_DIR/apps" "$fixture_dir/apps"
  printf '%s\n' "$fixture_dir"
}

install_kustomize_fixture() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cp "$ROOT_DIR/scripts/test-fixtures/kustomize-edit-set-image" "$bin_dir/kustomize"
  chmod +x "$bin_dir/kustomize"
}

run_update() {
  local fixture_dir="$1"
  local component="$2"
  local environment="$3"
  local source_repository="$4"
  local source_ref="$5"
  local source_sha="$6"
  local image="$7"
  local tag="$8"
  local digest="$9"
  local bin_dir="$fixture_dir/bin"

  install_kustomize_fixture "$bin_dir"
  PATH="$bin_dir:$PATH" \
    GITOPS_ROOT="$fixture_dir" \
    COMPONENT="$component" \
    DEPLOY_ENVIRONMENT="$environment" \
    SOURCE_REPOSITORY="$source_repository" \
    SOURCE_REF="$source_ref" \
    SOURCE_SHA="$source_sha" \
    IMAGE="$image" \
    TAG="$tag" \
    IMAGE_DIGEST="$digest" \
    "$UPDATE_SCRIPT"
}

expect_rejected() {
  local case_name="$1"
  local expected_message="$2"
  shift 2
  local fixture_dir
  fixture_dir="$(new_fixture "invalid-$case_name")"
  if run_update "$fixture_dir" "$@" >"$fixture_dir/output.log" 2>&1; then
    fail "$case_name payload was accepted"
  fi
  grep -Fq "$expected_message" "$fixture_dir/output.log" ||
    fail "$case_name did not fail during payload validation"
  echo "PASS: invalid $case_name rejected"
}

image_block() {
  local file="$1"
  local image="$2"
  awk -v image="$image" '
    $0 == "  - name: " image { capture = 1 }
    capture && $0 ~ /^  - name: / && $0 != "  - name: " image { exit }
    capture { print }
  ' "$file"
}

assert_digest_pin() {
  local file="$1"
  local image="$2"
  local digest="$3"
  local block
  block="$(image_block "$file" "$image")"
  grep -Fqx "    newName: $image" <<<"$block" || fail "$image newName was not set"
  grep -Fqx "    digest: $digest" <<<"$block" || fail "$image digest was not set"
  if grep -Eq '^[[:space:]]+newTag:' <<<"$block"; then
    fail "$image retained a mutable tag"
  fi
}

assert_only_target_changed() {
  local before_dir="$1"
  local after_dir="$2"
  local target_relative_path="$3"
  local changed
  changed="$(diff -qr "$before_dir" "$after_dir" | sed "s|$before_dir/||; s| and $after_dir/| |" || true)"
  [[ "$changed" == "Files $target_relative_path $target_relative_path differ" ]] ||
    fail "unexpected changed files: ${changed:-none}"
}

[[ -f "$UPDATE_SCRIPT" ]] || fail "missing shared update script: $UPDATE_SCRIPT"
[[ -x "$UPDATE_SCRIPT" ]] || fail "shared update script is not executable"

expect_rejected component 'unsupported component' \
  desktop dev "$WEB_SOURCE" develop "$WEB_SHA" "$WEB_IMAGE" "$WEB_SHA" "$WEB_DIGEST"
expect_rejected environment 'unsupported deployment environment' \
  web qa "$WEB_SOURCE" develop "$WEB_SHA" "$WEB_IMAGE" "$WEB_SHA" "$WEB_DIGEST"
expect_rejected source 'unexpected source repository' \
  web dev "$SERVER_SOURCE" develop "$WEB_SHA" "$WEB_IMAGE" "$WEB_SHA" "$WEB_DIGEST"
expect_rejected legacy_source 'unexpected source repository' \
  web dev "$LEGACY_WEB_SOURCE" develop "$WEB_SHA" "$WEB_IMAGE" "$WEB_SHA" "$WEB_DIGEST"
expect_rejected ref 'environment/source ref mismatch' \
  web dev "$WEB_SOURCE" main "$WEB_SHA" "$WEB_IMAGE" "$WEB_SHA" "$WEB_DIGEST"
expect_rejected digest 'invalid image digest' \
  web dev "$WEB_SOURCE" develop "$WEB_SHA" "$WEB_IMAGE" "$WEB_SHA" 'sha256:not-a-digest'
expect_rejected image 'unexpected image' \
  server prod "$SERVER_SOURCE" main "$SERVER_SHA" "$WEB_IMAGE" "$SERVER_SHA" "$SERVER_DIGEST"

web_fixture="$(new_fixture valid-web-dev)"
cp -R "$web_fixture/apps" "$web_fixture/apps-before"
web_server_before="$(image_block "$web_fixture/apps-before/jjinbbang-admin/overlays/dev/kustomization.yaml" "$SERVER_IMAGE")"
run_update "$web_fixture" web dev "$WEB_SOURCE" develop "$WEB_SHA" "$WEB_IMAGE" "$WEB_SHA" "$WEB_DIGEST"
assert_only_target_changed \
  "$web_fixture/apps-before" "$web_fixture/apps" \
  'jjinbbang-admin/overlays/dev/kustomization.yaml'
assert_digest_pin \
  "$web_fixture/apps/jjinbbang-admin/overlays/dev/kustomization.yaml" \
  "$WEB_IMAGE" "$WEB_DIGEST"
[[ "$web_server_before" == "$(image_block "$web_fixture/apps/jjinbbang-admin/overlays/dev/kustomization.yaml" "$SERVER_IMAGE")" ]] ||
  fail "dev server image block changed during web update"
cmp -s \
  "$web_fixture/apps-before/jjinbbang-admin/overlays/prod/kustomization.yaml" \
  "$web_fixture/apps/jjinbbang-admin/overlays/prod/kustomization.yaml" ||
  fail "prod overlay changed during dev web update"
echo "PASS: dev web changed only dev web image; prod overlay and dev server block are byte-for-byte identical"

server_fixture="$(new_fixture valid-server-prod)"
cp -R "$server_fixture/apps" "$server_fixture/apps-before"
prod_web_before="$(image_block "$server_fixture/apps-before/jjinbbang-admin/overlays/prod/kustomization.yaml" "$WEB_IMAGE")"
run_update "$server_fixture" server prod "$SERVER_SOURCE" main "$SERVER_SHA" "$SERVER_IMAGE" "$SERVER_SHA" "$SERVER_DIGEST"
assert_only_target_changed \
  "$server_fixture/apps-before" "$server_fixture/apps" \
  'jjinbbang-admin/overlays/prod/kustomization.yaml'
assert_digest_pin \
  "$server_fixture/apps/jjinbbang-admin/overlays/prod/kustomization.yaml" \
  "$SERVER_IMAGE" "$SERVER_DIGEST"
[[ "$prod_web_before" == "$(image_block "$server_fixture/apps/jjinbbang-admin/overlays/prod/kustomization.yaml" "$WEB_IMAGE")" ]] ||
  fail "prod web image block changed during server update"
cmp -s \
  "$server_fixture/apps-before/jjinbbang-admin/overlays/dev/kustomization.yaml" \
  "$server_fixture/apps/jjinbbang-admin/overlays/dev/kustomization.yaml" ||
  fail "dev overlay changed during prod server update"
echo "PASS: prod server changed only prod API image; dev overlay and prod web block are byte-for-byte identical"

grep -Fq './scripts/update-admin-image.sh' "$WORKFLOW" || fail "workflow does not call shared update script"
[[ "$(grep -Fc './scripts/update-admin-image.sh' "$WORKFLOW")" == "2" ]] ||
  fail "workflow must call shared script for validation and update"
grep -Fq 'VALIDATE_ONLY: "true"' "$WORKFLOW" || fail "workflow does not validate payload before remote checks"
grep -Fq 'EVENT_SENDER' "$WORKFLOW" || fail "workflow sender validation is missing"
grep -Fq 'api.github.com/repos/$SOURCE_REPOSITORY/commits/$SOURCE_REF' "$WORKFLOW" ||
  fail "workflow remote branch HEAD validation is missing"
grep -Fq 'docker buildx imagetools inspect' "$WORKFLOW" || fail "workflow GHCR digest validation is missing"
grep -Fq 'imranismail/setup-kustomize' "$WORKFLOW" || fail "workflow does not install real kustomize"
if grep -Ev '^[[:space:]]*#' "$WORKFLOW" | grep -Eq 'git (commit|push)'; then
  fail "workflow still has active automatic commit/push"
fi
echo "PASS: workflow delegates pure validation/update and keeps remote checks with auto-push disabled"

echo "All update-admin-image tests passed"
