#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "没有找到 Apple Swift 编译器。"
  echo "请先运行：xcode-select --install"
  read -r -p "按回车退出…"
  exit 1
fi

APP="Caliph Drop.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"

echo "正在构建 Caliph Drop ($ARCH)…"
xcrun swiftc \
  -O \
  -parse-as-library \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos13.0" \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/CaliphDrop" \
  -framework AppKit \
  -framework SwiftUI \
  -framework UniformTypeIdentifiers \
  -framework ImageIO \
  -framework Security \
  -framework CoreGraphics

cp Info.plist "$APP/Contents/Info.plist"

# 本机构建的 ad-hoc 签名，便于直接运行。
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo
printf "✓ 已生成：%s/%s\n" "$(pwd)" "$APP"
echo "现在可以双击打开 Caliph Drop.app。"
echo "第一次打开后，屏幕顶部菜单栏会出现上传图标。"
open "$APP"
