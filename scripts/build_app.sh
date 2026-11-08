#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="/tmp/powerglass-v3.0-build"
ICON_TMP_DIR="/tmp/powerglass-v3.0-icons"
APP_NAME="SysPulse"

# 读取或初始化版本号，每次编译自动递增 0.0.1
VERSION_FILE="$HERE/VERSION"
if [ ! -f "$VERSION_FILE" ]; then
    echo "0.0.13" > "$VERSION_FILE"
fi
VERSION=$(cat "$VERSION_FILE" | tr -d '[:space:]')
IFS='.' read -r major minor patch <<< "$VERSION"
PATCH_NUM="${patch%%_*}"
BUILD_NUM="${PATCH_NUM}"
BUNDLE_DIR="$HERE/build/$APP_NAME.app"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

CONFIGURATION="${1:-debug}"
CONFIG_FLAG=""
if [ "$CONFIGURATION" = "release" ]; then
    CONFIG_FLAG="-c release"
fi

echo "⚡️ 正在编译 $APP_NAME v$VERSION (Build $BUILD_NUM, 模式: $CONFIGURATION)..."

TMPDIR=/tmp \
DARWIN_USER_TEMP_DIR=/tmp \
DARWIN_USER_CACHE_DIR=/tmp \
CLANG_MODULE_CACHE_PATH=/tmp/clang-cache \
/Library/Developer/CommandLineTools/usr/bin/swift build \
    --package-path "$HERE" \
    --scratch-path "$BUILD_DIR" \
    --disable-sandbox \
    -Xswiftc -module-cache-path -Xswiftc /tmp/clang-cache \
    $CONFIG_FLAG

BIN_DIR=$(TMPDIR=/tmp DARWIN_USER_TEMP_DIR=/tmp DARWIN_USER_CACHE_DIR=/tmp CLANG_MODULE_CACHE_PATH=/tmp/clang-cache /Library/Developer/CommandLineTools/usr/bin/swift build --package-path "$HERE" --scratch-path "$BUILD_DIR" --show-bin-path $CONFIG_FLAG)
BIN_PATH="$BIN_DIR/SysPulse"

echo "📦 正在打包为 $APP_NAME.app..."
rm -rf "$BUNDLE_DIR" "$ICON_TMP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$ICON_TMP_DIR"

cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

# 编译原生 IOKit UPS 关机策略底层同步助手 SysPulseUPSHelper
/usr/bin/clang -O2 -arch arm64 \
    -framework CoreFoundation -framework IOKit \
    "$HERE/scripts/SysPulseUPSHelper.c" \
    -o "$MACOS_DIR/SysPulseUPSHelper"
chmod 755 "$MACOS_DIR/SysPulseUPSHelper"

echo "🎨 正在生成自适应液态玻璃应用图标 (AppIcon-Light.icns & AppIcon-Dark.icns)..."
cp "$HERE/Resources/AppIcon-Light-1024.png" "$RESOURCES_DIR/"
cp "$HERE/Resources/AppIcon-Dark-1024.png" "$RESOURCES_DIR/"
cp "$HERE/Resources/CleanerIcon-Light-1024.png" "$RESOURCES_DIR/"
cp "$HERE/Resources/CleanerIcon-Dark-1024.png" "$RESOURCES_DIR/"
cp "$HERE/Resources/MenuBarRabbit"*.png "$RESOURCES_DIR/" 2>/dev/null || true
if [ -f "$HERE/Resources/UninstallerIcon-Light-1024.png" ]; then
    cp "$HERE/Resources/UninstallerIcon-Light-1024.png" "$RESOURCES_DIR/"
fi
if [ -f "$HERE/Resources/UninstallerIcon-Dark-1024.png" ]; then
    cp "$HERE/Resources/UninstallerIcon-Dark-1024.png" "$RESOURCES_DIR/"
fi
if [ -f "$HERE/Resources/SpaceAnalysisIcon-Light-1024.png" ]; then
    cp "$HERE/Resources/SpaceAnalysisIcon-Light-1024.png" "$RESOURCES_DIR/"
fi
if [ -f "$HERE/Resources/SpaceAnalysisIcon-Dark-1024.png" ]; then
    cp "$HERE/Resources/SpaceAnalysisIcon-Dark-1024.png" "$RESOURCES_DIR/"
fi
for t in 1 2 3 4; do
    if [ -f "$HERE/Resources/HealthRabbit-Tier${t}-1024.png" ]; then
        cp "$HERE/Resources/HealthRabbit-Tier${t}-1024.png" "$RESOURCES_DIR/"
    fi
done
"$MACOS_DIR/$APP_NAME" --generate-icons "$ICON_TMP_DIR"
/usr/bin/iconutil -c icns "$ICON_TMP_DIR/AppIcon-Light.iconset" -o "$RESOURCES_DIR/AppIcon-Light.icns"
/usr/bin/iconutil -c icns "$ICON_TMP_DIR/AppIcon-Dark.iconset" -o "$RESOURCES_DIR/AppIcon-Dark.icns"
cp "$RESOURCES_DIR/AppIcon-Light.icns" "$RESOURCES_DIR/AppIcon.icns"

cat << EOF > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.rabbit.syspulse</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUM</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>DTSDKName</key>
    <string>macosx27.2</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>SysPulse 需要使用蓝牙功能读取妙控键盘、妙控鼠标、触控板及 AirPods 的真实电量状态。</string>
</dict>
</plist>
EOF

echo "🔐 正在对应用包进行代码签名与隔离属性清理..."
/usr/bin/xattr -cr "$BUNDLE_DIR"
/usr/bin/codesign --force --deep --sign - "$BUNDLE_DIR"

# 同步纯净 App 到主目录 build 下（文件名不带版本号）
mkdir -p "$HERE/../build"
rm -rf "$HERE/../build/$APP_NAME.app"
cp -R "$BUNDLE_DIR" "$HERE/../build/$APP_NAME.app"

echo "💿 正在生成可分享的 DMG 安装包 ($APP_NAME-v$VERSION.dmg)..."
DMG_STAGING="/tmp/syspulse-dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$BUNDLE_DIR" "$DMG_STAGING/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING/Applications"

DMG_OUTPUT="$HERE/../build/$APP_NAME-v$VERSION.dmg"
rm -f "$DMG_OUTPUT"
/usr/bin/hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_OUTPUT" -quiet
rm -rf "$DMG_STAGING"

echo "🔄 正在平滑退出旧版本并自动启动全新 $APP_NAME.app..."
/usr/bin/killall -TERM "$APP_NAME" 2>/dev/null || true
sleep 0.4
/usr/bin/killall -9 "$APP_NAME" 2>/dev/null || true
sleep 0.5
/usr/bin/open "$HERE/../build/$APP_NAME.app"

echo "✅ 打包并启动完成:"
echo "   - 独立 App: $HERE/../build/$APP_NAME.app"
echo "   - 可分享 DMG: $DMG_OUTPUT"

# 下次编译自动递增 0.0.1（若为带后缀的测试支线则保持当前测试版本号）
if [[ "$patch" != *"_"* ]]; then
    NEXT_PATCH=$((PATCH_NUM + 1))
    NEXT_VERSION="${major}.${minor}.${NEXT_PATCH}"
    echo "$NEXT_VERSION" > "$VERSION_FILE"
    echo "🔢 下一次编译版本将自动递增为: v$NEXT_VERSION"
else
    echo "🧪 当前为测试支线版本: v$VERSION"
fi
