#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

APP="CaffeinateBar.app"
BIN="$APP/Contents/MacOS/CaffeinateBar"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
/bin/echo -n "APPL????" > "$APP/Contents/PkgInfo"

# App icon: .icns rendered from the Icon Composer export via native toolchain.
ICON_SRC="Assets/caffenated-iOS-Default-1024@1x.png"
if [[ -f "$ICON_SRC" ]]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  sips -z 16 16     "$ICON_SRC" --out "$ICONSET/icon_16x16.png" >/dev/null
  sips -z 32 32     "$ICON_SRC" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
  sips -z 32 32     "$ICON_SRC" --out "$ICONSET/icon_32x32.png" >/dev/null
  sips -z 64 64     "$ICON_SRC" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
  sips -z 128 128   "$ICON_SRC" --out "$ICONSET/icon_128x128.png" >/dev/null
  sips -z 256 256   "$ICON_SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
  sips -z 256 256   "$ICON_SRC" --out "$ICONSET/icon_256x256.png" >/dev/null
  sips -z 512 512   "$ICON_SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
  sips -z 512 512   "$ICON_SRC" --out "$ICONSET/icon_512x512.png" >/dev/null
  cp "$ICON_SRC" "$ICONSET/icon_512x512@2x.png"
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$(dirname "$ICONSET")"
  echo "Icon: $APP/Contents/Resources/AppIcon.icns"
fi

# Native, optimized, zero dependencies: AppKit only, no SwiftUI,
# one slow coalesced timer (external caffeinate check), zero polling otherwise.
swiftc -O -whole-module-optimization -o "$BIN" Sources/main.swift -framework AppKit

codesign --force --deep --sign - "$APP" 2>/dev/null || true
echo "Built: $BIN ($(du -h "$BIN" | cut -f1))"

# Optional drag-and-drop installer: ./build.sh --dmg
if [[ "${1:-}" == "--dmg" ]]; then
  DMG="CaffeinateBar-2.0.dmg"
  rm -f "$DMG"
  create-dmg \
    --volname "CaffeinateBar" \
    --volicon "$APP/Contents/Resources/AppIcon.icns" \
    --window-size 660 400 \
    --icon-size 110 \
    --icon "$APP" 170 180 \
    --app-drop-link 490 180 \
    "$DMG" \
    "$APP"
  echo "DMG: $DMG ($(du -h "$DMG" | cut -f1))"
fi
