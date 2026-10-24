#!/bin/bash
# Builds "Lime.app" next to this folder.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="${LIME_BUILD_DIR:-$ROOT/.build}"
APP="${LIME_APP_PATH:-$ROOT/../Lime.app}"
VERSION="1.2.0"
"$ROOT/Scripts/FetchSparkle.sh"
SPARKLE="$ROOT/.deps/Sparkle"
mkdir -p "$BUILD/module-cache"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
SOURCES=()
while IFS= read -r -d '' file; do SOURCES+=("$file"); done < <(find "$ROOT/Sources" -name '*.swift' -print0 | sort -z)
# One binary per architecture, joined so the same app runs on Apple silicon
# and Intel. LIME_ARCHS="arm64" builds just one for quicker local runs.
ARCHS="${LIME_ARCHS:-arm64 x86_64}"
SLICES=()
for arch in $ARCHS; do
  mkdir -p "$BUILD/$arch"
  swiftc -swift-version 5 -O -parse-as-library -target "$arch-apple-macosx13.0" -module-cache-path "$BUILD/module-cache" \
    "${SOURCES[@]}" -o "$BUILD/$arch/Lime" \
    -framework AppKit -framework SwiftUI -framework AVFoundation -framework AVKit -framework PDFKit -framework Quartz \
    -framework Vision -framework CoreImage -framework QuickLookUI -framework QuickLookThumbnailing \
    -framework ServiceManagement -framework UniformTypeIdentifiers -framework ImageIO -framework WebKit \
    -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks
  SLICES+=("$BUILD/$arch/Lime")
done
lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/Lime"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Lime</string>
<key>CFBundleDisplayName</key><string>Lime</string>
<key>CFBundleIdentifier</key><string>local.Lime</string>
<key>CFBundleExecutable</key><string>Lime</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIconName</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAccentColorName</key><string>AccentColor</string>
<key>SUFeedURL</key><string>https://raw.githubusercontent.com/LumenJSN/Lime/main/appcast.xml</string>
<key>SUPublicEDKey</key><string>rGOxlINsJFBRPJetMzAySViGVEzpF9z+HqNwGNx7Doo=</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Lime opens a Terminal window at the location of your files.</string>
<key>NSDesktopFolderUsageDescription</key><string>Lime saves converted files beside the originals on your Desktop.</string>
<key>NSDocumentsFolderUsageDescription</key><string>Lime saves converted files beside the originals in Documents.</string>
<key>NSDownloadsFolderUsageDescription</key><string>Lime saves converted files beside the originals in Downloads.</string>
<key>NSRemovableVolumesUsageDescription</key><string>Lime saves converted files beside the originals on external drives.</string>
</dict></plist>
PLIST
cp "$ROOT/Resources/PagesTemplate.pages" "$APP/Contents/Resources/PagesTemplate.pages"
# AppIcon.icon is an Icon Composer document: macOS 26+ draws it as Liquid Glass,
# older systems get the flattened AppIcon.icns that actool writes beside it.
xcrun actool "$ROOT/Resources/Assets.xcassets" "$ROOT/Resources/AppIcon.icon" --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 13.0 --app-icon AppIcon \
  --output-partial-info-plist "$BUILD/assets-info.plist" >/dev/null
mkdir -p "$APP/Contents/Resources/Tools" "$APP/Contents/Resources/Licenses"
cp "$ROOT/Resources/Tools/ffmpeg" "$ROOT/Resources/Tools/ffprobe" "$APP/Contents/Resources/Tools/"
cp "$ROOT/Resources/Licenses/"* "$APP/Contents/Resources/Licenses/"
cp "$SPARKLE/LICENSE" "$APP/Contents/Resources/Licenses/Sparkle.txt"
# Lime is not sandboxed, so Sparkle's XPC services are not needed.
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
# A stable identity keeps macOS folder permissions across rebuilds; an
# ad-hoc signature looks like a new app every time. Override with LIME_SIGN_IDENTITY.
IDENTITY="${LIME_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development|Developer ID Application/ {print $2; exit}')}"
IDENTITY="${IDENTITY:--}"
for tool in "$APP/Contents/Resources/Tools/"*; do codesign --force --sign "$IDENTITY" "$tool" >/dev/null; done
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for part in "$FRAMEWORK/Autoupdate" "$FRAMEWORK/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework"; do
  codesign --force --sign "$IDENTITY" "$part" >/dev/null
done
codesign --force --sign "$IDENTITY" "$APP" >/dev/null
printf 'Built %s\n' "$APP"
