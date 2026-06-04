#!/bin/bash
# Build Ledge.app from Sources/. No Xcode project needed.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -O -swift-version 5 Sources/*.swift -o build/Ledge.bin
APP=build/Ledge.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
cp build/Ledge.bin "$APP/Contents/MacOS/Ledge"
codesign --force --sign - "$APP" 2>/dev/null
echo "built $APP"
