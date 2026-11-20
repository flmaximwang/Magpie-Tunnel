# Changelog

本项目的所有显著变更记录在此。格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本遵循 [SemVer](https://semver.org/lang/zh-CN/)。

## [1.2.0] - 2026-11-20

### 变更

- **Finder 图标换新**：白底圆角方片 + 背后的石红缎带环 + 一只飞过环心的黑喜鹊。缎带环被上方的翅膀遮住一段，下方的尾羽再从环前扫过，形成前后两层的纵深感。取代 1.1.0 的「拱门 + 栖停喜鹊 + 蓝绿虹彩尾羽」。
- **菜单栏图标同步重画**：改为飞越拱门的喜鹊剪影，翅膀在左、头尾在右，尾巴斜穿拱门。尾羽完整 = 全部就绪；尾羽在拱门处断开出一小块分离的羽毛 = 任一异常（含空配置）。仍是 Template Image，自动适配浅/深色与选中高亮。
- `MenuIcon` 的代码兜底（PNG 缺失时）改为按 36 单位坐标系重绘同一套 SVG 轮廓，含降级态的断尾缺口，替代旧的拱门 + 椭圆拼图版本。

### 升级

- `./scripts/build-apps.sh && ./scripts/install-apps.sh --force`，然后在菜单栏点「重启隧道守护」以让新包内的守护接管；配置、状态、日志原地复用。

## [1.1.0] - 2026-11-19

### 变更

- **两个 App 合成一个**：`Magpie Web 隧道.app` 现在同时是菜单栏入口和隧道守护的宿主。`Contents/MacOS/MagpieTunnelStatus` 是 `CFBundleExecutable`，包内 `magpie-tunneld` 由它拉起；打开 App 即启动隧道（已在跑则不动），菜单「重启隧道守护」= 先停再起，退出菜单栏不杀守护、隧道继续跑。`Magpie Tunnel Status.app` 不再构建。
- **菜单栏图标从 emoji 换成模板图**：`🔗` / `🔗⃠` 退役。新图标是一只栖在隧道拱门上的喜鹊，尾羽贯穿门洞表示全部就绪、尾羽在门洞中断开表示有异常。图标为 Template Image（黑 + alpha），自动适配浅色/深色菜单栏与选中高亮；无障碍标签同步为「magpie 隧道：全部就绪 / 有隧道异常」。
- **Finder 图标重画**：浅灰圆角底 + 石墨拱门 + 黑背白腹的喜鹊 + 蓝绿虹彩尾羽，与菜单栏图标共用同一套轮廓。
- 图标有了可复现的构建链：`resources/icon/*.svg` → `./scripts/build-icon.sh` → `resources/AppIcon.icns` + `resources/icon/MenuIcon-*.png`（生成物已提交，CI 不需要 rsvg-convert）。

### 新增

- `DaemonController` + `DaemonSystem` 协议：守护的检测/启动/重启决策全部可注入测试，12 个新测试只碰假实现，不 spawn、不 kill。
- `MenuIcon` 渲染层 + 4 个图标测试：18 pt 模板图、1x 与 @2x 双表征、纯黑 alpha、按状态缓存。
- `scripts/build-apps.sh` 打包单 App 时把 `MenuIcon-*.png` 一并放进 `Contents/Resources`；CI 校验图标资源、`CFBundleIdentifier` 与包内双可执行文件，并对打包后的二进制跑 `--smoke-test`。

### 移除

- `dist/Magpie Tunnel Status.app` 与 `CFBundleIdentifier com.maxim.magpie-tunnel-status`。
- `MenuState.iconEmoji`（由 `MenuIconState` 取代）。

### 升级

- `./scripts/build-apps.sh && ./scripts/install-apps.sh --force`，然后打开 `Magpie Web 隧道.app`。
- 首次启动会把旧的 bash 守护替换掉：先停旧进程（其 EXIT trap 会清掉 ssh 子进程），再由新 App 拉起包内 `magpie-tunneld`；`targets.conf`、`status/`、日志文件原地复用。
- 旧的 `Magpie Tunnel Status.app` 与它的登录项可以删除（安装脚本会提示路径；登录项用 `系统设置 → 通用 → 登录项` 移除）。
- 最低系统版本从 macOS 12 起（此前的 `LSMinimumSystemVersion` 写的是 11.0，但二进制实际 `minos` 一直是 12.0，二者现已对齐）。

## [1.0.0] - 2026-11-14

首个 Swift Package 版本。行为与旧 ad-hoc bash 守护 + 无版本状态 App 完全兼容（配置/状态/日志/URL/菜单不变），唯一有意差异见下。

### 新增

- **MagpieTunnelCore 核心库**：`TargetsParser`（targets.conf 解析/序列化，保留注释空行、坏行诊断）、`TunnelURLBuilder`（`?k=` URL 不变量）、`StatusStore`（原子写一行状态）、`RotatingFileLogger`（>2MB 轮转 `.1`）、`SingleInstanceLock`（flock + 旧版目录锁识别）、`TCPProbe`（非阻塞 connect 探测）、`TunnelPaths`（路径常量 + `MAGPIE_TUNNEL_*` 环境覆盖）
- **magpie-tunneld 隧道守护**（打包为 `Magpie Web 隧道.app`，替代 bash 版）
  - ssh 参数与旧版逐字节一致的硬化配置（BatchMode/ExitOnForwardFailure/KeepAlive 等）
  - 每目标独立监督线程：spawn → TCP 就绪探测 → 状态文件 → 断线 `ssh 断开 rc=<n>` → 指数退避重连（5s 起、×2、上限 60s；稳定运行 60s 后重置）
  - **差量热重载**：20s 周期按名字 diff，未变化且健康的隧道不再被重启（旧版每次全量重启）
  - 优雅退出：SIGTERM/SIGINT 杀整棵子进程组，无 PPID=1 孤儿；单实例 flock 锁，识别并尊重旧版 `tunnel.lock` 目录锁
- **MagpieTunnelStatus 菜单栏 App**（`Magpie Tunnel Status.app`）
  - 🔗 全部就绪 / 🔗⃠ 降级图标；摘要 `magpie 隧道 X/Y`；每目标 `✓/✗ 名字 localhost:端口`
  - 子菜单：打开 magpie / 复制链接 / 完整 URL；操作：刷新 / 编辑目标配置 / 打开隧道日志 / 重启隧道守护 / 退出菜单栏（隧道继续跑）
  - `--smoke-test` 无头模式与 CLI/env 路径覆盖，可在 CI 验证渲染
- **工程化**：Swift Package（macOS 11+，Swift 5 语言模式）、71 个测试（含 mock-ssh 黑盒集成测试）、`scripts/build-apps.sh`（构建 + ad-hoc 签名两 个 .app 到 dist/）、`scripts/install-apps.sh`（安全显式安装，绝不杀运行中的隧道）、GitHub Actions CI、README / docs/architecture / docs/configuration

### 兼容性

- 升级路径：`./scripts/install-apps.sh --force` 后菜单栏点「重启隧道守护」即可；配置、日志、状态文件原地复用
- 空配置文件旧版回退默认目标、新版跑 0 条 —— 唯一有意行为差异（避免幽灵隧道），其余状态文案（`端口未就绪`/`ssh 启动失败`/`ssh 断开 rc=<n>`/`配置移除`/`守护退出`）、URL 形式、文件路径全部保持
