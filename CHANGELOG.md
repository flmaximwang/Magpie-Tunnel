# Changelog

本项目的所有显著变更记录在此。格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本遵循 [SemVer](https://semver.org/lang/zh-CN/)。

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
