#!/bin/bash
# Packs an app into a drag-to-Applications disk image:
#   Scripts/MakeDMG.sh <Lime.app> <output.dmg>
# The window layout is set through Finder; if Finder can't be scripted, the
# image still works, just without the arranged icons and background.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$1"
OUT="$2"
VOLUME="Lime"
WORK="$(mktemp -d)"
trap 'hdiutil detach "/Volumes/$VOLUME" -quiet 2>/dev/null || true; rm -rf "$WORK"' EXIT

mkdir -p "$WORK/stage/.background"
ditto "$APP" "$WORK/stage/Lime.app"
ln -s /Applications "$WORK/stage/Applications"
swift "$ROOT/Scripts/MakeDMGBackground.swift" "$WORK/art"
tiffutil -cathidpicheck "$WORK/art/background.png" "$WORK/art/background@2x.png" -out "$WORK/stage/.background/background.tiff" 2>/dev/null

hdiutil detach "/Volumes/$VOLUME" -quiet 2>/dev/null || true
hdiutil create -quiet -volname "$VOLUME" -srcfolder "$WORK/stage" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg"
hdiutil attach -quiet -readwrite -noverify -noautoopen "$WORK/rw.dmg"

if ! osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLUME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 800, 528}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "Lime.app" of container window to {160, 190}
    set position of item "Applications" of container window to {440, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
then
  echo "Finder couldn't arrange the window; the image will use the default layout." >&2
fi

# The volume icon goes in last: Finder removes it while it saves the layout.
cp "$APP/Contents/Resources/AppIcon.icns" "/Volumes/$VOLUME/.VolumeIcon.icns"
SetFile -a C "/Volumes/$VOLUME"
sync
hdiutil detach "/Volumes/$VOLUME" -quiet
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$OUT"
echo "Made $OUT"
