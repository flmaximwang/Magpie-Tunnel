# 架构

```text
targets.conf ──解析──▶ [TargetConfig] ──守护进程 magpie-tunneld──▶ ssh -N -L 127.0.0.1:<lport>:127.0.0.1:<rport> <host>
     ▲                       │                                            │
     │ 保存并应用             │ 20s 差量 reload / 0.25s 即时重读            │ TCP 探测 127.0.0.1:<lport>
     │ reload.request/ack     ▼                                            ▼
     │               status/<名字>  up|connecting|down|<epoch>|detail   magpie-web-tunnel-<名字>.log
     │                       │
     │                       ▼  ~10s 轮询（面板打开时随刷新重建）
     └── 隧道配置窗口 ◀── MagpieTunnelStatus 菜单栏：喜鹊图标 + 弹出面板
        隧道日志窗口          （就是 Magpie-WebUI-Tunnel.app 本身；打开时拉起包内 magpie-tunneld）
```

## Swift Package 布局

```text
Sources/MagpieTunnelCore/        # 核心库（全部纯逻辑，可测）
├── TargetConfig.swift           #   name|lport|ssh|rport|key 五元组；builtInDefaults
├── TargetsParser.swift          #   解析/序列化 targets.conf：保留注释与空行、诊断坏行
├── TunnelURLBuilder.swift       #   http://127.0.0.1:<p>/?k=<key>（percent-encode，绝不 ?key=）
├── ConfigDocument.swift         #   逐行解析 targets.conf：保留注释/空行，坏行带行号与原因
│                                #   行级校验 parseRow：守护与配置窗口共用同一套规则
├── ConfigDraft.swift            #   配置窗口的草稿模型：增/改/删/撤销删除、字段级校验、
│                                #   保存前阻断检查、保留注释的序列化
├── ConfigFile.swift             #   配置文件快照（inode+size+mtime）与 tmp+rename 原子写
├── ReloadCoordinator.swift      #   App↔守护的即时重读会合点：reload.request / reload.ack
│                                #   + FNV-1a 内容摘要，让「已应用」可证
├── DaemonOwner.swift            #   daemon.owner（daemonPID|appPID|epoch）：守护归属记录
├── LogTail.swift                #   日志增量读取（识别轮转/截断）+ 不区分大小写搜索
├── StatusStore.swift            #   status/<名字> 原子写（tmp+rename(2)）、容错读
├── RotatingFileLogger.swift     #   "[YYYY-MM-DD HH:MM:SS] msg"，>2MB → .1（覆盖旧 .1）
├── SingleInstanceLock.swift     #   flock 锁 + 识别旧版 tunnel.lock 目录锁 + isAlive(pid)
├── TCPProbe.swift               #   非阻塞 connect + poll 探测
└── TunnelPaths.swift            #   全部路径常量 + MAGPIE_TUNNEL_* 环境变量覆盖

Sources/magpie-tunneld/          # 隧道守护进程（打包成 Magpie-WebUI-Tunnel.app）
├── DaemonOptions.swift          #   CLI 解析（--config 等，错误 exit 64）
├── SSHProcess.swift             #   posix_spawnp + 独立进程组 + dup2 到隧道日志；
│                                #   ssh 参数与旧 bash 版逐字节一致（BatchMode 等硬化项）
├── TargetSupervisor.swift       #   每目标一个线程：spawn → 写 connecting → 探测就绪 → 写状态
│                                #   → 阻塞等待 → down "ssh 断开 rc=<n>" → 指数退避重连（5s→60s）
├── Daemon.swift                 #   单实例锁、SIGTERM/SIGINT 优雅退出（杀整个子进程组）、
│                                #   20s 差量 reload + 0.25s 即时重读请求、App 归属看门狗
└── main.swift                   #   入口

Sources/MagpieTunnelStatus/      # 菜单栏入口（Magpie-WebUI-Tunnel.app 的 CFBundleExecutable）
├── PanelModel.swift             #   纯模型：TunnelConnectionState / TunnelRow / PanelEmptyState
│                                #   PanelStateBuilder：配置 + 状态 → 副标题、空态、图标状态
├── PanelViewController.swift    #   弹出面板：概况、隧道行、空态按钮、隧道配置/隧道日志/更多
├── ConfigEditorModel.swift      #   配置窗口的视图无关模型：表单、待删除确认、保存结果
├── ConfigWindowController.swift #   配置窗口：列表 + 表单、草稿、冲突提示、保存并应用
├── LogWindowController.swift    #   日志窗口：来源下拉、跟随/暂停/搜索/复制、轮转后继续
├── MenuIcon.swift               #   菜单栏模板图：读 MenuIcon-<state>.png，缺失时用绘制兜底
├── DaemonController.swift       #   守护生命周期：归属判断（daemon.owner）、立即重读确认、
│                                #   重启/停止；App 退出时结束守护
├── StatusViewModel.swift        #   读配置 + 状态目录 → PanelState（缺文件 = 零目标）
├── AppDelegate.swift            #   NSStatusItem/NSPopover 接线、两个窗口复用、退出确认
└── main.swift                   #   CLI/env 路径覆盖 + --smoke-test 无头模式

resources/icon/                  # 图标唯一来源（SVG）+ 生成的模板 PNG
├── app-icon.svg                 #   Finder 图标（纯白圆角底 + 石红缎带环 + 蓝黑喜鹊）
├── menu-icon-healthy.svg        #   菜单栏模板图，尾羽完整
├── menu-icon-degraded.svg       #   菜单栏模板图，尾羽有缺口
└── MenuIcon-*.png               #   build-icon.sh 生成，已提交
scripts/build-icon.sh            # SVG → resources/AppIcon.icns + MenuIcon PNG（平时不用跑）
```

## 关键设计决策

**为什么守护每个目标一个 `Thread` 而不是一个事件循环？**
目标数量是个位数；每线程的阻塞 `wait()` 天然序列化「等子进程退出 → 写状态 → 退避重连」这条状态机，可读性远高于 select/kqueue 复用。线程内所有 sleep 都是 0.1s 粒度的可中断睡眠，退出延迟有界。

**子进程为什么用 `posix_spawnp` + `POSIX_SPAWN_SETPGROUP`？**
ssh 的 stdout/stderr 直接 `dup2` 到该隧道的日志文件（与旧版 `>> log 2>&1` 等价）；独立进程组保证 `kill(-pid)` 能杀干净整棵子树，SIGTERM 优雅退出不留下 PPID=1 的孤儿（集成测试用 pgrep 断言过）。

**差量 reload 怎么做到「健康隧道不断」？**
以 `name` 为主键 diff 新旧配置：`TargetConfig` 相等的条目完全不碰（不 spawn、不写状态）；变化的 stop→start；消失的 stop 并写 `down|…|配置移除`。集成测试用 spawn 计数断言未变目标恰好 spawn 1 次。

**「保存并应用」为什么不是「保存后等 20 秒」？**
配置窗口写完文件立刻写一份 `reload.request`（请求 id + 文件内容摘要），守护每 0.25s 扫一次，读到就立刻按名字差量 apply，并把实际读到的内容摘要连同目标数写进 `reload.ack`。App 只在 ack 的请求 id 与本次请求一致时显示「已应用」；超时或守护不在则显示「配置已保存，尚未确认应用」并指到日志。摘要对不上（文件在请求后被别人改了）时 ack 带 `配置文件在请求后被修改`，不会谎报。这样「保存成功」与「应用成功」始终是两件可分辨的事。

**配置文件为什么既有轮询重读又支持显式请求？**
轮询兜住外部编辑（终端里改 `targets.conf`、`git checkout` 回来）；显式请求兜住窗口里的保存。两条路径共用同一个 `readConfigExplicitly` + `apply`，区别只在读文件失败时的处理：轮询保持现有目标，显式请求回一条 failed ack。

**为什么「文件不存在」等于零目标，而不是内置默认值？**
删掉最后一条隧道后保存，写出的就是一个没有目标行的文件——如果任何一处回退到 `builtInDefaults`，刚删掉的隧道就会复活。所以只有守护**首次启动**且配置缺失时才回退默认值（旧版的兼容行为，`--no-default-targets` 可关），运行中的重读与面板显示一律按「没有配置 = 没有隧道」。

**未保存的草稿如何防止覆盖别人的编辑？**
`ConfigFileSnapshot` 记下读入时的 `(device, inode, size, mtime)`；保存前重新 stat，只要 identity 变了就判定「文件已在别处被修改」，保留草稿、显示冲突条与「重新载入」，绝不覆盖。写入本身是同目录 tmp + `rename(2)`，守护永远读不到半截文件。

**状态文件为什么用 `rename(2)` 而不是 `FileManager.moveItem`？**
`moveItem` 目标已存在时抛错；`rename` 原子覆盖，菜单栏轮询永远读到完整的一行。写法是同目录 tmp 文件写满后 rename，不留残骸（有测试）。

**菜单栏 App 如何做到无头可测？**
内容决策全部在 `PanelStateBuilder`（纯函数）与 `StatusViewModel`（只碰文件系统）；`PanelViewController`/`AppDelegate` 只做渲染与接线。`--smoke-test` 模式不创建 `NSStatusItem`，直接打印面板模型后退出 —— CI 没有 WindowServer 也能验证端到端输出。

**为什么缺状态文件显示「状态未知」而不是「未连接」？**
`connecting` 只在守护真的在 spawn 后、探测成功前写（`TargetSupervisor`）。没有这行（守护没跑、刚启动、状态目录被清）说明**没有可信信息**，说成「未连接」是编造结论。只有读得到 `down|…|<原因>` 时才显示「未连接」并带上原因。

**为什么守护仍是独立进程？**
隧道逻辑与菜单栏 UI 的崩溃域分开：UI 卡住不影响隧道保活，守护也不会因为绘制失败被杀；但生命周期由 App 掌管。守护启动时写 `daemon.owner`（`daemonPID|appPID|epoch`）并每 2s 检查 App 是否还活着，App 一死（含崩溃、`kill -9`）就停掉全部 supervisor 并退出。App 这边 `DaemonController` 只认「owner 里的 daemonPID 与 appPID 都是自己」的守护，否则先 SIGTERM 旧的再 spawn 带 `--owner-pid` 的新守护 —— 重复打开 App 不会起第二个守护，也不会让上一个 App 遗留的守护继续跑。拉起的守护**总是**收到 App 自己的 `--config/--status-dir/--log-dir/--lock-dir/--ssh-bin`（外加 App 环境的副本）：隔离路径启动的 App 不会让守护回落到 `~/Library/Application Support/MagpieWebTunnel` 的默认锁，因此不会抢生产锁，也不会让 App 把生产守护当作「上一轮遗留」SIGTERM 掉。

**单实例与旧锁共存？**
新锁是 `tunneld.lock` 文件上的 flock；启动时若发现旧版 `tunnel.lock` **目录锁**里有活着的 pid（旧 bash 守护还在跑）同样拒绝启动，pid 已死则清掉目录锁继续 —— 旧→新滚动升级不会出现双守护。

## 文件系统足迹（与旧版逐路径一致）

| 路径 | 内容 |
| --- | --- |
| `~/Library/Application Support/MagpieWebTunnel/targets.conf` | 配置（唯一用户编辑点） |
| `~/Library/Application Support/MagpieWebTunnel/status/<名字>` | 隧道状态，一行 |
| `~/Library/Application Support/MagpieWebTunnel/tunneld.lock` | 新版 flock 单实例锁 |
| `~/Library/Application Support/MagpieWebTunnel/daemon.owner` | 守护归属（`daemonPID|appPID|epoch`），临时文件 |
| `~/Library/Application Support/MagpieWebTunnel/reload.request` / `.ack` | 保存并应用的会合文件，处理完即删 |
| `~/Library/Application Support/MagpieWebTunnel/tunnel.lock/` | 旧版目录锁（只读识别，不创建） |
| `~/Library/Logs/magpie-web-tunnel.log` | 守护主日志（轮转 .1） |
| `~/Library/Logs/magpie-web-tunnel-<名字>.log` | 每隧道 ssh 日志（轮转 .1） |

## 测试策略

- **MagpieTunnelCoreTests（78 个）**：解析/序列化字节级往返、配置草稿（保留注释、增删改撤销、字段校验、快照冲突）、重读会合（摘要/请求/ack 往返、归属记录）、日志增量读取（轮转/截断/大文件尾部/搜索）、URL 不变量、状态原子写、日志轮转、锁竞争、TCP 探测（真实 `/usr/bin/nc -l` 监听）、路径布局与环境变量
- **MagpieTunnelDaemonTests（12 个）**：黑盒拉起真实构建的二进制 + mock ssh 脚本 + 随机空闲端口；覆盖就绪/SIGTERM 无孤儿/断线重连/差量 reload/换配置重启/双实例拒绝/失败退避，以及**即时重读（不依赖轮询周期、缺失配置停全部、摘要不符时 ack 带说明）**与**归属看门狗（App 被杀 → 守护退出、无 `--owner-pid` 时不自退）**
- **MagpieTunnelStatusTests（52 个）**：面板模型全状态矩阵（含空态三态、副标题、图标可访问性）、ViewModel 文件驱动刷新（缺失配置不回退默认值）、`DaemonController` 起停与归属判断/重读确认（假 `DaemonSystem`，不 spawn 不 kill）、图标资源（18 pt 模板图 + 1x/@2x 双表征 + 纯黑 alpha + 缓存复用）、二进制 `--smoke-test` 端到端输出

所有集成测试只用临时目录、mock ssh、随机端口，绝不触碰真实的 `~/Library/Application Support/MagpieWebTunnel`、`~/Applications` 或生产隧道。
