#!/bin/bash
# Downloads the pinned Sparkle release into .deps/Sparkle (once) and checks it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="2.10.0"
SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
DEST="$ROOT/.deps/Sparkle"
[ -f "$DEST/.version" ] && [ "$(cat "$DEST/.version")" = "$VERSION" ] && exit 0
ARCHIVE="$ROOT/.deps/Sparkle-$VERSION.tar.xz"
mkdir -p "$ROOT/.deps"
curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" -o "$ARCHIVE"
echo "$SHA256  $ARCHIVE" | shasum -a 256 -c - >/dev/null
rm -rf "$DEST" && mkdir -p "$DEST"
tar -xJf "$ARCHIVE" -C "$DEST"
echo "$VERSION" > "$DEST/.version"
