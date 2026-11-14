import Foundation
import MagpieTunnelCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The daemon: owns the single-instance lock, the supervisor set, the config
/// hot-reload timer, and graceful SIGTERM/SIGINT shutdown.
final class Daemon {
    private let options: DaemonOptions
    private let paths: TunnelPaths
    private let logger: RotatingFileLogger
    private let statusStore: StatusStore
    private let lock: SingleInstanceLock

    private var supervisors: [String: TargetSupervisor] = [:]
    private var lastConfigText: String?
    private var lastDiagnostics: [String] = []
    private var reloadTimer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var shuttingDown = false

    init(options: DaemonOptions) throws {
        self.options = options
        self.paths = options.resolvedPaths()
        self.logger = try RotatingFileLogger(filePath: paths.mainLogPath)
        self.statusStore = try StatusStore(directory: paths.statusDirectory)
        self.lock = SingleInstanceLock(lockFilePath: paths.lockFilePath,
                                       legacyLockDirectory: paths.legacyLockDirectory)
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
        dispatchMain()
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
        if options.useDefaultTargetsWhenMissing {
            lastConfigText = nil
            lastDiagnostics = []
            logger.log("配置文件 \(paths.configPath) 不存在，使用内置默认目标")
            return .success(ParsedTargets(targets: TargetConfig.builtInDefaults, rawLines: [], diagnostics: []))
        }
        lastConfigText = nil
        lastDiagnostics = []
        logger.log("配置文件 \(paths.configPath) 不存在，--no-default-targets 已指定，不启动任何目标")
        return .success(ParsedTargets(targets: [], rawLines: [], diagnostics: []))
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
            source.setEventHandler { [weak self] in self?.shutdown() }
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

    private func shutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true
        reloadTimer?.cancel()
        for source in signalSources { source.cancel() }

        for (name, supervisor) in supervisors {
            supervisor.stop()
            statusStore.write(name: name, record: .down(reason: "守护退出"))
        }
        supervisors.removeAll()

        logger.log("隧道守护退出 (pid \(getpid()))")
        lock.release()
        exit(0)
    }
}
