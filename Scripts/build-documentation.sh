#!/bin/sh
#
# Builds the DocC documentation of YamlKit without Xcode, using SwiftPM to
# extract the symbol graph and the `docc` tool of the Swift toolchain.
#
# Usage:
#   Scripts/build-documentation.sh [archive|site|preview] [hosting-base-path]
#
#   archive  Create .build/YamlKit.doccarchive (default). Open it with Xcode
#            or serve it with a DocC-aware web server.
#   site     Create a static website in .build/docs-site that can be hosted
#            on any static web server (e.g. GitHub Pages). The optional
#            hosting base path is the URL path under which the site is
#            served, e.g. `swift-yamlkit` for
#            https://<user>.github.io/swift-yamlkit/ (default: no base path).
#   preview  Build the documentation and serve it locally at
#            http://localhost:8080/documentation/yamlkit with live reload.

set -eu

MODE="${1:-archive}"
BASE_PATH="${2:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYMBOL_GRAPHS="$ROOT/.build/symbol-graphs"
CATALOG="$ROOT/Sources/YamlKit/Documentation.docc"

# Locate docc: on the PATH (swift.org toolchains, Linux) or via xcrun (macOS).
if command -v docc >/dev/null 2>&1; then
  DOCC="docc"
elif command -v xcrun >/dev/null 2>&1 && xcrun --find docc >/dev/null 2>&1; then
  DOCC="$(xcrun --find docc)"
else
  echo "error: docc not found; install a Swift toolchain that includes DocC" >&2
  exit 1
fi

# Extract the symbol graph of the public API. A separate scratch path ensures
# that the module is compiled (and the symbol graph emitted) even if the
# regular build is up to date.
rm -rf "$SYMBOL_GRAPHS"
mkdir -p "$SYMBOL_GRAPHS"
swift build --package-path "$ROOT" --target YamlKit --scratch-path "$ROOT/.build/docs" \
  -Xswiftc -emit-symbol-graph \
  -Xswiftc -emit-symbol-graph-dir -Xswiftc "$SYMBOL_GRAPHS"

set -- --fallback-display-name YamlKit \
       --fallback-bundle-identifier org.objecthub.YamlKit \
       --additional-symbol-graph-dir "$SYMBOL_GRAPHS"

case "$MODE" in
  archive)
    "$DOCC" convert "$CATALOG" "$@" --output-path "$ROOT/.build/YamlKit.doccarchive"
    echo "Documentation archive: $ROOT/.build/YamlKit.doccarchive"
    ;;
  site)
    if [ -n "$BASE_PATH" ]; then
      set -- "$@" --hosting-base-path "$BASE_PATH"
    fi
    rm -rf "$ROOT/.build/docs-site"
    "$DOCC" convert "$CATALOG" "$@" --transform-for-static-hosting \
      --output-path "$ROOT/.build/docs-site"
    echo "Static website: $ROOT/.build/docs-site (entry point: documentation/yamlkit/index.html)"
    ;;
  preview)
    "$DOCC" preview "$CATALOG" "$@" --output-path "$ROOT/.build/docs-preview"
    ;;
  *)
    echo "usage: $0 [archive|site|preview] [hosting-base-path]" >&2
    exit 1
    ;;
esac
