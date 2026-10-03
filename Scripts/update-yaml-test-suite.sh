#!/bin/sh
#
# Refreshes the vendored snapshot of the YAML test suite
# (https://github.com/yaml/yaml-test-suite) used by the conformance tests.
#
# Usage: Scripts/update-yaml-test-suite.sh [data-release-tag]
#
# The default tag is the latest published data release. The snapshot is
# copied into Tests/YamlKitTests/Resources/yaml-test-suite and the tag and
# commit hash are recorded in its VERSION file.

set -eu

TAG="${1:-data-2022-01-17}"
REPO="https://github.com/yaml/yaml-test-suite.git"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Tests/YamlKitTests/Resources/yaml-test-suite"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" "$REPO" "$WORK/suite"
COMMIT="$(git -C "$WORK/suite" rev-parse HEAD)"

rm -rf "$DEST"
mkdir -p "$DEST"
# Copy every test directory (top-level IDs, some of which contain numbered
# sub-cases), skipping repository metadata.
for entry in "$WORK/suite"/*; do
  name="$(basename "$entry")"
  case "$name" in
    name|tags|ReadMe.md|README.md|Makefile|LICENSE) continue ;;
  esac
  [ -d "$entry" ] && cp -R "$entry" "$DEST/$name"
done

printf '%s\n%s\n' "$TAG" "$COMMIT" > "$DEST/VERSION"
# The data branches do not contain the license of the test suite.
curl -fsSL "https://raw.githubusercontent.com/yaml/yaml-test-suite/main/License" > "$DEST/LICENSE"
echo "Vendored yaml-test-suite $TAG ($COMMIT) into $DEST"
