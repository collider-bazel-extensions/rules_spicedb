#!/usr/bin/env bash
# Maintainer flow:
#   1. Edit tools/versions.bzl::SPICEDB_OPERATOR_VERSIONS — add/update the
#      target version's URL + sha256.
#   2. tools/render_spicedb_operator.sh <version>  (e.g. v1.25.0)
#
# Bazel-free: just curl + sha-check + copy into private/manifests/.
# Mirrors the rules_tekton pattern (release.yaml, no helm chart).
set -euo pipefail

VERSION="${1:?usage: tools/render_spicedb_operator.sh <version>}"

url=$(awk -v v="\"$VERSION\":" '
    $0 ~ v { in_block=1; next }
    in_block && /"url":/ { gsub(/[",]/,""); print $2; exit }
' tools/versions.bzl)
sha=$(awk -v v="\"$VERSION\":" '
    $0 ~ v { in_block=1; next }
    in_block && /"sha256":/ { gsub(/[",]/,""); print $2; exit }
' tools/versions.bzl)

[[ -n "$url" && -n "$sha" ]] || {
  echo "render_spicedb_operator: version '$VERSION' not in tools/versions.bzl" >&2
  exit 1
}

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

echo "render_spicedb_operator: fetching $url"
curl -sLfo "$tmp" "$url"

got_sha=$(sha256sum "$tmp" | awk '{print $1}')
if [[ "$got_sha" != "$sha" ]]; then
  echo "render_spicedb_operator: sha256 mismatch" >&2
  echo "  expected: $sha" >&2
  echo "  got:      $got_sha" >&2
  echo "Update tools/versions.bzl if the upstream changed intentionally." >&2
  exit 1
fi

dest="private/manifests/spicedb_operator.yaml"
mv "$tmp" "$dest"
trap - EXIT

echo "render_spicedb_operator: wrote $dest"
echo "  version: $VERSION"
echo "  sha256:  $got_sha"
echo "  lines:   $(wc -l < "$dest")"
