#!/bin/bash
# Build the two .app bundles into dist/:
#   dist/Magpie Web 隧道.app     — magpie-tunneld 隧道守护 (LSUIElement 后台运行)
#   dist/Magpie Tunnel Status.app — MagpieTunnelStatus 菜单栏状态 (LSUIElement)
# Ad-hoc codesign (codesign -s -), no developer certificate needed.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$(pwd)"

VERSION="${MAGPIE_TUNNEL_VERSION:-1.0}"
BUILD_NUMBER="${MAGPIE_TUNNEL_BUILD:-1}"
CONFIGURATION="${MAGPIE_TUNNEL_CONFIGURATION:-release}"
DIST="$REPO/dist"

echo "==> swift build -c $CONFIGURATION"
swift build -c "$CONFIGURATION"

# SPM 6.4 puts products under .build/out/Products/<Config>/ (product names,
# not target names); older layouts keep .build/<config>/. Probe both.
PRODUCTS_DIR=""
for candidate in ".build/out/Products/$CONFIGURATION" \
                  ".build/$CONFIGURATION" \
                  ".build/arm64-apple-macosx/$CONFIGURATION"; do
  if [[ -x "$candidate/MagpieTunnelDaemon" && -x "$candidate/MagpieTunnelStatus" ]]; then
    PRODUCTS_DIR="$candidate"
    break
  fi
done
if [[ -z "$PRODUCTS_DIR" ]]; then
  echo "error: 找不到构建产物 MagpieTunnelDaemon/MagpieTunnelStatus (搜索了 .build)" >&2
  exit 1
fi
echo "==> 使用构建产物: $PRODUCTS_DIR"

TUNNEL_APP="$DIST/Magpie Web 隧道.app"
STATUS_APP="$DIST/Magpie Tunnel Status.app"

echo "==> 重建 $DIST"
rm -rf "$TUNNEL_APP" "$STATUS_APP"
mkdir -p "$TUNNEL_APP/Contents/MacOS" "$TUNNEL_APP/Contents/Resources" \
         "$STATUS_APP/Contents/MacOS"

install -m 0755 "$PRODUCTS_DIR/MagpieTunnelDaemon" "$TUNNEL_APP/Contents/MacOS/magpie-web-tunnel"
install -m 0644 "$REPO/resources/AppIcon.icns" "$TUNNEL_APP/Contents/Resources/AppIcon.icns"

install -m 0755 "$PRODUCTS_DIR/MagpieTunnelStatus" "$STATUS_APP/Contents/MacOS/MagpieTunnelStatus"

cat > "$TUNNEL_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>CFBundleDisplayName</key>
	<string>Magpie Web 隧道</string>
	<key>CFBundleExecutable</key>
	<string>magpie-web-tunnel</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.maxim.magpie-web-tunnel</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Magpie Web 隧道</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

cat > "$STATUS_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>CFBundleDisplayName</key>
	<string>Magpie 隧道状态</string>
	<key>CFBundleExecutable</key>
	<string>MagpieTunnelStatus</string>
	<key>CFBundleIdentifier</key>
	<string>com.maxim.magpie-tunnel-status</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>MagpieTunnelStatus</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	<key>LSMinimumSystemVersion</key>
	<string>11.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

echo "==> ad-hoc codesign"
codesign --force --sign - "$TUNNEL_APP"
codesign --force --sign - "$STATUS_APP"

echo "==> 完成"
codesign --verify --deep "$TUNNEL_APP" && codesign --verify --deep "$STATUS_APP"
echo "    $TUNNEL_APP"
echo "    $STATUS_APP"
