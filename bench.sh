#!/bin/bash
# Times conversions and tools on large generated files (optimised build).
# ONLY=mp4,jpg ./bench.sh limits the cases; BENCH_OUT=file.tsv saves a table.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="${LIME_BUILD_DIR:-$ROOT/.build}"
mkdir -p "$BUILD/module-cache"
"$ROOT/Scripts/FetchSparkle.sh"
export LIME_TOOLS_DIR="$ROOT/Resources/Tools"
export LIME_PAGES_TEMPLATE="$ROOT/Resources/PagesTemplate.pages"
export BENCH_FIXTURES="${BENCH_FIXTURES:-$BUILD/bench-fixtures}"
SOURCES=()
while IFS= read -r -d '' file; do SOURCES+=("$file"); done < <(find "$ROOT/Sources" -name '*.swift' ! -name Entry.swift -print0 | sort -z)
swiftc -swift-version 5 -O -parse-as-library -target "$(uname -m)-apple-macosx13.0" -module-cache-path "$BUILD/module-cache" \
  "${SOURCES[@]}" "$ROOT/Tests/Benchmarks.swift" -o "$BUILD/Benchmarks" \
  -F "$ROOT/.deps/Sparkle" -framework Sparkle -Xlinker -rpath -Xlinker "$ROOT/.deps/Sparkle" 2>&1 | grep -E 'error' || true
"$BUILD/Benchmarks" 2>&1 | grep -v 'attributedStringScaled' | grep -E "^(PASS|FAIL|making)"
