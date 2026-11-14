import XCTest
@testable import MagpieTunnelCore

#if canImport(Darwin)
import Darwin
#endif

/// Black-box integration tests: they launch the real `MagpieTunnelDaemon`
/// binary against a mock ssh script inside a throwaway temp directory, on
/// ephemeral local ports. They never touch ~/Library, the real
/// MagpieWebTunnel support dir, or the live 3430/3431 tunnels.
final class MagpieTunnelDaemonIntegrationTests: XCTestCase {
    private var workDir: String!
    private var daemonHandles: [DaemonHandle] = []

    override func setUpWithError() throws {
        workDir = try Self.makeTempDirectory()
        try FileManager.default.createDirectory(atPath: workDir + "/status", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: workDir + "/logs", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: workDir + "/lock", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: workDir + "/mock", withIntermediateDirectories: true)
        try "healthy".write(toFile: workDir + "/mock/mode", atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        for handle in daemonHandles where handle.process.isRunning {
            kill(handle.process.processIdentifier, SIGKILL)
            handle.process.waitUntilExit()
        }
        daemonHandles.removeAll()
        try? FileManager.default.removeItem(atPath: workDir)
    }

    // MARK: - helpers

    private struct DaemonHandle {
        let process: Process
        let stderrPath: String
    }

    private static func makeTempDirectory() throws -> String {
        let template = NSTemporaryDirectory() + "magpie-tunneld-tests-XXXXXX"
        var buffer = template.cString(using: .utf8)!.map { $0 }
        guard let dir = mkdtemp(&buffer) else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "mkdtemp failed"])
        }
        return String(cString: dir)
    }

    /// Ephemeral free local port on 127.0.0.1 (never the live 3430/3431).
    private static func freePort() throws -> Int {
        for _ in 0..<64 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { break }
            defer { close(fd) }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            var bindResult: Int32 = -1
            withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bindResult = Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else { continue }
            var bound = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutablePointer(to: &bound) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = getsockname(fd, sa, &len)
                }
            }
            let candidate = Int(UInt16(bigEndian: bound.sin_port))
            if candidate > 0, candidate != 3430, candidate != 3431 {
                return candidate
            }
        }
        throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "no free port"])
    }

    private static let mockSSHScript = """
    #!/bin/bash
    # Mock ssh for magpie-tunneld integration tests; behavior set by $MOCK_DIR/mode.
    LP=""
    prev=""
    for a in "$@"; do
      if [ "$prev" = "-L" ]; then
        LP=$(printf '%s' "$a" | cut -d: -f2)
      fi
      prev="$a"
    done
    echo "start $LP $$" >> "$MOCK_DIR/spawns"
    printf '%s\\n' "$*" >> "$MOCK_DIR/args"
    MODE=$(cat "$MOCK_DIR/mode" 2>/dev/null || echo healthy)
    case "$MODE" in
      healthy)
        while true; do
          /usr/bin/nc -l 127.0.0.1 "$LP" >/dev/null 2>&1
          sleep 0.05
        done
        ;;
      flap)
        /usr/bin/nc -l 127.0.0.1 "$LP" >/dev/null 2>&1
        exit 0
        ;;
      fail)
        exit 7
        ;;
      *)
        exit 1
        ;;
    esac
    """

    private func writeMockSSH() throws -> String {
        let path = workDir + "/mock-ssh"
        try Self.mockSSHScript.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    /// The built daemon binary (product MagpieTunnelDaemon). `swift test`
    /// builds it before running this suite.
    private static func daemonBinaryPath() throws -> String {
        let testFile = #filePath
        let repoRoot = (testFile as NSString).deletingLastPathComponent // Tests/
            .components(separatedBy: "/").dropLast(2).joined(separator: "/")
        let candidates = [
            repoRoot + "/.build/out/Products/Debug/MagpieTunnelDaemon",
            repoRoot + "/.build/debug/MagpieTunnelDaemon",
            repoRoot + "/.build/arm64-apple-macosx/debug/MagpieTunnelDaemon",
        ]
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        throw XCTSkip("守护进程二进制不存在，请先运行 swift build。查找过: \(candidates)")
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval, _ description: String, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("等待超时: \(description)")
        return false
    }

    private func writeConfig(_ lines: [String]) throws -> String {
        let path = workDir + "/targets.conf"
        try lines.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @discardableResult
    private func launchDaemon(configPath: String, pollInterval: TimeInterval = 0.2, reloadInterval: TimeInterval = 1) throws -> DaemonHandle {
        let mockBin = try writeMockSSH()
        let stderrPath = workDir + "/daemon.err"
        FileManager.default.createFile(atPath: stderrPath, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try Self.daemonBinaryPath())
        process.arguments = [
            "--config", configPath,
            "--status-dir", workDir + "/status",
            "--log-dir", workDir + "/logs",
            "--lock-dir", workDir + "/lock",
            "--ssh-bin", mockBin,
            "--poll-interval", String(pollInterval),
            "--reload-interval", String(reloadInterval),
            "--no-default-targets",
        ]
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("MAGPIE_TUNNEL_") }
        environment["MOCK_DIR"] = workDir + "/mock"
        process.environment = environment
        process.standardError = FileHandle(forWritingAtPath: stderrPath)
        try process.run()
        let handle = DaemonHandle(process: process, stderrPath: stderrPath)
        daemonHandles.append(handle)
        return handle
    }

    private func terminateDaemon(_ handle: DaemonHandle, timeout: TimeInterval = 10) {
        guard handle.process.isRunning else { return }
        kill(handle.process.processIdentifier, SIGTERM)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && handle.process.isRunning {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if handle.process.isRunning {
            kill(handle.process.processIdentifier, SIGKILL)
            handle.process.waitUntilExit()
            XCTFail("daemon 未在 \(timeout)s 内响应 SIGTERM 退出")
        } else {
            handle.process.waitUntilExit()
        }
    }

    private func status(_ name: String) -> StatusRecord? {
        StatusRecord.parse((try? String(contentsOfFile: workDir + "/status/" + name, encoding: .utf8)) ?? "")
    }

    private func spawnCount(port: Int) -> Int {
        let text = (try? String(contentsOfFile: workDir + "/mock/spawns", encoding: .utf8)) ?? ""
        return text.split(separator: "\n").filter { $0.hasPrefix("start \(port) ") }.count
    }

    private func lastArgsLine() -> String {
        let text = (try? String(contentsOfFile: workDir + "/mock/args", encoding: .utf8)) ?? ""
        return text.split(separator: "\n").last.map(String.init) ?? ""
    }

    private func daemonLog() -> String {
        (try? String(contentsOfFile: workDir + "/logs/magpie-web-tunnel.log", encoding: .utf8)) ?? "<no log>"
    }

    // MARK: - tests

    func testCoreIsLinked() {
        XCTAssertEqual(TargetConfig.builtInDefaults.count, 2)
    }

    func testTunnelComesUpWritesStatusAndExitsCleanlyOnSIGTERM() throws {
        let port = try Self.freePort()
        let configPath = try writeConfig(["t1|\(port)|mock@example.com|22|abcdef0123456789"])

        let handle = try launchDaemon(configPath: configPath)

        // 1. Status flips to up with the port.
        let cameUp = waitUntil(timeout: 20, "status/t1 变为 up") {
            self.status("t1")?.isUp == true && self.status("t1")?.port == port
        }
        XCTAssertTrue(cameUp)
        // 状态 up 已由守护自己的探测写入；这里复探监听端口。mock 的 healthy
        // 模式是 while 循环重启 nc，探测可能恰好落在重启间隙，故短重试。
        let listenerUp = waitUntil(timeout: 5, "隧道端口接受连接") {
            TCPProbe.canConnect(port: port, timeout: 1.0)
        }
        XCTAssertTrue(listenerUp)

        // 2. The ssh child got the exact hardened legacy argument list.
        let cameUp2 = waitUntil(timeout: 5, "mock ssh 收到启动参数") { self.spawnCount(port: port) >= 1 }
        XCTAssertTrue(cameUp2)
        let args = lastArgsLine()
        XCTAssertTrue(args.contains("-N"), "缺少 -N: \(args)")
        for flag in ["ExitOnForwardFailure=yes", "BatchMode=yes", "ConnectTimeout=15",
                     "ServerAliveInterval=30", "ServerAliveCountMax=3", "TCPKeepAlive=yes",
                     "PasswordAuthentication=no", "KbdInteractiveAuthentication=no",
                     "NumberOfPasswordPrompts=0"] {
            XCTAssertTrue(args.contains("-o \(flag)"), "缺少 -o \(flag): \(args)")
        }
        XCTAssertTrue(args.contains("-L 127.0.0.1:\(port):127.0.0.1:22"), "缺少 -L 转发参数: \(args)")

        // 3. SIGTERM → exit 0, down 守护退出, no orphan listener left behind.
        terminateDaemon(handle)
        XCTAssertEqual(handle.process.terminationReason, .exit)
        XCTAssertEqual(handle.process.terminationStatus, 0)
        let down = status("t1")
        XCTAssertEqual(down?.state, "down")
        XCTAssertEqual(down?.detail, "守护退出", "状态: \(String(describing: down)) 日志: \(daemonLog())")

        let portClosed = waitUntil(timeout: 5, "端口在退出后关闭") {
            !TCPProbe.canConnect(port: port, timeout: 0.5)
        }
        XCTAssertTrue(portClosed)
        XCTAssertEqual(Self.pgrepMatches("nc -l 127.0.0.1 \(port)"), 0, "SIGTERM 后仍残留 nc 进程")
    }

    func testReconnectsAfterSSHExit() throws {
        try "flap".write(toFile: workDir + "/mock/mode", atomically: true, encoding: .utf8)
        let port = try Self.freePort()
        let configPath = try writeConfig(["t1|\(port)|mock@example.com|22|"])

        let handle = try launchDaemon(configPath: configPath)

        // The mock exits after each probe connection; the daemon must relaunch it.
        let reconnected = waitUntil(timeout: 25, "mock ssh 至少重启一次") { self.spawnCount(port: port) >= 2 }
        XCTAssertTrue(reconnected, "启动次数: \(self.spawnCount(port: port)) 日志: \(daemonLog())")

        terminateDaemon(handle)
    }

    func testDifferentialReloadKeepsUnchangedTunnelRunning() throws {
        let portA = try Self.freePort()
        let portB = try Self.freePort()
        let portC = try Self.freePort()
        let configPath = try writeConfig([
            "alpha|\(portA)|mock@example.com|22|",
            "beta|\(portB)|mock@example.com|22|",
        ])

        let handle = try launchDaemon(configPath: configPath)

        let bothUp = waitUntil(timeout: 20, "alpha 和 beta 都 up") {
            self.status("alpha")?.isUp == true && self.status("beta")?.isUp == true
        }
        XCTAssertTrue(bothUp, "日志: \(daemonLog())")

        // Hot-reload: alpha untouched, beta removed, gamma added.
        try [
            "# reload: alpha unchanged, beta removed, gamma added",
            "alpha|\(portA)|mock@example.com|22|",
            "gamma|\(portC)|mock@example.com|22|",
        ].joined(separator: "\n").appending("\n").write(toFile: configPath, atomically: true, encoding: .utf8)

        let gammaUp = waitUntil(timeout: 20, "gamma up 且 beta 配置移除") {
            self.status("gamma")?.isUp == true && self.status("beta")?.detail == "配置移除"
        }
        XCTAssertTrue(gammaUp, "alpha: \(String(describing: status("alpha"))) beta: \(String(describing: status("beta"))) gamma: \(String(describing: status("gamma"))) 日志: \(daemonLog())")

        // alpha's ssh was never restarted; beta/gamma each started exactly once.
        XCTAssertEqual(spawnCount(port: portA), 1, "alpha 不应被重启；日志: \(daemonLog())")
        XCTAssertEqual(spawnCount(port: portB), 1)
        XCTAssertEqual(spawnCount(port: portC), 1)
        XCTAssertEqual(status("alpha")?.state, "up")

        terminateDaemon(handle)
    }

    func testChangedTargetRestarts() throws {
        let port = try Self.freePort()
        let configPath = try writeConfig(["alpha|\(port)|mock@example.com|22|"])

        let handle = try launchDaemon(configPath: configPath)
        let up = waitUntil(timeout: 20, "alpha up") { self.status("alpha")?.isUp == true }
        XCTAssertTrue(up, "日志: \(daemonLog())")

        // Change the remote port → alpha's ssh must be restarted with new args.
        try "alpha|\(port)|mock@example.com|2222|\n".write(toFile: configPath, atomically: true, encoding: .utf8)
        let restarted = waitUntil(timeout: 20, "alpha 重启第二次") { self.spawnCount(port: port) >= 2 }
        XCTAssertTrue(restarted, "启动次数: \(spawnCount(port: port)) 日志: \(daemonLog())")
        let backUp = waitUntil(timeout: 10, "alpha 重新 up") { self.status("alpha")?.isUp == true }
        XCTAssertTrue(backUp)
        XCTAssertTrue(lastArgsLine().contains("-L 127.0.0.1:\(port):127.0.0.1:2222"), "新参数未生效: \(lastArgsLine())")

        terminateDaemon(handle)
    }

    func testSecondDaemonRefusesToStart() throws {
        let port = try Self.freePort()
        let configPath = try writeConfig(["t1|\(port)|mock@example.com|22|"])

        let first = try launchDaemon(configPath: configPath)
        let up = waitUntil(timeout: 20, "第一个 daemon up") { self.status("t1")?.isUp == true }
        XCTAssertTrue(up, "日志: \(daemonLog())")

        let second = try launchDaemon(configPath: configPath)
        second.process.waitUntilExit()
        XCTAssertNotEqual(second.process.terminationStatus, 0)
        let stderr = (try? String(contentsOfFile: second.stderrPath, encoding: .utf8)) ?? ""
        XCTAssertTrue(stderr.contains("已在运行"), "stderr 应说明已有实例: \(stderr)")

        terminateDaemon(first)
    }

    func testFailingSSHWritesDownStatusAndKeepsRetrying() throws {
        try "fail".write(toFile: workDir + "/mock/mode", atomically: true, encoding: .utf8)
        let port = try Self.freePort()
        let configPath = try writeConfig(["t1|\(port)|mock@example.com|22|"])

        let handle = try launchDaemon(configPath: configPath)
        // Legacy parity: a dying child ends as `down ... ssh 断开 rc=7` (the
        // brief `ssh 启动失败` transition is overwritten within milliseconds).
        let failed = waitUntil(timeout: 20, "状态变为 down (ssh 启动失败/断开)") {
            let record = self.status("t1")
            return record?.state == "down"
                && (record?.detail == "ssh 启动失败" || record?.detail.hasPrefix("ssh 断开 rc=") == true)
        }
        XCTAssertTrue(failed, "状态: \(String(describing: status("t1"))) 日志: \(daemonLog())")

        // Bounded backoff reconnects instead of spinning: ≥2 spawns within 25s
        // (5s base backoff), but never a busy loop (≤6 in that window).
        let retried = waitUntil(timeout: 25, "失败后重连") { self.spawnCount(port: port) >= 2 }
        XCTAssertTrue(retried, "启动次数: \(spawnCount(port: port)) 日志: \(daemonLog())")
        XCTAssertLessThanOrEqual(spawnCount(port: port), 6, "重连过于频繁，退避未生效: \(daemonLog())")

        terminateDaemon(handle)
    }

    // MARK: - misc

    private static func pgrepMatches(_ pattern: String) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", pattern]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(separator: "\n").filter { !$0.isEmpty }.count
    }
}
