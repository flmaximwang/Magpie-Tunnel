#!/bin/bash
# 安装 dist/ 下的两个 .app 到应用目录（默认 ~/Applications）。
#
# 安全设计：
#   - 绝不杀进程、绝不改配置 —— 只复制 .app
#   - 目标已存在时默认拒绝覆盖，需要 --force
#   - 若检测到旧版守护进程正在运行，明确提示重启步骤，由用户手动执行
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

TUNNEL_SRC="$REPO/dist/Magpie Web 隧道.app"
STATUS_SRC="$REPO/dist/Magpie Tunnel Status.app"
for app in "$TUNNEL_SRC" "$STATUS_SRC"; do
  if [[ ! -d "$app" ]]; then
    echo "error: $app 不存在 —— 先运行 scripts/build-apps.sh" >&2
    exit 1
  fi
done

mkdir -p "$APPS_DIR"

install_one() {
  local src="$1" name
  name="$(basename "$src")"
  local dst="$APPS_DIR/$name"
  if [[ -e "$dst" ]]; then
    if [[ "$FORCE" -ne 1 ]]; then
      echo "error: $dst 已存在。确认覆盖请加 --force（正在运行的旧隧道不受影响，替换后手动重启）" >&2
      exit 1
    fi
    echo "==> 覆盖 $dst"
    rm -rf "$dst"
  fi
  # 先复制到临时名再原子重命名，避免半成品目录
  local tmp="$APPS_DIR/.${name}.incoming"
  rm -rf "$tmp"
  ditto "$src" "$tmp"
  mv "$tmp" "$dst"
  echo "==> 已安装 $dst"
}

install_one "$TUNNEL_SRC"
install_one "$STATUS_SRC"

if pgrep -f 'magpie-web-tunnel|magpie-tunneld' >/dev/null 2>&1; then
  cat <<'NOTE'

⚠  检测到隧道守护进程正在运行（本脚本没有动它）。
   要切换到新版本，请手动执行：
     1. 菜单栏 → 重启隧道守护
     2. 或命令行: pkill -f magpie-web-tunnel; pkill -f magpie-tunneld; \
        open -a "Magpie Web 隧道"; open -a "Magpie Tunnel Status"
NOTE
fi

echo
echo "完成。首次使用可运行:  open '$APPS_DIR/Magpie Web 隧道.app' && open '$APPS_DIR/Magpie Tunnel Status.app'"
