#!/bin/bash
# Runs catalog/interaction, conversion-matrix and tool checks.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="${LIME_BUILD_DIR:-$ROOT/.build}"
mkdir -p "$BUILD/module-cache"
"$ROOT/Scripts/FetchSparkle.sh"
export LIME_TOOLS_DIR="$ROOT/Resources/Tools"
export LIME_PAGES_TEMPLATE="$ROOT/Resources/PagesTemplate.pages"
export RAR_FIXTURE="${RAR_FIXTURE:-$ROOT/Tests/Fixtures/sample.rar}" XLS_FIXTURE="${XLS_FIXTURE:-$ROOT/Tests/Fixtures/sample.xls}" PPT_FIXTURE="${PPT_FIXTURE:-$ROOT/Tests/Fixtures/sample.ppt}"
SOURCES=()
while IFS= read -r -d '' file; do SOURCES+=("$file"); done < <(find "$ROOT/Sources" -name '*.swift' ! -name Entry.swift -print0 | sort -z)
for suite in InteractionChecks ConversionMatrixChecks ToolChecks; do
  swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx13.0 -module-cache-path "$BUILD/module-cache" \
    "${SOURCES[@]}" "$ROOT/Tests/$suite.swift" -o "$BUILD/$suite" \
    -F "$ROOT/.deps/Sparkle" -framework Sparkle -Xlinker -rpath -Xlinker "$ROOT/.deps/Sparkle" 2>&1 | grep -E 'error' || true
  echo "== $suite"
  "$BUILD/$suite" 2>&1 | grep -v 'attributedStringScaled' | grep -E '^(PASS|FAIL|SKIPPED)'
done
