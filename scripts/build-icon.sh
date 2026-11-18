#!/bin/bash
# Regenerate the icon assets from the SVG sources in resources/icon/:
#
#   resources/AppIcon.icns           — Finder/Dock icon of the .app bundle
#   resources/icon/MenuIcon-*.png    — menu-bar template artwork (18 pt / 36 px)
#
# The generated files are committed, so a normal build (and CI) does NOT need
# rsvg-convert. Only run this when the artwork changes.
#
# Requires: rsvg-convert (brew install librsvg), iconutil (Xcode CLT), sips.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$(pwd)"
SRC="$REPO/resources/icon"

for tool in rsvg-convert iconutil sips; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: 需要 $tool（rsvg-convert 可用 brew install librsvg 安装）" >&2
    exit 1
  fi
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> App 图标: app-icon.svg → resources/AppIcon.icns"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
# Apple's required iconset slots: 16..512 at 1x, plus each @2x.
for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
            "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
            "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
  read -r px name <<<"$spec"
  rsvg-convert -w "$px" -h "$px" "$SRC/app-icon.svg" -o "$ICONSET/$name.png"
done
iconutil -c icns "$ICONSET" -o "$REPO/resources/AppIcon.icns"

echo "==> 菜单栏模板图标: menu-icon-*.svg → MenuIcon-*.png (黑 + 透明)"
# Template images must be pure black with alpha; AppKit tints them for light
# and dark menu bars. Two states, each at 1x (18 px) and @2x (36 px).
for state in healthy degraded; do
  for px in 18 36; do
    rsvg-convert -w "$px" -h "$px" "$SRC/menu-icon-$state.svg" -o "$WORK/raw.png"
    # Flatten onto transparent black so anti-aliased edges keep their alpha.
    magick_bin="$(command -v magick || command -v convert || true)"
    if [[ -n "$magick_bin" ]]; then
      # Force every pixel to black, keeping the alpha channel untouched, and
      # drop metadata so re-running this script produces byte-identical files.
      "$magick_bin" "$WORK/raw.png" -fill black -colorize 100% \
        -strip -define png:exclude-chunks=date,time "$WORK/black.png"
      mv "$WORK/black.png" "$WORK/raw.png"
    fi
    if [[ "$px" -eq 18 ]]; then
      out="$SRC/MenuIcon-$state.png"
    else
      out="$SRC/MenuIcon-$state@2x.png"
    fi
    cp "$WORK/raw.png" "$out"
  done
done

echo "==> 完成"
sips -g pixelWidth -g pixelHeight "$SRC/MenuIcon-healthy.png" \
                            "$SRC/MenuIcon-healthy@2x.png" | sed 's/^/    /'
echo "    resources/AppIcon.icns ($(du -h "$REPO/resources/AppIcon.icns" | cut -f1))"
