#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h}"
cd "$PROJECT_DIR"
mkdir -p build/BitcoinMenu.app/Contents/{MacOS,Resources} build/module-cache
ARCH="$(uname -m)"
xcrun swiftc -swift-version 6 -O -parse-as-library \
  -target "${ARCH}-apple-macosx13.0" -module-cache-path "$PROJECT_DIR/build/module-cache" \
  Sources/PriceCore.swift Sources/App.swift Sources/Main.swift \
  -framework AppKit -o build/BitcoinMenu.app/Contents/MacOS/BitcoinMenu
cp Resources/Info.plist build/BitcoinMenu.app/Contents/Info.plist
cp Resources/AppIcon.icns build/BitcoinMenu.app/Contents/Resources/AppIcon.icns
plutil -lint build/BitcoinMenu.app/Contents/Info.plist
codesign --force --sign - build/BitcoinMenu.app
codesign --verify --strict build/BitcoinMenu.app
printf 'Built: %s/build/BitcoinMenu.app\n' "$PROJECT_DIR"
