import AppKit
import Foundation
import MagpieTunnelCore

struct StatusOptions {
    var configPath: String?
    var statusDirectory: String?
    var logDirectory: String?
    var lockDirectory: String?
    var refreshInterval: TimeInterval = 10
    var smokeTest = false

    static func parse(_ arguments: [String]) -> StatusOptions {
        var options = StatusOptions()
        var iterator = arguments.dropFirst().makeIterator()

        func nextValue(_ flag: String) -> String {
            guard let value = iterator.next() else {
                FileHandle.standardError.write("MagpieTunnelStatus: \(flag) 需要一个参数值\n".data(using: .utf8)!)
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
            case "--refresh-interval":
                guard let v = Double(nextValue(arg)), v > 0, v <= 3600 else {
                    FileHandle.standardError.write("MagpieTunnelStatus: --refresh-interval 需要一个 0...3600 的秒数\n".data(using: .utf8)!)
                    exit(64)
                }
                options.refreshInterval = v
            case "--smoke-test": options.smokeTest = true
            case "-h", "--help":
                print("MagpieTunnelStatus — magpie 隧道菜单栏状态\n\n" +
                      "用法: MagpieTunnelStatus [--config <path>] [--status-dir <path>] " +
                      "[--log-dir <path>] [--lock-dir <path>] [--refresh-interval <sec>] [--smoke-test]\n" +
                      "路径也可用 MAGPIE_TUNNEL_CONFIG 等环境变量覆盖（命令行优先）。")
                exit(0)
            default:
                FileHandle.standardError.write("MagpieTunnelStatus: 未知参数 \(arg)\n".data(using: .utf8)!)
                exit(64)
            }
        }
        return options
    }

    func resolvedPaths() -> TunnelPaths {
        var paths = TunnelPaths.defaults(environment: ProcessInfo.processInfo.environment)
        paths.configPath = configPath ?? paths.configPath
        paths.statusDirectory = statusDirectory ?? paths.statusDirectory
        paths.logDirectory = logDirectory ?? paths.logDirectory
        paths.lockDirectory = lockDirectory ?? paths.lockDirectory
        return paths
    }
}

let options = StatusOptions.parse(CommandLine.arguments)

// Headless mode for tests/CI: build the menu model once, print it, exit.
// Never touches NSStatusBar, so it works without a window server.
if options.smokeTest {
    let viewModel = StatusViewModel(paths: options.resolvedPaths())
    let state = viewModel.refresh()
    print(state.iconEmoji + " " + state.summaryTitle)
    for row in state.targetRows {
        print(row.title + " → " + row.url)
    }
    for diagnostic in viewModel.lastDiagnostics {
        print("警告: " + diagnostic)
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate(viewModel: StatusViewModel(paths: options.resolvedPaths()),
                           refreshInterval: options.refreshInterval)
app.delegate = delegate
app.run()
