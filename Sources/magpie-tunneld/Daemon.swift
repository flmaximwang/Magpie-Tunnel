import Foundation
import MagpieTunnelCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The daemon: owns the single-instance lock, the supervisor set, the config
/// hot-reload timer, immediate reload requests from the menu-bar app, the
/// owner watchdog, and graceful SIGTERM/SIGINT shutdown.
final class Daemon {
    private let options: DaemonOptions
    private let paths: TunnelPaths
    private let logger: RotatingFileLogger
    private let statusStore: StatusStore
    private let lock: SingleInstanceLock
    private let reloadCoordinator: ReloadCoordinator

    private var supervisors: [String: TargetSupervisor] = [:]
    private var lastConfigText: String?
    private var lastDiagnostics: [String] = []
    private var reloadTimer: DispatchSourceTimer?
    private var requestTimer: DispatchSourceTimer?
    private var ownerTimer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var shuttingDown = false
    private var lastHandledRequest: String?

    /// How often the daemon looks for a pending immediate-reload request.
    static let requestPollInterval: TimeInterval = 0.25
    /// How often the daemon checks that its owning app is still alive.
    static let ownerPollInterval: TimeInterval = 2.0

    init(options: DaemonOptions) throws {
        self.options = options
        self.paths = options.resolvedPaths()
        self.logger = try RotatingFileLogger(filePath: paths.mainLogPath)
        self.statusStore = try StatusStore(directory: paths.statusDirectory)
        self.lock = SingleInstanceLock(lockFilePath: paths.lockFilePath,
                                       legacyLockDirectory: paths.legacyLockDirectory)
        self.reloadCoordinator = ReloadCoordinator(lockDirectory: paths.lockDirectory)
    }

    // MARK: - entry

    func run() -> Never {
        guard lock.tryAcquire() else {
            let other = lock.otherPID.map(String.init) ?? "未知"
            let message = "另一个 magpie-tunneld 已在运行 (pid \(other))，退出"
            logger.log(message)
            FileHandle.standardError.write("magpie-tunneld: \(message)\n".data(using: .utf8)!)
            exit(1)
        }

        installSignalHandlers()
        recordOwnership()

        switch loadInitialTargets() {
        case .success(let parsed):
            logger.log("隧道守护启动 (pid \(getpid()))，目标 \(parsed.targets.count) 个")
            logDiagnostics(parsed.diagnostics)
            apply(parsed.targets)
        case .failure(let message):
            logger.log(message)
            logger.log("隧道守护启动 (pid \(getpid()))，目标 0 个")
        }

        startReloadTimer()
        startRequestTimer()
        startOwnerWatchdog()
        dispatchMain()
    }

    // MARK: - ownership

    /// Bind this daemon to the menu-bar app that launched it. The app is the
    /// sole owner of the daemon and every tunnel, so a daemon without a live
    /// owner must not keep tunnels up.
    private func recordOwnership() {
        guard let appPID = options.ownerAppPID else { return }
        let owner = DaemonOwner(daemonPID: getpid(), appPID: appPID)
        do {
            try DaemonOwner.write(owner, to: paths.ownerPath)
            logger.log("已绑定菜单栏 App (pid \(appPID))")
        } catch {
            // Not fatal: the app can still restart the daemon, just not adopt it.
            logger.log("无法写入守护归属记录: \(error.localizedDescription)")
        }
    }

    private func startOwnerWatchdog() {
        guard let appPID = options.ownerAppPID else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Daemon.ownerPollInterval,
                       repeating: Daemon.ownerPollInterval,
                       leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self, !self.shuttingDown else { return }
            guard !SingleInstanceLock.isAlive(appPID) else { return }
            self.logger.log("菜单栏 App (pid \(appPID)) 已退出，清理全部隧道")
            self.shutdown(reason: "App 退出")
        }
        timer.resume()
        ownerTimer = timer
    }

    // MARK: - config loading

    private enum ConfigLoad {
        case success(ParsedTargets)
        case failure(String)
    }

    private func loadInitialTargets() -> ConfigLoad {
        if FileManager.default.fileExists(atPath: paths.configPath) {
            guard let text = try? String(contentsOfFile: paths.configPath, encoding: .utf8) else {
                return .failure("配置文件 \(paths.configPath) 无法读取")
            }
            lastConfigText = text
            let parsed = TargetsParser.parse(text)
            lastDiagnostics = parsed.diagnostics
            return .success(parsed)
        }
        lastConfigText = nil
        lastDiagnostics = []
        if options.useDefaultTargetsWhenMissing {
            logger.log("配置文件 \(paths.configPath) 不存在，使用内置默认目标")
            return .success(ParsedTargets(targets: TargetConfig.builtInDefaults, rawLines: [], diagnostics: []))
        }
        logger.log("配置文件 \(paths.configPath) 不存在，--no-default-targets 已指定，不启动任何目标")
        return .success(ParsedTargets(targets: [], rawLines: [], diagnostics: []))
    }

    /// Read the config exactly as it is on disk right now.
    ///
    /// Unlike the polled path, a missing file means "zero targets", never the
    /// built-in defaults: this is the path taken right after the config window
    /// saved a file, and falling back to defaults there would resurrect tunnels
    /// the user just deleted.
    private enum ReadResult {
        case missing
        case text(String)
        case failure(String)
    }

    private func readConfigExplicitly() -> ReadResult {
        guard FileManager.default.fileExists(atPath: paths.configPath) else { return .missing }
        guard let text = try? String(contentsOfFile: paths.configPath, encoding: .utf8) else {
            return .failure("配置文件 \(paths.configPath) 无法读取")
        }
        return .text(text)
    }

    /// Reload tick: keep current targets on any read failure; apply
    /// differential changes only when the parsed content actually changed.
    private func reloadTick() {
        guard !shuttingDown else { return }

        guard FileManager.default.fileExists(atPath: paths.configPath) else {
            if options.useDefaultTargetsWhenMissing, lastConfigText != nil {
                logger.log("配置文件已删除，回退到内置默认目标")
                lastConfigText = nil
                lastDiagnostics = []
                apply(TargetConfig.builtInDefaults)
            }
            return
        }
        guard let text = try? String(contentsOfFile: paths.configPath, encoding: .utf8) else {
            logger.log("配置文件 \(paths.configPath) 本次读取失败，保持现有目标")
            return
        }
        guard text != lastConfigText else { return }

        let parsed = TargetsParser.parse(text)
        lastConfigText = text
        logger.log("检测到配置变更，重新加载（\(parsed.targets.count) 个目标）")
        if parsed.diagnostics != lastDiagnostics {
            logDiagnostics(parsed.diagnostics)
            lastDiagnostics = parsed.diagnostics
        }
        apply(parsed.targets)
    }

    private func logDiagnostics(_ diagnostics: [String]) {
        for line in diagnostics {
            logger.log("配置警告: \(line)")
        }
    }

    // MARK: - immediate reload requests

    private func startRequestTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Daemon.requestPollInterval,
                       repeating: Daemon.requestPollInterval,
                       leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.serviceReloadRequest() }
        timer.resume()
        requestTimer = timer
    }

    /// Answer one pending `reload.request` from the app.
    ///
    /// The ack carries the request id and the digest of the text the daemon
    /// actually used, so the app can prove this save — and not an older one —
    /// was applied. Requests are processed once; a repeat of the same id is
    /// ignored so a stale file can never re-trigger an apply.
    private func serviceReloadRequest() {
        guard !shuttingDown else { return }
        guard let request = reloadCoordinator.readRequest() else { return }
        guard request.requestID != lastHandledRequest else { return }
        lastHandledRequest = request.requestID

        let result = readConfigExplicitly()
        switch result {
        case .missing:
            lastConfigText = nil
            lastDiagnostics = []
            logger.log("收到配置重读请求 \(request.requestID)：配置文件不存在，停止全部目标")
            apply([])
            writeAck(for: request, computedText: "", outcome: .applied, detail: "配置文件不存在")
        case .failure(let message):
            logger.log("收到配置重读请求 \(request.requestID)：\(message)，保持现有目标")
            writeAck(for: request, computedText: nil, outcome: .failed, detail: message)
        case .text(let text):
            let parsed = TargetsParser.parse(text)
            lastConfigText = text
            if parsed.diagnostics != lastDiagnostics {
                logDiagnostics(parsed.diagnostics)
                lastDiagnostics = parsed.diagnostics
            }
            logger.log("收到配置重读请求 \(request.requestID)，应用 \(parsed.targets.count) 个目标")
            apply(parsed.targets)
            let digest = ConfigDigest.digest(text)
            if digest != request.digest {
                // The file changed between the app's write and this read; the
                // ack reports what was actually applied so the app can say so.
                writeAck(for: request, computedText: text, outcome: .applied,
                         detail: "配置文件在请求后被修改")
            } else {
                writeAck(for: request, computedText: text, outcome: .applied, detail: "")
            }
        }
    }

    private func writeAck(for request: ReloadRequest, computedText: String?,
                          outcome: ReloadAck.Outcome, detail: String) {
        let digest = computedText.map(ConfigDigest.digest) ?? request.digest
        let ack = ReloadAck(requestID: request.requestID,
                            digest: digest,
                            outcome: outcome,
                            targetCount: supervisors.count,
                            epoch: Int(Date().timeIntervalSince1970),
                            detail: detail)
        do {
            try reloadCoordinator.writeAck(ack)
        } catch {
            logger.log("无法写入重读确认: \(error.localizedDescription)")
        }
    }

    // MARK: - differential apply

    /// Reconcile running supervisors with the desired target set. Untouched
    /// healthy tunnels are left completely alone — no spawn, no status write.
    private func apply(_ targets: [TargetConfig]) {
        let incoming: [String: TargetConfig] = .init(targets.map { ($0.name, $0) },
                                                     uniquingKeysWith: { first, _ in first })

        for (name, supervisor) in supervisors where incoming[name] == nil {
            supervisor.stop()
            supervisors[name] = nil
            statusStore.write(name: name, record: .down(reason: "配置移除"))
            logger.log("[\(name)] 已从配置移除，停止隧道")
        }

        for (_, target) in incoming.sorted(by: { $0.key < $1.key }) {
            if let existing = supervisors[target.name] {
                if existing.target != target {
                    existing.stop()
                    supervisors[target.name] = nil
                    logger.log("[\(target.name)] 配置已变更，重启隧道")
                    startSupervisor(for: target)
                }
            } else {
                startSupervisor(for: target)
            }
        }
    }

    private func startSupervisor(for target: TargetConfig) {
        let supervisor = TargetSupervisor(target: target,
                                         sshBinary: paths.sshBinary,
                                         paths: paths,
                                         statusStore: statusStore,
                                         mainLog: logger,
                                         pollInterval: options.pollInterval)
        supervisors[target.name] = supervisor
        supervisor.start()
    }

    // MARK: - runloop plumbing

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in self?.shutdown(reason: nil) }
            source.activate()
            signalSources.append(source)
        }
    }

    private func startReloadTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + options.reloadInterval,
                       repeating: options.reloadInterval,
                       leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.reloadTick() }
        timer.resume()
        reloadTimer = timer
    }

    private func shutdown(reason: String?) {
        guard !shuttingDown else { return }
        shuttingDown = true
        reloadTimer?.cancel()
        requestTimer?.cancel()
        ownerTimer?.cancel()
        for source in signalSources { source.cancel() }

        for (name, supervisor) in supervisors {
            supervisor.stop()
            statusStore.write(name: name, record: .down(reason: "守护退出"))
        }
        supervisors.removeAll()

        if reason == nil {
            logger.log("隧道守护退出 (pid \(getpid()))")
        } else {
            logger.log("隧道守护退出 (pid \(getpid()))，原因：\(reason!)")
        }
        DaemonOwner.remove(path: paths.ownerPath)
        reloadCoordinator.clear()
        lock.release()
        exit(0)
    }
}
