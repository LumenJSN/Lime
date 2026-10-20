#!/bin/bash
# Builds "Lime.app" next to this folder.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="${LIME_BUILD_DIR:-$ROOT/.build}"
APP="${LIME_APP_PATH:-$ROOT/../Lime.app}"
VERSION="1.0"
mkdir -p "$BUILD/module-cache"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
SOURCES=()
while IFS= read -r -d '' file; do SOURCES+=("$file"); done < <(find "$ROOT/Sources" -name '*.swift' -print0 | sort -z)
swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx13.0 -module-cache-path "$BUILD/module-cache" \
  "${SOURCES[@]}" -o "$APP/Contents/MacOS/Lime" \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework AVKit -framework PDFKit -framework Quartz \
  -framework Vision -framework CoreImage -framework QuickLookUI -framework QuickLookThumbnailing \
  -framework ServiceManagement -framework UniformTypeIdentifiers -framework ImageIO -framework WebKit
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Lime</string>
<key>CFBundleDisplayName</key><string>Lime</string>
<key>CFBundleIdentifier</key><string>local.Lime</string>
<key>CFBundleExecutable</key><string>Lime</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAccentColorName</key><string>AccentColor</string>
<key>NSAppleEventsUsageDescription</key><string>Lime opens a Terminal window at the location of your files.</string>
<key>NSDesktopFolderUsageDescription</key><string>Lime saves converted files beside the originals on your Desktop.</string>
<key>NSDocumentsFolderUsageDescription</key><string>Lime saves converted files beside the originals in Documents.</string>
<key>NSDownloadsFolderUsageDescription</key><string>Lime saves converted files beside the originals in Downloads.</string>
<key>NSRemovableVolumesUsageDescription</key><string>Lime saves converted files beside the originals on external drives.</string>
</dict></plist>
PLIST
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/PagesTemplate.pages" "$APP/Contents/Resources/PagesTemplate.pages"
xcrun actool "$ROOT/Resources/Assets.xcassets" --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 13.0 \
  --output-partial-info-plist "$BUILD/assets-info.plist" >/dev/null
mkdir -p "$APP/Contents/Resources/Tools" "$APP/Contents/Resources/Licenses"
cp "$ROOT/Resources/Tools/ffmpeg" "$ROOT/Resources/Tools/ffprobe" "$APP/Contents/Resources/Tools/"
cp "$ROOT/Resources/Licenses/"* "$APP/Contents/Resources/Licenses/"
# A stable identity keeps macOS folder permissions across rebuilds; an
# ad-hoc signature looks like a new app every time. Override with LIME_SIGN_IDENTITY.
IDENTITY="${LIME_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development|Developer ID Application/ {print $2; exit}')}"
IDENTITY="${IDENTITY:--}"
for tool in "$APP/Contents/Resources/Tools/"*; do codesign --force --sign "$IDENTITY" "$tool" >/dev/null; done
codesign --force --sign "$IDENTITY" "$APP" >/dev/null
printf 'Built %s\n' "$APP"
