# 架构

```text
targets.conf ──解析──▶ [TargetConfig] ──守护进程 magpie-tunneld──▶ ssh -N -L 127.0.0.1:<lport>:127.0.0.1:<rport> <host>
                             │                                            │
                             │ 20s 差量 reload                            │ TCP 探测 127.0.0.1:<lport>
                             ▼                                            ▼
                     status/<名字>  up|<epoch>|port=<p>            magpie-web-tunnel-<名字>.log
                             │
                             ▼  ~10s 轮询
                     MagpieTunnelStatus 菜单栏：🔗/🔗⃠ + ✓/✗ + 操作
```

## Swift Package 布局

```text
Sources/MagpieTunnelCore/        # 核心库（全部纯逻辑，可测）
├── TargetConfig.swift           #   name|lport|ssh|rport|key 五元组；builtInDefaults
├── TargetsParser.swift          #   解析/序列化 targets.conf：保留注释与空行、诊断坏行
├── TunnelURLBuilder.swift       #   http://127.0.0.1:<p>/?k=<key>（percent-encode，绝不 ?key=）
├── StatusStore.swift            #   status/<名字> 原子写（tmp+rename(2)）、容错读
├── RotatingFileLogger.swift     #   "[YYYY-MM-DD HH:MM:SS] msg"，>2MB → .1（覆盖旧 .1）
├── SingleInstanceLock.swift     #   flock 锁 + 识别旧版 tunnel.lock 目录锁
├── TCPProbe.swift               #   非阻塞 connect + poll 探测
└── TunnelPaths.swift            #   全部路径常量 + MAGPIE_TUNNEL_* 环境变量覆盖

Sources/magpie-tunneld/          # 隧道守护进程（打包成 Magpie Web 隧道.app）
├── DaemonOptions.swift          #   CLI 解析（--config 等，错误 exit 64）
├── SSHProcess.swift             #   posix_spawnp + 独立进程组 + dup2 到隧道日志；
│                                #   ssh 参数与旧 bash 版逐字节一致（BatchMode 等硬化项）
├── TargetSupervisor.swift       #   每目标一个线程：spawn → 探测就绪 → 写状态 → 阻塞等待
│                                #   → down "ssh 断开 rc=<n>" → 指数退避重连（5s→60s，稳定 60s 后重置）
├── Daemon.swift                 #   单实例锁、SIGTERM/SIGINT 优雅退出（杀整个子进程组）、
│                                #   20s 差量 reload（按名字 diff：增/删/改/不动）
└── main.swift                   #   入口

Sources/MagpieTunnelStatus/      # 菜单栏状态 App（Magpie Tunnel Status.app）
├── MenuStateBuilder.swift       #   纯模型：摘要 "magpie 隧道 X/Y"、✓/✗ 行、🔗/🔗⃠
├── StatusViewModel.swift        #   读配置 + 状态目录 → MenuState（配置缺失回退默认值）
├── AppDelegate.swift            #   NSStatusItem/NSMenu 接线 + 五个操作动作
└── main.swift                   #   CLI/env 路径覆盖 + --smoke-test 无头模式
```

## 关键设计决策

**为什么守护每个目标一个 `Thread` 而不是一个事件循环？**
目标数量是个位数；每线程的阻塞 `wait()` 天然序列化「等子进程退出 → 写状态 → 退避重连」这条状态机，可读性远高于 select/kqueue 复用。线程内所有 sleep 都是 0.1s 粒度的可中断睡眠，退出延迟有界。

**子进程为什么用 `posix_spawnp` + `POSIX_SPAWN_SETPGROUP`？**
ssh 的 stdout/stderr 直接 `dup2` 到该隧道的日志文件（与旧版 `>> log 2>&1` 等价）；独立进程组保证 `kill(-pid)` 能杀干净整棵子树，SIGTERM 优雅退出不留下 PPID=1 的孤儿（集成测试用 pgrep 断言过）。

**差量 reload 怎么做到「健康隧道不断」？**
以 `name` 为主键 diff 新旧配置：`TargetConfig` 相等的条目完全不碰（不 spawn、不写状态）；变化的 stop→start；消失的 stop 并写 `down|…|配置移除`。集成测试用 spawn 计数断言未变目标恰好 spawn 1 次。

**状态文件为什么用 `rename(2)` 而不是 `FileManager.moveItem`？**
`moveItem` 目标已存在时抛错；`rename` 原子覆盖，菜单栏轮询永远读到完整的一行。写法是同目录 tmp 文件写满后 rename，不留残骸（有测试）。

**菜单栏 App 如何做到无头可测？**
内容决策全部在 `MenuStateBuilder`（纯函数）与 `StatusViewModel`（只碰文件系统）；`AppDelegate` 只做 NSMenu 渲染。`--smoke-test` 模式不创建 `NSStatusItem`，直接打印菜单内容退出 —— CI 没有 WindowServer 也能验证端到端渲染。

**单实例与旧锁共存？**
新锁是 `tunneld.lock` 文件上的 flock；启动时若发现旧版 `tunnel.lock` **目录锁**里有活着的 pid（旧 bash 守护还在跑）同样拒绝启动，pid 已死则清掉目录锁继续 —— 旧→新滚动升级不会出现双守护。

## 文件系统足迹（与旧版逐路径一致）

| 路径 | 内容 |
| --- | --- |
| `~/Library/Application Support/MagpieWebTunnel/targets.conf` | 配置（唯一用户编辑点） |
| `~/Library/Application Support/MagpieWebTunnel/status/<名字>` | 隧道状态，一行 |
| `~/Library/Application Support/MagpieWebTunnel/tunneld.lock` | 新版 flock 单实例锁 |
| `~/Library/Application Support/MagpieWebTunnel/tunnel.lock/` | 旧版目录锁（只读识别，不创建） |
| `~/Library/Logs/magpie-web-tunnel.log` | 守护主日志（轮转 .1） |
| `~/Library/Logs/magpie-web-tunnel-<名字>.log` | 每隧道 ssh 日志（轮转 .1） |

## 测试策略

- **MagpieTunnelCoreTests（51 个）**：解析/序列化字节级往返、URL 不变量、状态原子写、日志轮转、锁竞争、TCP 探测（真实 `/usr/bin/nc -l` 监听）、路径布局与环境变量
- **MagpieTunnelDaemonTests（7 个）**：黑盒拉起真实构建的二进制 + mock ssh 脚本 + 随机空闲端口；覆盖就绪/SIGTERM 无孤儿/断线重连/差量 reload/换配置重启/双实例拒绝/失败退避
- **MagpieTunnelStatusTests（13 个）**：菜单模型全状态矩阵、ViewModel 文件驱动刷新、二进制 `--smoke-test` 端到端输出

所有集成测试只用临时目录、mock ssh、随机端口，绝不触碰真实的 `~/Library/Application Support/MagpieWebTunnel`、`~/Applications` 或生产隧道。
