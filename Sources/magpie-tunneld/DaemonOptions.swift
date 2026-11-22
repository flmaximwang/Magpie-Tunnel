import Foundation
import MagpieTunnelCore

/// Command-line options for `magpie-tunneld`. Every path is overridable so
/// tests can run the daemon fully inside a temp directory.
struct DaemonOptions {
    var configPath: String?
    var statusDirectory: String?
    var logDirectory: String?
    var lockDirectory: String?
    var sshBinary: String?
    var pollInterval: TimeInterval = 0.5
    var reloadInterval: TimeInterval = 20
    var useDefaultTargetsWhenMissing = true
    /// PID of the menu-bar app that owns this daemon. When set, the daemon
    /// records the binding and exits as soon as the app goes away.
    var ownerAppPID: Int32?

    static let usage = """
    magpie-tunneld — magpie 隧道守护进程

    用法: magpie-tunneld [选项]

    选项:
      --config <path>         targets.conf 路径
                              (默认 ~/Library/Application Support/MagpieWebTunnel/targets.conf)
      --status-dir <path>     状态目录 (默认 .../MagpieWebTunnel/status)
      --log-dir <path>        日志目录 (默认 ~/Library/Logs)
      --lock-dir <path>       锁文件目录 (默认 .../MagpieWebTunnel)
      --ssh-bin <path>        ssh 可执行文件 (默认 /usr/bin/ssh)
      --poll-interval <sec>   端口探测间隔 (默认 0.5)
      --reload-interval <sec> 配置热重载间隔 (默认 20)
      --owner-pid <pid>       绑定到该菜单栏 App；App 消失后守护自动退出
      --no-default-targets    配置文件缺失时不回退到内置默认目标
      -h, --help              显示本帮助

    行为:
      · 只重启配置中新增/修改/删除的目标，未变的目标保持运行
      · 守护退出时（SIGTERM/SIGINT、绑定的 App 消失）杀掉所有 ssh 子进程并释放锁
    """

    static func parse(_ arguments: [String]) -> DaemonOptions {
        var options = DaemonOptions()
        var iterator = arguments.dropFirst().makeIterator()

        func nextValue(_ flag: String) -> String {
            guard let value = iterator.next() else {
                FileHandle.standardError.write("magpie-tunneld: \(flag) 需要一个参数值\n".data(using: .utf8)!)
                exit(64)
            }
            return value
        }

        while let arg = iterator.next() {
            switch arg {
            case "--config": options.configPath = nextValue(arg)
            case "--status-dir": options.statusDirectory = nextValue(arg)
            case "--log-dir": options.logDirectory = nextValue(arg)
            case "--lock-dir": options.lockDirectory = nextValue(arg)
            case "--ssh-bin": options.sshBinary = nextValue(arg)
            case "--poll-interval":
                guard let v = Double(nextValue(arg)), v > 0, v <= 60 else {
                    FileHandle.standardError.write("magpie-tunneld: --poll-interval 需要一个 0...60 的秒数\n".data(using: .utf8)!)
                    exit(64)
                }
                options.pollInterval = v
            case "--reload-interval":
                guard let v = Double(nextValue(arg)), v > 0, v <= 3600 else {
                    FileHandle.standardError.write("magpie-tunneld: --reload-interval 需要一个 0...3600 的秒数\n".data(using: .utf8)!)
                    exit(64)
                }
                options.reloadInterval = v
            case "--owner-pid":
                guard let v = Int32(nextValue(arg)), v > 0 else {
                    FileHandle.standardError.write("magpie-tunneld: --owner-pid 需要一个正整数\n".data(using: .utf8)!)
                    exit(64)
                }
                options.ownerAppPID = v
            case "--no-default-targets":
                options.useDefaultTargetsWhenMissing = false
            case "-h", "--help":
                print(usage)
                exit(0)
            default:
                FileHandle.standardError.write("magpie-tunneld: 未知参数 \(arg)\n\n\(usage)\n".data(using: .utf8)!)
                exit(64)
            }
        }
        return options
    }

    /// Resolve paths from defaults + env + CLI overrides (CLI wins).
    func resolvedPaths() -> TunnelPaths {
        var paths = TunnelPaths.defaults(environment: ProcessInfo.processInfo.environment)
        paths.configPath = configPath ?? paths.configPath
        paths.statusDirectory = statusDirectory ?? paths.statusDirectory
        paths.logDirectory = logDirectory ?? paths.logDirectory
        paths.lockDirectory = lockDirectory ?? paths.lockDirectory
        paths.sshBinary = sshBinary ?? paths.sshBinary
        return paths
    }
}
