#!/usr/bin/env bash
# Consumer check against the commit's release archive (git archive honours
# .gitattributes export-ignore, as GitHub's tag tarballs do): the
# export-ignored directories are absent and @rules_spicedb//... loads for a
# consumer. Same check as rules_atlas / rules_kubectl. Also (#9): a root that
# declares rules_spicedb's own version resolves, and one module declaring a
# version two ways fails clearly.
# Usage: .github/consumer/check.sh <scratch dir>
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
work="$1"
src="$work/rules_spicedb"
rm -rf "$work"; mkdir -p "$src"
git -C "$repo" archive HEAD | tar -x -C "$src"
for d in tests; do
    if [[ -e "$src/$d" ]]; then echo "FAIL: archive contains $d/" >&2; exit 1; fi
done
# rules_kubectl is a non-dev dependency outside the BCR: pin it as this
# repo's MODULE.bazel does (its override applies only when it is the root).
kubectl_version="$(sed -n 's/^bazel_dep(name = "rules_kubectl", version = "\([^"]*\)".*/\1/p' "$src/MODULE.bazel")"
kubectl_commit="$(grep -A3 'module_name = "rules_kubectl"' "$src/MODULE.bazel" | sed -n 's/.*commit = "\([0-9a-f]*\)".*/\1/p')"

consumer() { # <name> <extra MODULE.bazel lines>
    local c="$work/$1"
    mkdir -p "$c"
    touch "$c/BUILD.bazel"
    if [[ -f "$repo/.bazelversion" ]]; then cp "$repo/.bazelversion" "$c/"; fi
    cat > "$c/MODULE.bazel" <<MOD
module(name = "consumer")
bazel_dep(name = "rules_spicedb")
local_path_override(module_name = "rules_spicedb", path = "$src")
bazel_dep(name = "rules_kubectl", version = "$kubectl_version")
git_override(
    module_name = "rules_kubectl",
    remote = "https://github.com/collider-bazel-extensions/rules_kubectl",
    commit = "$kubectl_commit",
)
$2
MOD
    echo "$c"
}

c="$(consumer consumer "")"
(cd "$c" && bazel query @rules_spicedb//... >/dev/null)
echo "PASS: @rules_spicedb//... loads; archive has no tests"

# #9: the root declares the version rules_spicedb itself declares, as the
# README shows. Through v0.3.2 the extension created its repos twice.
version="$(sed -n 's/^spicedb.version(versions = \["\([^"]*\)"\])/\1/p' "$src/MODULE.bazel")"
[[ -n "$version" ]] || { echo "FAIL: no spicedb.version() in rules_spicedb's MODULE.bazel" >&2; exit 1; }
repo_name="spicedb_${version//./_}_linux_amd64"
c="$(consumer same_version "spicedb = use_extension(\"@rules_spicedb//:extensions.bzl\", \"spicedb\", dev_dependency = True)
spicedb.version(versions = [\"$version\"])
use_repo(spicedb, \"$repo_name\")")"
(cd "$c" && bazel query "@$repo_name//:all" >/dev/null)
echo "PASS: a root declaring rules_spicedb's version ($version) resolves"

# One module declaring a version two ways fails, naming both tags.
c="$(consumer conflict "spicedb = use_extension(\"@rules_spicedb//:extensions.bzl\", \"spicedb\")
spicedb.version(versions = [\"$version\"])
spicedb.system(versions = [\"$version\"])")"
if (cd "$c" && bazel mod deps) > "$work/conflict.out" 2>&1; then
    echo "FAIL: a version declared two ways resolved" >&2; exit 1
fi
grep -q "declares SpiceDB $version twice, differently (spicedb.version and spicedb.system)" "$work/conflict.out" || {
    cat "$work/conflict.out" >&2; echo "FAIL: conflicting tags: wrong error" >&2; exit 1; }
echo "PASS: a version declared two ways fails clearly"
