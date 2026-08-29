#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${GITOPS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

COMPONENT="${COMPONENT:-}"
DEPLOY_ENVIRONMENT="${DEPLOY_ENVIRONMENT:-}"
SOURCE_REPOSITORY="${SOURCE_REPOSITORY:-}"
SOURCE_REF="${SOURCE_REF:-}"
SOURCE_SHA="${SOURCE_SHA:-}"
IMAGE="${IMAGE:-}"
TAG="${TAG:-}"
IMAGE_DIGEST="${IMAGE_DIGEST:-}"
VALIDATE_ONLY="${VALIDATE_ONLY:-false}"

case "$COMPONENT" in
  web)
    EXPECTED_SOURCE="JJinBBang-web/JJinBBang_Admin"
    EXPECTED_IMAGE="ghcr.io/jjinbbang-web/jjinbbang-admin"
    ;;
  server)
    EXPECTED_SOURCE="JJinBBang-web/jjinbbang-server"
    EXPECTED_IMAGE="ghcr.io/jjinbbang-web/jjinbbang-server"
    ;;
  *)
    echo "unsupported component: $COMPONENT" >&2
    exit 1
    ;;
esac

case "$DEPLOY_ENVIRONMENT" in
  dev)
    EXPECTED_REF="develop"
    ;;
  prod)
    EXPECTED_REF="main"
    ;;
  *)
    echo "unsupported deployment environment: $DEPLOY_ENVIRONMENT" >&2
    exit 1
    ;;
esac

if [[ "$SOURCE_REPOSITORY" != "$EXPECTED_SOURCE" ]]; then
  echo "unexpected source repository for $COMPONENT: $SOURCE_REPOSITORY" >&2
  exit 1
fi
if [[ "$SOURCE_REF" != "$EXPECTED_REF" ]]; then
  echo "environment/source ref mismatch: $DEPLOY_ENVIRONMENT/$SOURCE_REF" >&2
  exit 1
fi
if [[ "$IMAGE" != "$EXPECTED_IMAGE" ]]; then
  echo "unexpected image for $COMPONENT: $IMAGE" >&2
  exit 1
fi
if [[ ! "$TAG" =~ ^[0-9a-f]{40}$ ]]; then
  echo "tag must be a full Git commit SHA" >&2
  exit 1
fi
if [[ "$SOURCE_SHA" != "$TAG" ]]; then
  echo "source SHA must match image tag: $SOURCE_SHA/$TAG" >&2
  exit 1
fi
if [[ ! "$IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "invalid image digest" >&2
  exit 1
fi
if [[ "$VALIDATE_ONLY" == "true" ]]; then
  echo "dispatch payload validation ok: $COMPONENT/$DEPLOY_ENVIRONMENT"
  exit 0
fi
if [[ "$VALIDATE_ONLY" != "false" ]]; then
  echo "VALIDATE_ONLY must be true or false" >&2
  exit 1
fi

OVERLAY_DIR="$ROOT_DIR/apps/jjinbbang-admin/overlays/$DEPLOY_ENVIRONMENT"
if [[ ! -f "$OVERLAY_DIR/kustomization.yaml" ]]; then
  echo "overlay kustomization not found: $OVERLAY_DIR/kustomization.yaml" >&2
  exit 1
fi
if ! command -v kustomize >/dev/null 2>&1; then
  echo "kustomize is required" >&2
  exit 1
fi

cd "$OVERLAY_DIR"
EDIT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/jjinbbang-kustomize-edit.XXXXXX")"
UPDATED_FILE="$(mktemp "${TMPDIR:-/tmp}/jjinbbang-kustomization.XXXXXX")"
cleanup() {
  rm -rf "$EDIT_DIR"
  rm -f "$UPDATED_FILE"
}
trap cleanup EXIT

cp kustomization.yaml "$EDIT_DIR/kustomization.yaml"
(
  cd "$EDIT_DIR"
  kustomize edit set image "$IMAGE=$IMAGE@$IMAGE_DIGEST"
)
grep -Fq "digest: $IMAGE_DIGEST" "$EDIT_DIR/kustomization.yaml"
grep -Fq "name: $IMAGE" "$EDIT_DIR/kustomization.yaml"
grep -Fq "newName: $IMAGE" "$EDIT_DIR/kustomization.yaml"

awk -v image="$IMAGE" -v digest="$IMAGE_DIGEST" '
  $0 == "  - name: " image {
    print
    print "    newName: " image
    print "    digest: " digest
    replacing = 1
    found = 1
    next
  }
  replacing && /^    (newName|newTag|digest):/ { next }
  replacing { replacing = 0 }
  { print }
  END { if (!found) exit 1 }
' kustomization.yaml >"$UPDATED_FILE"
mv "$UPDATED_FILE" kustomization.yaml
echo "updated $DEPLOY_ENVIRONMENT $COMPONENT image to $IMAGE@$IMAGE_DIGEST"
