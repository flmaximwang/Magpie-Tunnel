import Foundation
import MagpieTunnelCore

let options = DaemonOptions.parse(CommandLine.arguments)
do {
    let daemon = try Daemon(options: options)
    daemon.run()
} catch {
    FileHandle.standardError.write("magpie-tunneld: 启动失败: \(error)\n".data(using: .utf8)!)
    exit(1)
}
