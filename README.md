# Magpie-Tunnel

把本机不能直接访问的远端 magpie Web 服务，通过 SSH 本地端口转发变成 `http://127.0.0.1:<端口>/?k=<key>` 可打开的链接；一个菜单栏 App（内含隧道守护）实时显示每条隧道的健康状态。

从一套 ad-hoc bash 守护脚本 + 无版本管理的 Swift 状态 App，重写为结构清晰、有测试、有 CI 的 Swift Package 项目。**行为与旧版完全兼容**：配置格式、状态文件格式、日志文件名、URL 形式、菜单结构全部不变。

## 组成

| 产物 | 说明 |
| --- | --- |
| `MagpieTunnelCore` | 核心库：配置解析、URL 构建、状态存储、日志轮转、单实例锁、TCP 探测 |
| `MagpieTunnelStatus`（打包为 `Magpie Web 隧道.app`） | 菜单栏入口：喜鹊图标显示隧道状态 + 每条隧道 ✓/✗ + 快捷操作 |
| `magpie-tunneld`（随包放在该 .app 内） | 隧道守护进程：为每个目标拉起一条硬化配置的 SSH 隧道并保活 |

## 快速开始

```bash
# 测试 + 构建
swift test
./scripts/build-apps.sh

# 安装到 ~/Applications（目标已存在时需 --force；绝不杀正在跑的隧道）
./scripts/install-apps.sh

# 启动
open "$HOME/Applications/Magpie Web 隧道.app"
```

一个 App 就够了：它是 `LSUIElement`（无 Dock 图标），打开后菜单栏出现喜鹊图标，同时自动拉起包内的隧道守护；关掉菜单栏（退出）后守护继续跑，隧道不断。

## 配置

唯一需要编辑的文件：`~/Library/Application Support/MagpieWebTunnel/targets.conf`

```
# 注释行
名字|本地端口|SSH目标|远端端口|Web密钥
TC2C4G2026|3430|ubuntu@43.142.18.254|3430|3bdf4869eb195854f1f322fee217dc6d
ZLab4090D|3431|wangfanlin1@100.68.85.3|3430|
```

- 每行一条隧道；`Web密钥` 可留空（行尾保留 `|`），此时 URL 不带 `?k=` 参数
- 保存即生效：守护进程每 20 秒差量重载 —— **未变化且健康的隧道不会断开**，只启停变化的条目
- 改坏了一行？坏行被忽略并写入主日志诊断，其余行继续工作
- 配置文件不存在时使用内置默认值（上面两条）；存在但为空则一条隧道都不跑

详细格式与诊断规则见 [docs/configuration.md](docs/configuration.md)，架构与文件布局见 [docs/architecture.md](docs/architecture.md)。

## URL 不变量

有 key：`http://127.0.0.1:<本地端口>/?k=<key>`（服务器种 400 天 cookie）
无 key：`http://127.0.0.1:<本地端口>/`

`?k=` 参数名与值逐一编码由 `TunnelURLBuilder` 保证，有单元测试锁定。

## 菜单栏状态

- 图标是一只栖在隧道拱门上的喜鹊：尾羽贯穿门洞 = 全部就绪；尾羽在门洞中断开 = 任一异常（含空配置）
- 图标是模板图（Template Image），自动适配浅色/深色菜单栏，选中高亮也正确
- 摘要行 `magpie 隧道 X/Y`；每条隧道 `✓/✗ 名字 localhost:端口`
- 子菜单：打开 magpie / 复制链接 / 完整 URL
- 底部操作：刷新、编辑目标配置、打开隧道日志、重启隧道守护、退出菜单栏（隧道继续跑）

图标是怎么来的：`resources/icon/app-icon.svg`（Finder 图标）与 `resources/icon/menu-icon-{healthy,degraded}.svg`（菜单栏模板图）是唯一来源，`./scripts/build-icon.sh` 生成 `resources/AppIcon.icns` 与 `resources/icon/MenuIcon-*.png`。生成物已提交，普通构建不需要 rsvg-convert。

## 运维

```bash
# 手动前台跑守护（便于排查），全路径可覆盖
.build/out/Products/Debug/MagpieTunnelDaemon --config /tmp/t.conf --status-dir /tmp/st ...

# 菜单栏 App 无头自检（打印菜单内容后退出，不碰状态栏）
.build/out/Products/Debug/MagpieTunnelStatus --smoke-test --config /tmp/t.conf --status-dir /tmp/st
```

- 菜单栏 App 打的守护就是包内的 `Contents/MacOS/magpie-tunneld`；打开 App 时若无守护在跑则拉起，菜单「重启隧道守护」= 先停再起
- 主日志：`~/Library/Logs/magpie-web-tunnel.log`（>2MB 轮转为 `.1`）
- 每条隧道日志：`~/Library/Logs/magpie-web-tunnel-<名字>.log`（SSH 自身输出）
- 状态文件：`~/Library/Application Support/MagpieWebTunnel/status/<名字>`（`up|<epoch>|port=<p>` / `down|<epoch>|<原因>`）
- 单实例锁：`~/Library/Application Support/MagpieWebTunnel/tunneld.lock`（flock；同时识别旧版 `tunnel.lock` 目录锁）

## 兼容性保证

- 从旧版升级：直接 `./scripts/install-apps.sh --force`，然后打开 App 点「重启隧道守护」。配置、日志、状态文件原地复用；旧的两 App 布局可整体删除（安装脚本会提示）
- 旧 bash 守护的 ssh 参数、重连节奏（5s 起步指数退避、上限 60s）、状态文案（`端口未就绪` / `ssh 启动失败` / `ssh 断开 rc=<n>` / `配置移除` / `守护退出`）逐项对齐
- 唯一有意的行为差异：旧版配置 reload 时**重启所有**隧道；新版差量处理
- macOS 11+，Swift Package Manager，`swift build` 即可出产物，ad-hoc 签名无需开发者证书
