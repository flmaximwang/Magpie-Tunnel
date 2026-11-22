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
    /// `environment` is passed explicitly so the daemon sees exactly the
    /// `MAGPIE_TUNNEL_*` values this app was started with.
    func spawn(executable: String, logPath: String, arguments: [String],
               environment: [String: String]) -> Int32?
    /// The `daemon.owner` record, when a daemon on this machine wrote one.
    func ownerRecord(path: String) -> DaemonOwner?
}

extension DaemonSystem {
    func ownerRecord(path: String) -> DaemonOwner? { DaemonOwner.read(path: path) }
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

    func spawn(executable: String, logPath: String, arguments: [String],
               environment: [String: String]) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // Hand the child the app's environment explicitly: the daemon reads
        // `MAGPIE_TUNNEL_CONFIG / STATUS_DIR / LOG_DIR / LOCK_DIR / SSH_BIN`
        // too, and a Finder-launched app would otherwise fall back to the
        // production defaults. Paths travel both ways (flags and env); flags
        // win in `DaemonOptions.resolvedPaths()`, so the daemon can never
        // disagree with the app about which files it owns.
        process.environment = environment

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
        // Keep the child alive independent of the app's own termination
        // sequence: the daemon watches our PID itself and shuts down cleanly,
        // which is what makes a crash or a force quit leave nothing behind.
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

/// Result of asking the daemon to apply a freshly saved configuration.
///
/// "Saved" and "applied" are deliberately separate: a write can succeed while
/// the daemon never answers, and the UI must be able to say exactly that.
enum ReloadOutcome: Equatable {
    /// The daemon acknowledged this exact request.
    case applied(targetCount: Int, note: String?)
    /// The request was written but no acknowledgement arrived in time.
    case unconfirmed(detail: String)
    /// The daemon read the file and could not use it.
    case rejected(detail: String)

    var isApplied: Bool { if case .applied = self { return true }; return false }

    var statusText: String {
        switch self {
        case .applied:
            return "已应用"
        case .unconfirmed(let detail):
            return "配置已保存，尚未确认应用（\(detail)）"
        case .rejected(let detail):
            return "配置已保存，但守护进程未能应用（\(detail)）"
        }
    }
}

/// Owns the lifecycle of the bundled `magpie-tunneld` — and, because the app is
/// now the sole owner of every tunnel, the lifecycle of the tunnels themselves:
///
/// - opening the app starts a daemon bound to this app process;
/// - a leftover daemon from an earlier app run is replaced, never adopted;
/// - quitting the app stops the daemon, which stops every ssh child;
/// - the daemon independently watches the app PID, so a crash or force quit
///   still cleans up;
/// - saving the configuration asks the daemon to reload immediately and waits
///   for the acknowledgement of that exact save.
///
/// An already-running daemon is detected through the flock PID file, so a
/// second launch of the app can never start a duplicate — the daemon's own
/// single-instance lock is the final guard.
final class DaemonController {
    private let paths: TunnelPaths
    private let system: DaemonSystem
    private let locateExecutable: () -> String?
    private let appPIDProvider: () -> Int32
    private let workQueue = DispatchQueue(label: "magpie.daemon-controller")
    private(set) var lastDiagnostic: String?
    /// PID of the daemon this app process is currently bound to.
    private(set) var ownedDaemonPID: Int32?

    init(paths: TunnelPaths,
         system: DaemonSystem = LiveDaemonSystem(),
         appPIDProvider: @escaping () -> Int32 = { getpid() },
         locateExecutable: @escaping () -> String? = { DaemonController.bundledDaemonPath() }) {
        self.paths = paths
        self.system = system
        self.appPIDProvider = appPIDProvider
        self.locateExecutable = locateExecutable
    }

    private var appPID: Int32 { appPIDProvider() }

    /// Full argument list for the daemon, derived from the `paths` this
    /// controller was built with — the single source of truth.
    ///
    /// Every path must be forwarded: the daemon resolves its own defaults from
    /// `TunnelPaths.defaults()`, which normally point at the production
    /// `~/Library/Application Support/MagpieWebTunnel` directory. A daemon
    /// started for an isolated run would therefore take the *production* lock
    /// (and the app would then SIGTERM the user's real daemon).
    var daemonArguments: [String] {
        ["--config", paths.configPath,
         "--status-dir", paths.statusDirectory,
         "--log-dir", paths.logDirectory,
         "--lock-dir", paths.lockDirectory,
         "--ssh-bin", paths.sshBinary,
         "--owner-pid", String(appPID)]
    }

    /// Environment handed to the daemon process: a copy of this app's own
    /// environment, so any `MAGPIE_TUNNEL_*` override the app was launched
    /// with reaches the child as well. Flags take precedence over these in
    /// `DaemonOptions.resolvedPaths()`, so the two can never disagree.
    var daemonEnvironment: [String: String] { ProcessInfo.processInfo.environment }

    /// The reload rendezvous shared with the daemon.
    var reloadCoordinator: ReloadCoordinator {
        ReloadCoordinator(lockDirectory: paths.lockDirectory)
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

    /// Whether the live daemon already belongs to this app process.
    func isOwnedByThisApp() -> Bool {
        guard let pid = currentDaemonPID(),
              let owner = system.ownerRecord(path: paths.ownerPath) else { return false }
        return owner.daemonPID == pid && owner.appPID == appPID
    }

    /// Launch path: guarantee exactly one daemon, owned by this app process.
    ///
    /// A daemon from an earlier run (or one without a matching owner record) is
    /// stopped first, so reopening the app always starts from the saved
    /// configuration instead of inheriting stale tunnels.
    @discardableResult
    func ensureOwnedDaemon(grace: TimeInterval = 8) -> Bool {
        if let pid = currentDaemonPID() {
            if isOwnedByThisApp() {
                ownedDaemonPID = pid
                return true
            }
            guard system.terminate(pid, grace: grace) else {
                lastDiagnostic = "旧的隧道守护 (pid \(pid)) 未能在 \(Int(grace)) 秒内退出"
                return false
            }
        }
        return spawnOwnedDaemon()
    }

    /// Start the daemon only when none is running (compatibility entry point).
    func startIfNeeded() {
        ensureOwnedDaemon()
    }

    private func spawnOwnedDaemon() -> Bool {
        guard let executable = locateExecutable() else {
            lastDiagnostic = "找不到隧道守护可执行文件；隧道不会自动启动"
            return false
        }
        let arguments = daemonArguments
        guard let pid = system.spawn(executable: executable, logPath: paths.mainLogPath,
                                     arguments: arguments,
                                     environment: daemonEnvironment) else {
            lastDiagnostic = "隧道守护启动失败（\(executable)）"
            return false
        }
        ownedDaemonPID = pid
        lastDiagnostic = nil
        return true
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
        guard system.spawn(executable: executable, logPath: paths.mainLogPath,
                           arguments: daemonArguments,
                           environment: daemonEnvironment) != nil else {
            return RestartResult(ok: false, diagnostic: "隧道守护启动失败（\(executable)）")
        }
        return RestartResult(ok: true, diagnostic: nil)
    }

    /// Quit path: stop the daemon, which in turn stops every ssh child.
    ///
    /// Returns true when nothing is left running. Used by `applicationWillTerminate`
    /// and by the quit confirmation; the daemon's own owner watchdog covers the
    /// crash / force-quit paths where this never runs.
    @discardableResult
    func stopSynchronously(grace: TimeInterval = 10) -> Bool {
        defer { ownedDaemonPID = nil }
        guard let pid = currentDaemonPID() else {
            DaemonOwner.remove(path: paths.ownerPath)
            reloadCoordinator.clear()
            return true
        }
        let gone = system.terminate(pid, grace: grace)
        if !gone {
            lastDiagnostic = "隧道守护 (pid \(pid)) 未能在 \(Int(grace)) 秒内退出"
        }
        DaemonOwner.remove(path: paths.ownerPath)
        reloadCoordinator.clear()
        return gone
    }

    /// Ask the daemon to reload the configuration this app just wrote and wait
    /// for the acknowledgement of *this* request.
    ///
    /// Blocking; call it off the main thread. Requests are matched by id, so a
    /// leftover ack from an earlier save can never be mistaken for this one.
    func applyConfiguration(digest: String, timeout: TimeInterval = 10) -> ReloadOutcome {
        // A daemon that vanished between save and apply cannot answer.
        guard currentDaemonPID() != nil else {
            return .unconfirmed(detail: "隧道守护未运行")
        }

        let coordinator = reloadCoordinator
        let request = ReloadRequest(requestID: UUID().uuidString, digest: digest)
        // Clear the previous ack first so a stale answer cannot be read as ours.
        try? FileManager.default.removeItem(atPath: coordinator.ackPath)
        do {
            try coordinator.writeRequest(request)
        } catch {
            return .unconfirmed(detail: error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let ack = coordinator.readAck(), ack.requestID == request.requestID {
                coordinator.clear()
                switch ack.outcome {
                case .applied:
                    let note = ack.detail.isEmpty ? nil : ack.detail
                    return .applied(targetCount: ack.targetCount, note: note)
                case .failed:
                    return .rejected(detail: ack.detail)
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return .unconfirmed(detail: "等待 \(Int(timeout)) 秒未收到守护确认")
    }

    /// Async wrapper used by the configuration window.
    func applyConfiguration(digest: String, timeout: TimeInterval = 10,
                            completion: @escaping (ReloadOutcome) -> Void) {
        workQueue.async { [weak self] in
            guard let self else { return }
            let outcome = self.applyConfiguration(digest: digest, timeout: timeout)
            DispatchQueue.main.async { completion(outcome) }
        }
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
