#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

APP="build/CmdQGuard.app"
BINARY="$APP/Contents/MacOS/CmdQGuard"
ARCH="$(uname -m)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

swiftc \
    -O \
    -swift-version 5 \
    -target "${ARCH}-apple-macos13.0" \
    -framework Cocoa \
    -framework ApplicationServices \
    -framework ServiceManagement \
    -framework SwiftUI \
    -framework UniformTypeIdentifiers \
    main.swift SettingsView.swift \
    -o "$BINARY"

codesign --force --sign - "$APP"

echo "Built $APP"
echo "Run:      open '$APP'"
echo "HUD demo: open -W '$APP' --args --demo"
echo "Settings: open -W '$APP' --args --settings-demo"
