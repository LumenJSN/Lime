#!/bin/bash
# Builds a release of the version in build.sh into ../dist/<version>:
# an ad-hoc signed app zip for Sparkle and a drag-to-Applications DMG (no
# personal certificate or home path inside either),
# the LGPL sources, SHA256SUMS.txt, and a new item at the top of appcast.xml
# signed with the Sparkle key in the login Keychain (account "lime").
# Publishing stays manual: commit appcast.xml, then run the printed gh command.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$ROOT/build.sh")"
DIST="$ROOT/../dist/$VERSION"
SOURCES_DIR="${LIME_SOURCES_DIR:-$ROOT/../../work/dependencies/downloads}"
ZIP="Lime-$VERSION-arm64.zip"
DMG="Lime-$VERSION-arm64.dmg"
REPO="LumenJSN/Lime"

rm -rf "$DIST" && mkdir -p "$DIST"
LIME_SIGN_IDENTITY=- LIME_APP_PATH="$DIST/Lime.app" "$ROOT/build.sh"

# ffmpeg records its build prefix; swap the home folder name for one of the
# same length so the binaries stay valid, then re-sign.
NAME="$(basename "$HOME")"
MASK="$(printf 'x%.0s' $(seq ${#NAME}))"
for tool in "$DIST/Lime.app/Contents/Resources/Tools/"*; do
  perl -pi -e "s#/Users/\Q$NAME\E/#/Users/$MASK/#g" "$tool"
  codesign --force --sign - "$tool" >/dev/null
done
codesign --force --sign - "$DIST/Lime.app" >/dev/null
codesign --verify --deep --strict "$DIST/Lime.app"
# A personal signing certificate would put its owner's name and email in the app.
if codesign -dvv "$DIST/Lime.app" 2>&1 | grep -q '^Authority='; then
  echo "The app is signed with a certificate; releases must be ad-hoc." >&2; exit 1
fi
if grep -r -a -q -i -e "/Users/$NAME" "$DIST/Lime.app"; then
  echo "The home folder path is still inside the app; not releasing." >&2; exit 1
fi

(cd "$DIST" && ditto -c -k --sequesterRsrc --keepParent Lime.app "$ZIP")
"$ROOT/Scripts/MakeDMG.sh" "$DIST/Lime.app" "$DIST/$DMG"
cp "$SOURCES_DIR/ffmpeg-8.0.tar.xz" "$SOURCES_DIR/lame-3.100.tar.gz" "$DIST/"
(cd "$DIST" && shasum -a 256 "$DMG" "$ZIP" ffmpeg-8.0.tar.xz lame-3.100.tar.gz > SHA256SUMS.txt)

SIGNATURE="$("$ROOT/.deps/Sparkle/bin/sign_update" --account lime "$DIST/$ZIP")"
ITEM="    <item>
      <title>$VERSION</title>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <enclosure url=\"https://github.com/$REPO/releases/download/v$VERSION/$ZIP\" $SIGNATURE type=\"application/octet-stream\"/>
    </item>"
APPCAST="$ROOT/appcast.xml"
ITEM="$ITEM" python3 -I - "$APPCAST" <<'EOF'
import os, sys
path = sys.argv[1]
text = open(path).read()
marker = "<language>en</language>\n"
assert marker in text, "appcast.xml is missing its <language> line"
updated = text.replace(marker, marker + os.environ["ITEM"] + "\n", 1)
with open(path, "w") as handle:
    handle.write(updated)
EOF

# The release badge names the version itself: shieldcn caches the GitHub
# release, so a live badge still showed the previous version after a release.
sed -i '' "s#shieldcn.dev/badge/release-v[0-9.]*\.svg#shieldcn.dev/badge/release-v$VERSION.svg#g" "$ROOT/README.md"

echo "Release files are in $DIST"
echo "Next: commit appcast.xml and README.md, push, then:"
echo "  gh release create v$VERSION -R $REPO --target main --title \"Lime $VERSION\" --notes-file <notes.md> \"$DIST/$DMG\" \"$DIST/$ZIP\" \"$DIST/ffmpeg-8.0.tar.xz\" \"$DIST/lame-3.100.tar.gz\" \"$DIST/SHA256SUMS.txt\""
