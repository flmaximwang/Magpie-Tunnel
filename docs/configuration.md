# 配置参考

## targets.conf

位置：`~/Library/Application Support/MagpieWebTunnel/targets.conf`（可用 `MAGPIE_TUNNEL_CONFIG` 或 `--config` 覆盖，见下）。

```text
# magpie 隧道目标配置 —— 改这一个文件，隧道守护和菜单栏 App 都跟着变
TC2C4G2026|3430|ubuntu@43.142.18.254|3430|3bdf4869eb195854f1f322fee217dc6d
ZLab4090D|3431|wangfanlin1@100.68.85.3|3430|
```

### 行格式

```
名字|本地端口|SSH目标|远端端口|Web密钥
```

| 字段 | 规则 |
| --- | --- |
| 名字 | 非空；不得含 `/` `\` `:`，不得以 `.` 开头（防路径穿越，因为名字直接拼进日志/状态文件路径）；不得重复 |
| 本地端口 | 1–65535；**不同目标之间不得重复**（一条隧 道 就是一个 127.0.0.1 监听） |
| SSH目标 | 非空；`user@host` 形式（与命令行 ssh 一致，可含别名） |
| 远端端口 | 1–65535；远端 sshd 侧转发目标（通常是 magpie 服务端口） |
| Web密钥 | 可为空（行尾保留 `|` 即 5 段空值，或直接 4 段）；空 = URL 不带 `?k=` |

### 解析行为

- `#` 开头为注释，空行忽略；**保存时注释与空行原样保留**（配置窗口写回时也会保留它们）
- 坏行不致命：字段数不是 4/5、端口越界、名字非法、重复名字/端口 —— 该行忽略，诊断写入主日志，其余行正常生效。配置窗口会把坏行显示成可编辑的一行，原地改好即可
- 文件**首次**启动时不存在 → 使用内置默认值（上面的 TC2C4G2026 / ZLab4090D 两条），`--no-default-targets` 可关掉这个兼容行为
- 文件存在但 0 条有效目标 → 一条隧道都不跑（旧 bash 版此时会退回默认值，这是唯一有意的行为差异，避免幽灵隧道）
- 运行中重读时文件缺失 → 同样按 0 条目标处理（不会复活刚删掉的隧道）；文件暂时不可读（权限等）→ 保持现有目标不变，下个周期重试

### 生效节奏

守护每 `--reload-interval`（默认 20s）轮询重读一次并**差量**应用：同名且同配置的隧道不重启；变化的先停后启；删除的写 `down|<epoch>|配置移除`。

在配置窗口按「保存并应用」时不等轮询：App 写一份 `reload.request`（请求 id + 文件内容摘要），守护每 0.25s 扫这个目录，读到就立刻 apply，并把实际应用的内容摘要与目标数写进 `reload.ack`。App 只有在请求 id 与摘要都对得上时才显示「已应用」；10 秒内没等到则显示「配置已保存，尚未确认应用」，绝不谎报成功。

Magpie-WebUI-Tunnel 每 `--refresh-interval`（默认 10s）重读状态目录；面板打开时会立即刷新一次。

## 环境变量覆盖

测试与隔离部署用，优先级：**命令行 > 环境变量 > 默认路径**。

| 变量 | 覆盖对象 |
| --- | --- |
| `MAGPIE_TUNNEL_CONFIG` | targets.conf 路径 |
| `MAGPIE_TUNNEL_STATUS_DIR` | 状态文件目录（默认 `…/MagpieWebTunnel/status`） |
| `MAGPIE_TUNNEL_LOG_DIR` | 日志目录（默认 `~/Library/Logs`） |
| `MAGPIE_TUNNEL_LOCK_DIR` | 锁目录（默认 `…/MagpieWebTunnel`） |
| `MAGPIE_TUNNEL_SSH_BIN` | ssh 可执行文件路径（默认 `/usr/bin/ssh`；测试注入 mock） |

## magpie-tunneld 命令行

```
magpie-tunneld [--config <path>] [--status-dir <path>] [--log-dir <path>]
               [--lock-dir <path>] [--ssh-bin <path>]
               [--poll-interval <sec>] [--reload-interval <sec>]
               [--owner-pid <pid>] [--no-default-targets] [-h]
```

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `--poll-interval` | 0.5 | 隧道启动后 TCP 探测就绪的步长（60 步 = 30s 上限） |
| `--reload-interval` | 20 | 配置差量重载周期（旧版同值） |
| `--owner-pid` | 无 | 绑定到这个菜单栏 App；App 消失（含崩溃、被强退）后守护 2s 内自行退出并杀掉全部 ssh。App 启动时会自己带上这个参数 |
| `--no-default-targets` | 关 | 配置文件缺失时不要回退到内置默认目标（跑 0 条） |

参数错误 exit 64；已有守护在跑（flock 冲突或旧目录锁里有活 pid）exit 1 并提示对方 pid；SIGTERM/SIGINT 优雅退出 exit 0。

## MagpieTunnelStatus 命令行

```
MagpieTunnelStatus [--config <path>] [--status-dir <path>] [--log-dir <path>]
                   [--lock-dir <path>] [--ssh-bin <path>]
                   [--refresh-interval <sec>] [--smoke-test]
```

这五个路径参数是 App 的**唯一真相**：App 拉起包内 `magpie-tunneld` 时会把它们连同 `--owner-pid` 一起原样传给守护（同时继承 App 的环境变量，命令行为准）。所以隔离运行（如 `--lock-dir /tmp/magpie-accept/lock`）不会去抢生产锁，也不会误杀生产守护。

`--ssh-bin`：覆盖隧道使用的 ssh 可执行文件（默认 `/usr/bin/ssh`），用于注入 mock ssh；不传时仍可由 `MAGPIE_TUNNEL_SSH_BIN` 覆盖。

`--smoke-test`：不接触状态栏，构建一次菜单模型打印后退出（exit 0）——用于 CI/脚本自检。

## SSH 参数（不可配置，固化在 SSHProcess.swift）

```
ssh -N \
  -o ExitOnForwardFailure=yes -o BatchMode=yes -o ConnectTimeout=15 \
  -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o TCPKeepAlive=yes \
  -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
  -o NumberOfPasswordPrompts=0 \
  -L 127.0.0.1:<本地端口>:127.0.0.1:<远端端口> <SSH目标>
```

全部非交互硬化项与旧 bash 版逐字节一致；只支持公钥认证 —— 私钥请先配好 `ssh-agent` / `~/.ssh/config`。
