# Magpie-WebUI-Tunnel

把本机不能直接访问的远端 magpie Web 服务，通过 SSH 本地端口转发变成 `http://127.0.0.1:<端口>/?k=<key>` 可打开的链接；一个菜单栏 App（内含隧道守护）实时显示每条隧道的健康状态。

从一套 ad-hoc bash 守护脚本 + 无版本管理的 Swift 状态 App，重写为结构清晰、有测试、有 CI 的 Swift Package 项目。**老用户数据继续可用**：bundle ID（`com.maxim.magpie-web-tunnel`）、配置目录、状态文件格式、日志文件名、URL 形式都不变。

## 组成

| 产物 | 说明 |
| --- | --- |
| `MagpieTunnelCore` | 核心库：配置解析、URL 构建、状态存储、日志轮转、单实例锁、TCP 探测 |
| `MagpieTunnelStatus`（打包为 `Magpie-WebUI-Tunnel.app`） | 菜单栏入口：喜鹊图标显示隧道状态 + 弹出面板（概况、逐条隧道、配置/日志入口） |
| `magpie-tunneld`（随包放在该 .app 内） | 隧道守护进程：为每个目标拉起一条硬化配置的 SSH 隧道并保活；由菜单栏应用管理生命周期 |

## 快速开始

### 安装发布版

从 [Releases](https://github.com/flmaximwang/Magpie-Tunnel/releases) 下载 `Magpie-WebUI-Tunnel-<版本>.zip`，解压后把 `Magpie-WebUI-Tunnel.app` 拖进 `~/Applications`（或 `/Applications`），双击打开即可。产物是 ad-hoc 签名（首次打开若被拦，右键 → 打开），内含 arm64 与 x86_64 两个架构。

### 从源码

```bash
# 测试 + 构建
swift test
./scripts/build-apps.sh

# 安装到 ~/Applications（目标已存在时需 --force；脚本只复制 .app，不杀进程）
./scripts/install-apps.sh

# 启动
open "$HOME/Applications/Magpie-WebUI-Tunnel.app"
```

一个 App 就够了：它是 `LSUIElement`（无 Dock 图标），打开后菜单栏出现喜鹊图标，同时按已保存配置拉起包内的隧道守护；**退出应用会一并结束守护进程和所有隧道**，重新打开应用再按配置把隧道拉起来。应用崩溃或被强制退出时同样会清理守护与 SSH 子进程，不会留下后台隧道。

## 配置

唯一需要编辑的文件：`~/Library/Application Support/MagpieWebTunnel/targets.conf`

```
# 注释行
名字|本地端口|SSH目标|远端端口|Web密钥
TC2C4G2026|3430|ubuntu@43.142.18.254|3430|3bdf4869eb195854f1f322fee217dc6d
ZLab4090D|3431|wangfanlin1@100.68.85.3|3430|
```

- 每行一条隧道；`Web密钥` 可留空（行尾保留 `|`），此时 URL 不带 `?k=` 参数
- 两种改法：点面板里的「隧道配置」在应用自带窗口里增删改（列表 + 表单，带校验、可撤销删除、保存前统一检查），或者直接编辑上面这个文件
- 保存即生效并**差量应用**：窗口里按「保存并应用」会立刻请求守护重读，只有收到守护确认才显示「已应用」；外部编辑最迟 20 秒后被轮询拾取。两种情况下未变化且健康的隧道都不会断开
- 改坏了一行？坏行被忽略并写入主日志诊断，其余行继续工作；配置窗口里坏行会列出来，可以原地修正
- 配置文件不存在时（仅首次启动）使用内置默认值（上面两条）；存在但为空、或运行中把文件删掉，都是一条隧道都不跑
- 草稿不会覆盖别人的修改：如果文件在这期间被别处改过，窗口会提示冲突并要求先「重新载入」

详细格式与诊断规则见 [docs/configuration.md](docs/configuration.md)，架构与文件布局见 [docs/architecture.md](docs/architecture.md)。

## URL 不变量

有 key：`http://127.0.0.1:<本地端口>/?k=<key>`（服务器种 400 天 cookie）
无 key：`http://127.0.0.1:<本地端口>/`

`?k=` 参数名与值逐一编码由 `TunnelURLBuilder` 保证，有单元测试锁定。

## 菜单栏面板

- 图标是一只飞过隧道拱门的喜鹊。尾羽完整表示全部就绪，尾羽有缺口表示任一隧道异常、状态未知或没有配置。
- 图标是模板图（Template Image），自动适配浅色/深色菜单栏，选中高亮也正确
- 点图标弹出面板：顶部一行副标题（如「2 条隧道，全部已连接」），中间每条隧道一行 —— 彩色圆点 + 名字 + 「打开 Magpie」/「复制链接」（仅在已连接时可用），第二行是状态与 `127.0.0.1:<端口>`；未连接时带上原因
- 状态有四种：已连接 / 连接中 / 未连接（附原因）/ 状态未知。读不到状态文件时显示「状态未知」而不是猜成「未连接」
- 一条都没配时显示「尚未配置隧道」+「添加隧道」；配置有坏行时显示「配置有 N 行错误，没有可用的隧道」+「修正配置」
- 底部是「隧道配置」「隧道日志」两个应用自带窗口的入口，以及「更多」（重启全部隧道 / 退出）。两个窗口可同时打开；重复点入口把已有窗口带到前台，窗口关了应用仍留在菜单栏
- 退出 Magpie-WebUI-Tunnel 会结束守护进程和所有隧道（不是只关菜单栏）；重新打开应用再按已保存配置启动隧道

图标是怎么来的：`resources/icon/app-icon.svg`（Finder 图标）与 `resources/icon/menu-icon-{healthy,degraded}.svg`（菜单栏模板图）是唯一来源，`./scripts/build-icon.sh` 生成 `resources/AppIcon.icns` 与 `resources/icon/MenuIcon-*.png`。生成物已提交，普通构建不需要 rsvg-convert。

## 运维

```bash
# 手动前台跑守护（便于排查），全路径可覆盖
.build/out/Products/Debug/MagpieTunnelDaemon --config /tmp/t.conf --status-dir /tmp/st ...

# 菜单栏 App 无头自检（打印面板模型后退出，不碰状态栏）
.build/out/Products/Debug/MagpieTunnelStatus --smoke-test --config /tmp/t.conf --status-dir /tmp/st
```

App 的路径参数是唯一真相：拉起包内守护时会把 `--config/--status-dir/--log-dir/--lock-dir/--ssh-bin/--owner-pid` 全部传给 `magpie-tunneld`（并继承 App 的 `MAGPIE_TUNNEL_*` 环境变量，参数优先），所以隔离路径启动的 App 不会去抢生产锁。

- 菜单栏 App 打的守护就是包内的 `Contents/MacOS/magpie-tunneld`：打开 App 时若无守护在跑则拉起（带上 `--owner-pid`），「更多」里的「重启全部隧道」= 先停再起。退出 App（含崩溃/被强退）会结束守护及其 SSH 子进程，所以没有「App 退出了隧道还在跑」的情况
- 主日志：`~/Library/Logs/magpie-web-tunnel.log`（>2MB 轮转为 `.1`）；「隧道日志」窗口默认看这一份，可切到单条隧道的日志
- 每条隧道日志：`~/Library/Logs/magpie-web-tunnel-<名字>.log`（SSH 自身输出）
- 状态文件：`~/Library/Application Support/MagpieWebTunnel/status/<名字>`（`up|<epoch>|port=<p>` / `down|<epoch>|<原因>`）
- 单实例锁：`~/Library/Application Support/MagpieWebTunnel/tunneld.lock`（flock；同时识别旧版 `tunnel.lock` 目录锁）
- 发版：`git tag v<版本> && git push --tags` 会触发 `.github/workflows/release.yml`，跑测试、构建通用二进制、打 zip 并自动创建 GitHub Release；版本号默认值在 `scripts/build-apps.sh` 顶部

## 兼容性保证

- **从旧版升级（`Magpie Web 隧道.app` 及更早的 bash 版）**：先退出旧版应用，确认守护进程也已结束 —— `pgrep -f 'magpie-web-tunnel|magpie-tunneld'` 应无输出（若还在跑，用 `pkill -f magpie-tunneld` 结束）。然后把旧 `Magpie Web 隧道.app`（以及更早的 `Magpie Tunnel Status.app`）手动拖进废纸篓，再解压安装新版 `Magpie-WebUI-Tunnel.app`。安装脚本**不会探测、迁移或自动删除**旧应用，只会在发现残留进程/旧 .app 时打印提示。
- 装好新版后配置、日志、状态文件原地复用：bundle ID 仍是 `com.maxim.magpie-web-tunnel`，配置目录仍是 `~/Library/Application Support/MagpieWebTunnel`，日志仍是 `~/Library/Logs/magpie-web-tunnel*.log`。
- 旧 bash 守护的 ssh 参数、重连节奏（5s 起步指数退避、上限 60s）、状态文案（`端口未就绪` / `ssh 启动失败` / `ssh 断开 rc=<n>` / `配置移除` / `守护退出`）逐项对齐
- 有意的行为差异：旧版配置 reload 时**重启所有**隧道，新版差量处理；旧版关掉菜单栏后守护继续跑，新版退出应用即结束守护与所有隧道
- macOS 12+，Swift Package Manager，`swift build` 即可出产物，ad-hoc 签名无需开发者证书
