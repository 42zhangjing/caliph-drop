#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
TEST_BINARY="$(mktemp -t caliph-drop-core-tests)"

xcrun swiftc \
  -parse-as-library \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos13.0" \
  Sources/Models.swift \
  Sources/ImageProcessor.swift \
  Sources/Uploader.swift \
  Tests/CaliphDropCoreTests.swift \
  -o "$TEST_BINARY" \
  -framework CoreGraphics \
  -framework ImageIO \
  -framework UniformTypeIdentifiers

"$TEST_BINARY"
