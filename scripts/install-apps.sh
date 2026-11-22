#!/bin/bash
# 安装 dist/ 下的单一 .app 到应用目录（默认 ~/Applications）。
#
# 安全设计：
#   - 绝不杀进程、绝不改配置 —— 只复制 .app
#   - 目标已存在时默认拒绝覆盖，需要 --force
#   - 不探测、不迁移、不自动删除旧版 .app（旧版由用户手动退出并卸载）
#   - 若检测到旧版守护进程正在运行，明确提示手动处置步骤，由用户自行执行
# 用法: scripts/install-apps.sh [--force] [应用目录]
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$(pwd)"

APPS_DIR="${HOME}/Applications"
FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1 ;;
    -h|--help)
      echo "用法: scripts/install-apps.sh [--force] [应用目录]  (默认 ~/Applications)"
      exit 0 ;;
    *) APPS_DIR="$1" ;;
  esac
  shift
done

APP_NAME="Magpie-WebUI-Tunnel.app"
SRC="$REPO/dist/$APP_NAME"
if [[ ! -d "$SRC" ]]; then
  echo "error: $SRC 不存在 —— 先运行 scripts/build-apps.sh" >&2
  exit 1
fi

mkdir -p "$APPS_DIR"
DST="$APPS_DIR/$APP_NAME"
LEGACY_STATUS="$APPS_DIR/Magpie Tunnel Status.app"

if [[ -e "$DST" ]]; then
  if [[ "$FORCE" -ne 1 ]]; then
    echo "error: $DST 已存在。确认覆盖请加 --force（建议先退出正在运行的 Magpie-WebUI-Tunnel：退出应用会结束守护与所有隧道）" >&2
    exit 1
  fi
  echo "==> 覆盖 $DST"
  rm -rf "$DST"
fi

# 先复制到临时名再原子重命名，避免半成品目录
tmp="$APPS_DIR/.${APP_NAME}.incoming"
rm -rf "$tmp"
ditto "$SRC" "$tmp"
mv "$tmp" "$DST"
echo "==> 已安装 $DST"

if [[ -d "$LEGACY_STATUS" ]]; then
  cat <<NOTE

⚠  发现旧版独立的「${LEGACY_STATUS}」。
   新版把菜单栏和隧道守护合并成一个 App，旧的不会再被启动。本脚本不会删除它，
   确认不再需要后请手动拖进废纸篓：
     rm -rf '$LEGACY_STATUS'
NOTE
fi

if pgrep -f 'magpie-web-tunnel|magpie-tunneld' >/dev/null 2>&1; then
  cat <<'NOTE'

⚠  检测到隧道守护进程仍在运行（本脚本没有动它，也不会动它）。
   新版退出应用就会结束守护与所有隧道；从旧版切过来请手动执行：
     1. 退出旧的菜单栏应用（若菜单里没有退出项，用 pkill -f 'magpie-web-tunnel'）
     2. 确认守护已结束: pgrep -f 'magpie-web-tunnel|magpie-tunneld' 应无输出
     3. 把旧 .app（如 Magpie Web 隧道.app）拖进废纸篓
     4. 再打开刚装好的 Magpie-WebUI-Tunnel.app
NOTE
fi

echo
echo "完成。首次使用可运行:  open '$DST'"
