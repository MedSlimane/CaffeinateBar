#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

APP="CaffeinateBar.app"
BIN="$APP/Contents/MacOS/CaffeinateBar"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
/bin/echo -n "APPL????" > "$APP/Contents/PkgInfo"

# Native, optimized, zero dependencies: AppKit only, no SwiftUI, no timers.
swiftc -O -whole-module-optimization -o "$BIN" Sources/main.swift -framework AppKit

codesign --force --deep --sign - "$APP" 2>/dev/null || true
echo "Built: $BIN ($(du -h "$BIN" | cut -f1))"
