#!/bin/bash
# Build ONE macOS app bundle into dist/:
#
#   dist/Magpie Web 隧道.app   — menu-bar entry (CFBundleExecutable) plus the
#                                bundled `magpie-tunneld` daemon in Contents/MacOS
#
# The daemon is a plain child process of the menu-bar app: opening the app
# starts it (if not already running), the menu's restart action stops and
# starts it, and quitting the app leaves it running — the tunnels keep serving.
#
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

APP="$DIST/Magpie Web 隧道.app"
LEGACY_STATUS_APP="$DIST/Magpie Tunnel Status.app"

echo "==> 重建 $DIST"
rm -rf "$APP" "$LEGACY_STATUS_APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Menu-bar app is the bundle's main executable; the daemon ships beside it so
# DaemonController.bundledDaemonPath() finds it at Contents/MacOS/magpie-tunneld.
install -m 0755 "$PRODUCTS_DIR/MagpieTunnelStatus" "$APP/Contents/MacOS/MagpieTunnelStatus"
install -m 0755 "$PRODUCTS_DIR/MagpieTunnelDaemon" "$APP/Contents/MacOS/magpie-tunneld"

install -m 0644 "$REPO/resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
for state in healthy degraded; do
  install -m 0644 "$REPO/resources/icon/MenuIcon-$state.png" \
                  "$APP/Contents/Resources/MenuIcon-$state.png"
  install -m 0644 "$REPO/resources/icon/MenuIcon-$state@2x.png" \
                  "$APP/Contents/Resources/MenuIcon-$state@2x.png"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>CFBundleDisplayName</key>
	<string>Magpie Web 隧道</string>
	<key>CFBundleExecutable</key>
	<string>MagpieTunnelStatus</string>
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
codesign --force --sign - "$APP"

echo "==> 完成"
codesign --verify --deep "$APP"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
echo "    $APP"
echo "    ├─ Contents/MacOS/MagpieTunnelStatus  (菜单栏)"
echo "    └─ Contents/MacOS/magpie-tunneld      (隧道守护)"
