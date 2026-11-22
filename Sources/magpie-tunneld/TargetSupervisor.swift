import Foundation
import MagpieTunnelCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Runs the connect-probe-reconnect loop for one target on a dedicated
/// thread. Writes status transitions through the shared StatusStore and
/// mirrors the legacy bash daemon's log messages.
final class TargetSupervisor {
    let target: TargetConfig

    private let sshBinary: String
    private let paths: TunnelPaths
    private let statusStore: StatusStore
    private let mainLog: RotatingFileLogger
    private let pollInterval: TimeInterval

    private let stateLock = NSLock()
    private var stoppedFlag = false
    private var currentChild: SSHProcess?
    private var workThread: Thread?

    private let finishedSemaphore = DispatchSemaphore(value: 0)
    static let reconnectBackoffBase: TimeInterval = 5
    static let reconnectBackoffMax: TimeInterval = 60
    static let uptimeResetsBackoff: TimeInterval = 60

    var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stoppedFlag
    }

    init(target: TargetConfig, sshBinary: String, paths: TunnelPaths, statusStore: StatusStore, mainLog: RotatingFileLogger, pollInterval: TimeInterval) {
        self.target = target
        self.sshBinary = sshBinary
        self.paths = paths
        self.statusStore = statusStore
        self.mainLog = mainLog
        self.pollInterval = pollInterval
    }

    func start() {
        let thread = Thread { [weak self] in
            self?.runLoop()
            self?.finishedSemaphore.signal()
        }
        thread.name = "magpie-supervisor-\(target.name)"
        workThread = thread
        thread.start()
    }

    /// Signal the loop to stop, kill the running child, wait for the thread.
    func stop() {
        stateLock.lock()
        stoppedFlag = true
        let child = currentChild
        stateLock.unlock()
        child?.terminate()
        _ = finishedSemaphore.wait(timeout: .now() + 5)
    }

    // MARK: - loop

    private func runLoop() {
        var backoff = TargetSupervisor.reconnectBackoffBase
        var lastUpAt: Date?

        while !isStopped {
            // Rotate the per-target log if it grew past the legacy threshold.
            let logPath = paths.targetLogPath(name: target.name)
            let targetLog = try? RotatingFileLogger(filePath: logPath)
            targetLog?.rotateIfNeeded()
            let logFD = open(logPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard logFD >= 0 else {
                mainLog.log("[\(target.name)] 无法打开日志文件: \(logPath)")
                statusStore.write(name: target.name, record: .down(reason: "日志打开失败"))
                if !interruptibleSleep(5) { return }
                continue
            }
            defer { close(logFD) }

            stateLock.lock()
            guard !stoppedFlag else {
                stateLock.unlock()
                return
            }
            guard let child = SSHProcess(sshBinary: sshBinary, target: target, logFD: logFD) else {
                stateLock.unlock()
                mainLog.log("[\(target.name)] ssh 启动失败 (spawn)")
                statusStore.write(name: target.name, record: .down(reason: "ssh 启动失败"))
                if !interruptibleSleep(backoff) { return }
                backoff = min(backoff * 2, TargetSupervisor.reconnectBackoffMax)
                continue
            }
            currentChild = child
            stateLock.unlock()

            mainLog.log("[\(target.name)] 连接 \(target.sshTarget) (本机 127.0.0.1:\(target.localPort) -> 远端 127.0.0.1:\(target.remotePort))")
            // An ssh child now exists and the port is being probed: this is the
            // only interval the UI is allowed to call "连接中".
            statusStore.write(name: target.name, record: .connecting())

            // Probe the local port for up to 60 poll intervals (legacy: 60 × 0.5s).
            var markedUp = false
            for _ in 0..<60 {
                if isStopped { break }
                if child.tryWait() != nil { break } // child already died
                if TCPProbe.canConnect(port: target.localPort, timeout: 1.0) {
                    markedUp = true
                    break
                }
                Thread.sleep(forTimeInterval: pollInterval)
            }

            if isStopped { break }

            if markedUp {
                statusStore.write(name: target.name, record: .up(port: target.localPort))
                mainLog.log("[\(target.name)] 隧道就绪 127.0.0.1:\(target.localPort)")
                lastUpAt = Date()
                backoff = TargetSupervisor.reconnectBackoffBase
            } else {
                let reason = child.isRunning ? "端口未就绪" : "ssh 启动失败"
                statusStore.write(name: target.name, record: .down(reason: reason))
                mainLog.log("[\(target.name)] \(reason)")
            }

            // Block until the ssh child exits (stop() kills it to unblock us).
            let rc = child.wait()
            if isStopped { break }

            statusStore.write(name: target.name, record: .down(reason: "ssh 断开 rc=\(rc)"))
            mainLog.log("[\(target.name)] ssh 断开 (rc=\(rc))，\(Int(backoff)) 秒后重连")

            // Stayed up long enough → reset the backoff ladder, else grow it.
            let uptime = lastUpAt.map { Date().timeIntervalSince($0) } ?? 0
            if uptime >= TargetSupervisor.uptimeResetsBackoff {
                backoff = TargetSupervisor.reconnectBackoffBase
            }
            if !interruptibleSleep(backoff) { return }
            backoff = min(backoff * 2, TargetSupervisor.reconnectBackoffMax)
        }
    }

    /// Sleep that wakes early when stopped. Returns false if we should exit.
    private func interruptibleSleep(_ seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if isStopped { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return !isStopped
    }
}
