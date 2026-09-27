#!/usr/bin/env bash
set -euo pipefail

repository="${1:?source repository is required}"
case "$repository" in
  JJinBBang-web/JJinBBang_Admin|JJinBBang-web/jjinbbang-server) ;;
  *) echo "unsupported admin source repository" >&2; exit 1 ;;
esac

api() {
  curl --fail --silent --show-error --retry 3 \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/repos/$repository/$1"
}

# Only completed push CI includes the tested and published ARM64 image.
sha="$(api 'actions/workflows/ci.yml/runs?branch=develop&event=push&status=success&per_page=1' |
  jq -r '.workflow_runs[0] | select(.conclusion == "success" and .event == "push" and .head_branch == "develop") | .head_sha // empty')"
if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "No successful develop push CI found for $repository; keep the current deployment." >&2
  exit 1
fi

# A force-push must not deploy a successful build removed from develop.
api "compare/$sha...develop" | jq -e '.status == "ahead" or .status == "identical"' >/dev/null || {
  echo "Successful CI commit is no longer on develop; refusing deployment." >&2
  exit 1
}
printf '%s\n' "$sha"
