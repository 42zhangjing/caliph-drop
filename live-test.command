#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [[ "${CALIPH_DROP_ALLOW_LIVE_TEST:-0}" != "1" && "${CALIPH_DROP_RENDER_FIXTURE:-0}" != "1" ]]; then
  echo "这会向生产图库发布一张明确标注的验证图片。"
  echo "只有确认后才运行：CALIPH_DROP_ALLOW_LIVE_TEST=1 ./live-test.command"
  exit 2
fi

SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
TEST_BINARY="$(mktemp -t caliph-drop-live-tests)"

xcrun swiftc \
  -parse-as-library \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos13.0" \
  Sources/Models.swift \
  Sources/ImageProcessor.swift \
  Sources/KeychainStore.swift \
  Sources/Uploader.swift \
  Tests/LiveUploadSmoke.swift \
  -o "$TEST_BINARY" \
  -framework CoreGraphics \
  -framework AppKit \
  -framework ImageIO \
  -framework Security \
  -framework UniformTypeIdentifiers

CALIPH_DROP_ALLOW_LIVE_TEST="${CALIPH_DROP_ALLOW_LIVE_TEST:-0}" \
CALIPH_DROP_RENDER_FIXTURE="${CALIPH_DROP_RENDER_FIXTURE:-0}" \
  "$TEST_BINARY"
