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

CONFIGURATION="${1:-release}"
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

# 编译原生系统优化特权助手 SysPulseOptimizeHelper（零后台常驻进程）
if [ -f "$HERE/scripts/SysPulseOptimizeHelper.c" ]; then
    /usr/bin/clang -O2 -arch arm64 \
        "$HERE/scripts/SysPulseOptimizeHelper.c" \
        -o "$MACOS_DIR/SysPulseOptimizeHelper"
    chmod 755 "$MACOS_DIR/SysPulseOptimizeHelper"
fi

# 编译统一 Touch ID 特权执行助手 SysPulsePrivilegedHelper（零后台常驻进程，父进程签名校验）
if [ -f "$HERE/scripts/SysPulsePrivilegedHelper.c" ]; then
    /usr/bin/clang -O2 -arch arm64 \
        -framework CoreFoundation -framework Security \
        "$HERE/scripts/SysPulsePrivilegedHelper.c" \
        -o "$MACOS_DIR/SysPulsePrivilegedHelper"
    chmod 755 "$MACOS_DIR/SysPulsePrivilegedHelper"
fi

# 编译嵌入式 Node 运行时轻量桥接器 SysPulseNodeShim
if [ -f "$HERE/scripts/SysPulseNodeShim.c" ]; then
    /usr/bin/clang -O2 -arch arm64 \
        "$HERE/scripts/SysPulseNodeShim.c" \
        -o "$MACOS_DIR/SysPulseNodeShim"
    chmod 755 "$MACOS_DIR/SysPulseNodeShim"
fi

echo "🎨 正在生成自适应液态玻璃应用图标 (AppIcon-Light.icns & AppIcon-Dark.icns)..."
cp "$HERE/Resources/AppIcon-Light-1024.png" "$RESOURCES_DIR/"
cp "$HERE/Resources/AppIcon-Dark-1024.png" "$RESOURCES_DIR/"
cp "$HERE/Resources/CleanerIcon-Light-1024.png" "$RESOURCES_DIR/"
cp "$HERE/Resources/CleanerIcon-Dark-1024.png" "$RESOURCES_DIR/"
cp "$HERE/Resources/MenuBarRabbit"*.png "$RESOURCES_DIR/" 2>/dev/null || true
cp "$HERE/Resources/ieee_oui.tsv" "$RESOURCES_DIR/" 2>/dev/null || true
cp "$HERE/Resources/FolderNotes.json" "$RESOURCES_DIR/" 2>/dev/null || true
for icon_base in OptimizerIcon UninstallerIcon SpaceAnalysisIcon PSPortalIcon WiFiLatencyIcon LanSnifferIcon UPSPowerIcon AntigravityContextIcon AIToolCleanerIcon SoftwareUpdaterIcon AccessoryLocationIcon; do
    for suffix in Light Dark; do
        if [ -f "$HERE/Resources/${icon_base}-${suffix}-1024.png" ]; then
            cp "$HERE/Resources/${icon_base}-${suffix}-1024.png" "$RESOURCES_DIR/"
        fi
    done
done
if [ -d "$HERE/Resources/CommandLineToolIcons" ]; then
    mkdir -p "$RESOURCES_DIR/CommandLineToolIcons"
    cp -R "$HERE/Resources/CommandLineToolIcons/"* "$RESOURCES_DIR/CommandLineToolIcons/"
fi
for t in 1 2 3 4; do
    if [ -f "$HERE/Resources/HealthRabbit-Tier${t}-1024.png" ]; then
        cp "$HERE/Resources/HealthRabbit-Tier${t}-1024.png" "$RESOURCES_DIR/"
    fi
done
# 编译 PS Portal 串流画质增强原生 BPF 注入引擎 portal_engine
if [ -f "$HERE/scripts/portal_engine.c" ]; then
    mkdir -p "$HERE/Resources/Plugins/PSPortal"
    /usr/bin/clang -O2 -arch arm64 \
        "$HERE/scripts/portal_engine.c" \
        -o "$HERE/Resources/Plugins/PSPortal/portal_engine"
    chmod 755 "$HERE/Resources/Plugins/PSPortal/portal_engine"
fi

if [ -d "$HERE/Resources/Plugins" ]; then
    mkdir -p "$RESOURCES_DIR/Plugins"
    cp -R "$HERE/Resources/Plugins/"* "$RESOURCES_DIR/Plugins/"
fi
"$MACOS_DIR/$APP_NAME" --generate-icons "$ICON_TMP_DIR"
/usr/bin/iconutil -c icns "$ICON_TMP_DIR/AppIcon-Light.iconset" -o "$RESOURCES_DIR/AppIcon-Light.icns"
/usr/bin/iconutil -c icns "$ICON_TMP_DIR/AppIcon-Dark.iconset" -o "$RESOURCES_DIR/AppIcon-Dark.icns"
cp "$RESOURCES_DIR/AppIcon-Light.icns" "$RESOURCES_DIR/AppIcon.icns"

# 生成支持 macOS 26+ 系统深浅色模式自适应切换的 Assets.car (Icon Composer AppIcon.icon)
ICON_BUNDLE_DIR="$ICON_TMP_DIR/AppIcon.icon"
mkdir -p "$ICON_BUNDLE_DIR/Assets"
cp "$HERE/Resources/AppIcon-Light-1024.png" "$ICON_BUNDLE_DIR/Assets/AppIcon-Light-1024.png"
cp "$HERE/Resources/AppIcon-Dark-1024.png" "$ICON_BUNDLE_DIR/Assets/AppIcon-Dark-1024.png"
cat << 'ICONJSON' > "$ICON_BUNDLE_DIR/icon.json"
{
  "fill-specializations" : [
    {
      "value" : {
        "solid" : "extended-srgb:0.96863,0.95686,0.92549,1.00000"
      }
    },
    {
      "appearance" : "dark",
      "value" : {
        "solid" : "extended-srgb:0.06275,0.07451,0.12549,1.00000"
      }
    }
  ],
  "groups" : [
    {
      "layers" : [
        {
          "glass" : false,
          "hidden-specializations" : [
            {
              "value" : false
            },
            {
              "appearance" : "dark",
              "value" : true
            }
          ],
          "image-name" : "AppIcon-Light-1024.png",
          "name" : "AppIcon-Light-1024"
        },
        {
          "glass" : false,
          "hidden-specializations" : [
            {
              "value" : true
            },
            {
              "appearance" : "dark",
              "value" : false
            }
          ],
          "image-name" : "AppIcon-Dark-1024.png",
          "name" : "AppIcon-Dark-1024"
        }
      ],
      "shadow" : {
        "kind" : "none",
        "opacity" : 0
      },
      "translucency" : {
        "enabled" : false,
        "value" : 0
      }
    }
  ],
  "supported-platforms" : {
    "squares" : [
      "macOS"
    ]
  }
}
ICONJSON

/usr/bin/xcrun actool "$ICON_BUNDLE_DIR" \
    --compile "$RESOURCES_DIR" \
    --output-format human-readable-text \
    --notices --warnings --errors \
    --output-partial-info-plist "$ICON_TMP_DIR/assetcatalog_generated_info.plist" \
    --app-icon AppIcon \
    --include-all-app-icons \
    --enable-on-demand-resources NO \
    --development-region zh-Hans \
    --target-device mac \
    --minimum-deployment-target 26.0 \
    --platform macosx

if [ ! -s "$RESOURCES_DIR/Assets.car" ]; then
    echo "❌ Assets.car 未能生成" >&2
    exit 1
fi
if [ ! -f "$RESOURCES_DIR/AppIcon.icns" ]; then
    cp "$RESOURCES_DIR/AppIcon-Light.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

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
    <key>CFBundleIconName</key>
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
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>SysPulse 需要使用蓝牙功能读取妙控键盘、妙控鼠标、触控板及 AirPods 的真实电量状态。</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>SysPulse 需要访问局域网以发现 PS5、PS Portal 及其他局域网网络设备并进行通信测量。</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>SysPulse 需要在市电意外断开或用户点击推出时，向系统发送外置磁盘安全推出与断电保护自动化控制指令。</string>
</dict>
</plist>
EOF

echo "🔐 正在对应用包进行分层代码签名与隔离属性清理 (Designated Requirement: com.rabbit.syspulse)..."
/usr/bin/xattr -cr "$BUNDLE_DIR"
if [ -f "$MACOS_DIR/SysPulseUPSHelper" ]; then
    /usr/bin/codesign --force -s - -i "com.rabbit.syspulse.upshelper" "$MACOS_DIR/SysPulseUPSHelper"
fi
if [ -f "$MACOS_DIR/SysPulseOptimizeHelper" ]; then
    /usr/bin/codesign --force -s - -i "com.rabbit.syspulse.optimizehelper" "$MACOS_DIR/SysPulseOptimizeHelper"
fi
if [ -f "$MACOS_DIR/SysPulsePrivilegedHelper" ]; then
    /usr/bin/codesign --force -s - -i "com.rabbit.syspulse.privilegedhelper" "$MACOS_DIR/SysPulsePrivilegedHelper"
fi
if [ -f "$MACOS_DIR/SysPulseNodeShim" ]; then
    /usr/bin/codesign --force -s - -i "com.rabbit.syspulse.nodeshim" "$MACOS_DIR/SysPulseNodeShim"
fi
if [ -f "$RESOURCES_DIR/Plugins/PSPortal/portal_engine" ]; then
    /usr/bin/codesign --force -s - -i "com.rabbit.syspulse.portal-engine" "$RESOURCES_DIR/Plugins/PSPortal/portal_engine"
fi
/usr/bin/codesign --force -s - -r='designated => identifier "com.rabbit.syspulse"' "$BUNDLE_DIR"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$BUNDLE_DIR"

# 同步纯净 App 到主目录 build 下（文件名不带版本号）
mkdir -p "$HERE/../build"
rm -rf "$HERE/../build/$APP_NAME.app"
cp -R "$BUNDLE_DIR" "$HERE/../build/$APP_NAME.app"
/usr/bin/codesign --verify --deep --strict "$HERE/../build/$APP_NAME.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$HERE/../build/$APP_NAME.app" 2>/dev/null || true

echo "💿 正在生成可分享的 DMG 安装包 ($APP_NAME-v$VERSION.dmg)..."
DMG_STAGING="/tmp/syspulse-dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$BUNDLE_DIR" "$DMG_STAGING/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING/Applications"

DMG_OUTPUT="$HERE/../build/$APP_NAME-v$VERSION.dmg"
rm -f "$DMG_OUTPUT"
/usr/bin/hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_OUTPUT" -quiet
/usr/bin/xattr -c "$DMG_OUTPUT" 2>/dev/null || true
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

# 下次编译自动递增版本号
if [[ "$patch" != *"_"* ]]; then
    NEXT_PATCH=$((PATCH_NUM + 1))
    NEXT_VERSION="${major}.${minor}.${NEXT_PATCH}"
    echo "$NEXT_VERSION" > "$VERSION_FILE"
    echo "🔢 下一次编译版本将自动递增为: v$NEXT_VERSION"
elif [[ "$VERSION" =~ (.*_Test)([0-9]+)$ ]]; then
    PREFIX="${BASH_REMATCH[1]}"
    NUM="${BASH_REMATCH[2]}"
    NEXT_NUM=$((NUM + 1))
    NEXT_VERSION="${PREFIX}${NEXT_NUM}"
    echo "$NEXT_VERSION" > "$VERSION_FILE"
    echo "🔢 下一次编译测试版本将自动递增为: v$NEXT_VERSION"
else
    echo "🧪 当前为测试支线版本: v$VERSION"
fi
