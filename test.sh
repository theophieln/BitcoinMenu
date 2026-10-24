#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h}"
cd "$PROJECT_DIR"
mkdir -p build/module-cache
ARCH="$(uname -m)"
xcrun swiftc -swift-version 6 -parse-as-library \
  -target "${ARCH}-apple-macosx13.0" -module-cache-path "$PROJECT_DIR/build/module-cache" \
  Sources/PriceCore.swift Tests/PriceCoreTests.swift -o build/BitcoinMenuTests
build/BitcoinMenuTests "$@"
