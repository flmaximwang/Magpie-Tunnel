import Foundation
import MagpieTunnelCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The operating-system side of daemon control, split out so the decision
/// logic in `DaemonController` can be unit-tested without spawning anything.
protocol DaemonSystem {
    /// PID recorded in the flock PID file, regardless of liveness.
    func recordedPID(lockFilePath: String) -> Int32?
    /// PID recorded by the legacy bash daemon's directory lock.
    func legacyPID(lockDirectory: String) -> Int32?
    func isAlive(_ pid: Int32) -> Bool
    /// SIGTERM, wait up to `grace`, SIGKILL if needed. Returns true when gone.
    func terminate(_ pid: Int32, grace: TimeInterval) -> Bool
    /// Launch detached from the UI process. Returns the child's PID, nil on failure.
    func spawn(executable: String, logPath: String) -> Int32?
}

struct LiveDaemonSystem: DaemonSystem {
    func recordedPID(lockFilePath: String) -> Int32? {
        SingleInstanceLock(lockFilePath: lockFilePath).recordedPID()
    }

    func legacyPID(lockDirectory: String) -> Int32? {
        let pidFile = lockDirectory + "/pid"
        guard let text = try? String(contentsOfFile: pidFile, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func isAlive(_ pid: Int32) -> Bool { SingleInstanceLock.isAlive(pid) }

    func terminate(_ pid: Int32, grace: TimeInterval) -> Bool {
        guard isAlive(pid) else { return true }
        kill(pid, SIGTERM)
        if waitForExit(pid, limit: grace) { return true }
        kill(pid, SIGKILL)
        return waitForExit(pid, limit: 2)
    }

    private func waitForExit(_ pid: Int32, limit: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(limit)
        while Date() < deadline {
            if !isAlive(pid) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !isAlive(pid)
    }

    func spawn(executable: String, logPath: String) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = []

        // The daemon writes its own rotating log; stdout/stderr are startup
        // diagnostics only. Append them to the main log rather than dropping
        // them, so a failed launch is explainable after the fact.
        FileManager.default.createFile(atPath: logPath, contents: nil)
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            process.standardOutput = handle
            process.standardError = handle
            LiveDaemonSystem.detachedHandles.append(handle)
        }
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")

        // The app must not die with its child (and must not be counted as the
        // child's parent for status purposes): Process keeps a monitor thread
        // that reaps it, and quitting the app leaves the daemon running.
        do {
            try process.run()
        } catch {
            return nil
        }
        let pid = process.processIdentifier
        // Keep the Process object alive for its monitor unless it exits.
        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                LiveDaemonSystem.liveChildren.removeValue(forKey: pid)
            }
        }
        LiveDaemonSystem.liveChildren[pid] = process
        return pid
    }

    private static var liveChildren: [Int32: Process] = [:]
    private static var detachedHandles: [FileHandle] = []
}

/// Owns the lifecycle of the bundled `magpie-tunneld`:
///
/// - opening the app starts it when nothing is running;
/// - the menu action restarts it in place (status keeps rendering meanwhile);
/// - quitting the app leaves it running, exactly like the legacy two-app setup.
///
/// An already-running daemon is detected through the flock PID file, so a
/// second launch of the app (or a second click on the bundle) can never start a
/// duplicate — the daemon's own single-instance lock is the final guard.
final class DaemonController {
    private let paths: TunnelPaths
    private let system: DaemonSystem
    private let locateExecutable: () -> String?
    private let workQueue = DispatchQueue(label: "magpie.daemon-controller")
    private(set) var lastDiagnostic: String?

    init(paths: TunnelPaths,
         system: DaemonSystem = LiveDaemonSystem(),
         locateExecutable: @escaping () -> String? = { DaemonController.bundledDaemonPath() }) {
        self.paths = paths
        self.system = system
        self.locateExecutable = locateExecutable
    }

    /// PID of a live daemon, new or legacy, or nil when none is running.
    func currentDaemonPID() -> Int32? {
        if let pid = system.recordedPID(lockFilePath: paths.lockFilePath), system.isAlive(pid) {
            return pid
        }
        if let pid = system.legacyPID(lockDirectory: paths.legacyLockDirectory), system.isAlive(pid) {
            return pid
        }
        return nil
    }

    /// Start the daemon only when none is running (app launch path).
    func startIfNeeded() {
        if currentDaemonPID() != nil { return }
        guard let executable = locateExecutable() else {
            lastDiagnostic = "找不到隧道守护可执行文件；隧道不会自动启动"
            return
        }
        if system.spawn(executable: executable, logPath: paths.mainLogPath) == nil {
            lastDiagnostic = "隧道守护启动失败（\(executable)）"
        }
    }

    /// Stop then start, off the main thread so the menu bar keeps responding.
    func restart(completion: @escaping () -> Void = {}) {
        workQueue.async { [weak self] in
            guard let self else { return }
            let result = self.restartSynchronously()
            if !result.ok { self.lastDiagnostic = result.diagnostic }
            DispatchQueue.main.async(execute: completion)
        }
    }

    struct RestartResult: Equatable {
        let ok: Bool
        let diagnostic: String?
    }

    func restartSynchronously(grace: TimeInterval = 8) -> RestartResult {
        if let pid = currentDaemonPID() {
            guard system.terminate(pid, grace: grace) else {
                return RestartResult(ok: false,
                                     diagnostic: "旧的隧道守护 (pid \(pid)) 未能在 \(Int(grace)) 秒内退出")
            }
        }
        guard let executable = locateExecutable() else {
            return RestartResult(ok: false, diagnostic: "找不到隧道守护可执行文件")
        }
        guard system.spawn(executable: executable, logPath: paths.mainLogPath) != nil else {
            return RestartResult(ok: false, diagnostic: "隧道守护启动失败（\(executable)）")
        }
        return RestartResult(ok: true, diagnostic: nil)
    }

    /// Packaged daemon lives next to the menu-bar executable inside the bundle.
    static func bundledDaemonPath() -> String? {
        let candidates = [
            Bundle.main.executableURL?.deletingLastPathComponent()
                .appendingPathComponent("magpie-tunneld").path,
            // SwiftPM debug layout: both products sit next to each other.
            Bundle.main.executableURL?.deletingLastPathComponent()
                .appendingPathComponent("MagpieTunnelDaemon").path,
        ]
        for case let candidate? in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }
}
