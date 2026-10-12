#!/bin/bash
# build.sh — 构建 AirPods 电池健康查看器.app（通用二进制 x86_64 + arm64）
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
SRC="$ROOT/Sources/AirPodsHealthViewer.swift"
APP_NAME="AirPodsHealthViewer"
DISPLAY_NAME="AirPods 电池健康查看器"
BUNDLE_ID="com.kaiwetlab.airpods-health-viewer"
VERSION="1.0"
BUILD="$ROOT/build/$DISPLAY_NAME.app"

echo "==> 清理旧产物"
rm -rf "$ROOT/build"
mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources"

# -disable-sandbox：某些受限环境（CI / 沙箱）下编译器无法为宏插件启动子沙箱，
# 会导致 SwiftUIMacros 报 "produced malformed response"，加上此开关即可绕过。
FLAGS=(-O -parse-as-library -disable-sandbox)

echo "==> 编译 arm64"
swiftc -target arm64-apple-macos14.0 "${FLAGS[@]}" -o /tmp/${APP_NAME}.arm64 "$SRC"
echo "==> 编译 x86_64"
swiftc -target x86_64-apple-macos14.0 "${FLAGS[@]}" -o /tmp/${APP_NAME}.x86_64 "$SRC"

echo "==> 合并为通用二进制"
lipo -create -output "$BUILD/Contents/MacOS/$APP_NAME" /tmp/${APP_NAME}.arm64 /tmp/${APP_NAME}.x86_64
rm -f /tmp/${APP_NAME}.arm64 /tmp/${APP_NAME}.x86_64

echo "==> 写入 Info.plist"
cat > "$BUILD/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key>
	<string>${DISPLAY_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleExecutable</key>
	<string>${APP_NAME}</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSSupportsAutomaticGraphicsSwitching</key>
	<true/>
</dict>
</plist>
PLIST

echo "==> 拷贝图标"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$BUILD/Contents/Resources/"

echo "==> ad-hoc 签名"
codesign --force --deep --sign - "$BUILD"

echo "==> 完成：$BUILD"
lipo -info "$BUILD/Contents/MacOS/$APP_NAME"
