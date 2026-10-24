#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h}"
cd "$PROJECT_DIR"
./test.sh
./build.sh
STAGING_DIR="$(mktemp -d "$PROJECT_DIR/build/dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto build/BitcoinMenu.app "$STAGING_DIR/BitcoinMenu.app"
ln -s /Applications "$STAGING_DIR/Applications"
mkdir -p dist
hdiutil create -volname BitcoinMenu -srcfolder "$STAGING_DIR" \
  -format UDZO -ov dist/BitcoinMenu.dmg
hdiutil verify dist/BitcoinMenu.dmg
printf 'DMG: %s/dist/BitcoinMenu.dmg\n' "$PROJECT_DIR"
