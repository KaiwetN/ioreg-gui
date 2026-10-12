#!/bin/bash
# make-dmg.sh — 把 build/ 下的 .app 打包为可分发的 DMG（含 Applications 软链接）
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DISPLAY_NAME="IORegistry 查看器"
VERSION="1.0"
APP="$ROOT/build/$DISPLAY_NAME.app"
STAGE="$ROOT/build/dmg-stage"
OUT="$ROOT/dist/ioreg-gui-v${VERSION}.dmg"

if [ ! -d "$APP" ]; then
  echo "未找到 $APP，请先执行 scripts/build.sh" >&2
  exit 1
fi

echo "==> 准备 DMG 内容"
rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE" "$(dirname "$OUT")"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> 生成 DMG（UDZO 压缩）"
hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null

echo "==> 完成：$OUT"
ls -lh "$OUT"
