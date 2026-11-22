import XCTest
@testable import MagpieTunnelCore
@testable import MagpieTunnelStatus

/// Decision-logic tests for `DaemonController` with a fake `DaemonSystem`:
/// nothing here spawns a process, kills a PID or touches the real support dir.
final class DaemonControllerTests: XCTestCase {
    private var workDir: String!

    override func setUpWithError() throws {
        workDir = NSTemporaryDirectory() + "magpie-daemon-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: workDir)
    }

    private func makePaths() -> TunnelPaths {
        TunnelPaths(configPath: workDir + "/targets.conf",
                    statusDirectory: workDir + "/status",
                    logDirectory: workDir + "/logs",
                    lockDirectory: workDir + "/lock",
                    sshBinary: "/usr/bin/ssh")
    }

    /// Records every call so the test can assert what the controller asked for.
    final class FakeSystem: DaemonSystem {
        var lockPID: Int32?
        var legacyPIDValue: Int32?
        var alivePIDs: Set<Int32> = []
        var terminateResult = true
        var spawnPID: Int32? = 4242
        var spawnCallCount = 0
        var terminateCallCount = 0
        var lastSpawnExecutable: String?
        var lastSpawnLogPath: String?
        var lastSpawnArguments: [String] = []
        var spawnArguments: [[String]] = []
        var lastSpawnEnvironment: [String: String] = [:]
        var owner: DaemonOwner?

        func recordedPID(lockFilePath: String) -> Int32? { lockPID }
        func legacyPID(lockDirectory: String) -> Int32? { legacyPIDValue }
        func isAlive(_ pid: Int32) -> Bool { alivePIDs.contains(pid) }

        func terminate(_ pid: Int32, grace: TimeInterval) -> Bool {
            terminateCallCount += 1
            if terminateResult { alivePIDs.remove(pid) }
            return terminateResult
        }

        func spawn(executable: String, logPath: String, arguments: [String],
                   environment: [String: String]) -> Int32? {
            spawnCallCount += 1
            lastSpawnExecutable = executable
            lastSpawnLogPath = logPath
            lastSpawnArguments = arguments
            spawnArguments.append(arguments)
            lastSpawnEnvironment = environment
            if let pid = spawnPID { alivePIDs.insert(pid) }
            return spawnPID
        }

        func ownerRecord(path: String) -> DaemonOwner? { owner }
    }

    private func makeController(system: FakeSystem,
                                appPID: Int32 = 777,
                                executable: String = "/Applications/MagpieWebTunnel.app/Contents/MacOS/magpie-tunneld")
        -> DaemonController {
        DaemonController(paths: makePaths(),
                         system: system,
                         appPIDProvider: { appPID },
                         locateExecutable: { executable })
    }

    /// Splits a `--flag value` argument list into a dictionary, so tests can
    /// assert individual paths without pinning the whole order.
    private func flagValues(_ arguments: [String]) -> [String: String] {
        var values: [String: String] = [:]
        var index = 0
        while index + 1 < arguments.count {
            let flag = arguments[index]
            if flag.hasPrefix("--") { values[flag] = arguments[index + 1] }
            index += 2
        }
        return values
    }

    private func assertSpawnCarriesIsolation(_ system: FakeSystem, file: StaticString = #filePath,
                                             line: UInt = #line) {
        let paths = makePaths()
        XCTAssertFalse(system.spawnArguments.isEmpty, "期望至少一次 spawn", file: file, line: line)
        // Every spawn call, not just the latest one, must carry the paths.
        for arguments in system.spawnArguments {
            let flags = flagValues(arguments)
            XCTAssertEqual(flags["--config"], paths.configPath,
                           "隔离运行必须让守护看到 App 的 --config", file: file, line: line)
            XCTAssertEqual(flags["--status-dir"], paths.statusDirectory, file: file, line: line)
            XCTAssertEqual(flags["--log-dir"], paths.logDirectory, file: file, line: line)
            XCTAssertEqual(flags["--lock-dir"], paths.lockDirectory,
                           "锁目录必须是 App 的隔离目录，否则守护会抢生产锁", file: file, line: line)
            XCTAssertEqual(flags["--ssh-bin"], paths.sshBinary, file: file, line: line)
            XCTAssertEqual(flags["--owner-pid"], "777", file: file, line: line)
        }
    }

    // MARK: - Detection

    func testCurrentDaemonPIDReadsLiveLockFilePID() {
        let system = FakeSystem()
        system.lockPID = 501
        system.alivePIDs = [501]
        XCTAssertEqual(makeController(system: system).currentDaemonPID(), 501)
    }

    func testCurrentDaemonPIDIgnoresStaleLockFile() {
        let system = FakeSystem()
        system.lockPID = 501          // recorded, but the process is gone
        system.alivePIDs = []
        XCTAssertNil(makeController(system: system).currentDaemonPID())
    }

    func testCurrentDaemonPIDFallsBackToLegacyDirectoryLock() {
        let system = FakeSystem()
        system.legacyPIDValue = 77
        system.alivePIDs = [77]
        XCTAssertEqual(makeController(system: system).currentDaemonPID(), 77)
    }

    // MARK: - Start on open

    func testStartIfNeededSpawnsWhenNothingIsRunning() {
        let system = FakeSystem()
        let controller = makeController(system: system)
        controller.startIfNeeded()

        XCTAssertEqual(system.spawnCallCount, 1)
        XCTAssertEqual(system.lastSpawnExecutable,
                       "/Applications/MagpieWebTunnel.app/Contents/MacOS/magpie-tunneld")
        XCTAssertEqual(system.lastSpawnLogPath, makePaths().mainLogPath)
        XCTAssertEqual(system.lastSpawnArguments,
                       ["--config", makePaths().configPath,
                        "--status-dir", makePaths().statusDirectory,
                        "--log-dir", makePaths().logDirectory,
                        "--lock-dir", makePaths().lockDirectory,
                        "--ssh-bin", "/usr/bin/ssh",
                        "--owner-pid", "777"],
                       "守护必须绑定到当前 App 进程，并使用同一套路径")
        XCTAssertNil(controller.lastDiagnostic)
        XCTAssertEqual(controller.ownedDaemonPID, 4242)
    }

    func testStartIfNeededPassesPathsToDaemon() {
        let system = FakeSystem()
        let controller = makeController(system: system)
        controller.startIfNeeded()

        XCTAssertEqual(system.spawnCallCount, 1)
        assertSpawnCarriesIsolation(system)
        XCTAssertEqual(controller.ownedDaemonPID, 4242)
    }

    func testSpawnInheritsAppEnvironmentSoEnvOverridesReachTheDaemon() {
        let system = FakeSystem()
        let controller = makeController(system: system)
        controller.startIfNeeded()

        XCTAssertEqual(system.spawnCallCount, 1)
        XCTAssertEqual(system.lastSpawnEnvironment, ProcessInfo.processInfo.environment,
                       "子进程环境必须是 App 自己环境的副本，MAGPIE_TUNNEL_* 才能继续生效")
    }

    func testStartIfNeededAdoptsDaemonAlreadyOwnedByThisApp() {
        let system = FakeSystem()
        system.lockPID = 900
        system.alivePIDs = [900]
        system.owner = DaemonOwner(daemonPID: 900, appPID: 777)
        let controller = makeController(system: system)
        controller.startIfNeeded()

        XCTAssertEqual(system.spawnCallCount, 0, "本次 App 的守护不需要重启")
        XCTAssertEqual(system.terminateCallCount, 0)
        XCTAssertEqual(controller.ownedDaemonPID, 900)
    }

    func testStartIfNeededReplacesDaemonLeftOverFromPreviousAppRun() {
        let system = FakeSystem()
        system.lockPID = 900
        system.alivePIDs = [900]
        system.owner = DaemonOwner(daemonPID: 900, appPID: 123)   // an older app
        let controller = makeController(system: system)
        controller.startIfNeeded()

        XCTAssertEqual(system.terminateCallCount, 1, "上次运行的守护不能继续服务")
        XCTAssertEqual(system.spawnCallCount, 1)
        XCTAssertTrue(system.alivePIDs.contains(4242))
        XCTAssertFalse(system.alivePIDs.contains(900))
    }

    func testStartIfNeededReplacesDaemonWithoutOwnerRecord() {
        let system = FakeSystem()
        system.lockPID = 900
        system.alivePIDs = [900]
        system.owner = nil
        let controller = makeController(system: system)
        controller.startIfNeeded()

        XCTAssertEqual(system.terminateCallCount, 1, "归属未知的守护同样要换掉")
        XCTAssertEqual(system.spawnCallCount, 1)
    }

    func testStartIfNeededReportsMissingBundledExecutable() {
        let system = FakeSystem()
        let controller = DaemonController(paths: makePaths(), system: system,
                                          appPIDProvider: { 777 }, locateExecutable: { nil })
        controller.startIfNeeded()

        XCTAssertEqual(system.spawnCallCount, 0)
        XCTAssertEqual(controller.lastDiagnostic, "找不到隧道守护可执行文件；隧道不会自动启动")
    }

    func testStartIfNeededReportsSpawnFailure() {
        let system = FakeSystem()
        system.spawnPID = nil
        let controller = makeController(system: system)
        controller.startIfNeeded()

        XCTAssertEqual(system.spawnCallCount, 1)
        XCTAssertEqual(controller.lastDiagnostic,
                       "隧道守护启动失败（/Applications/MagpieWebTunnel.app/Contents/MacOS/magpie-tunneld）")
    }

    // MARK: - Restart

    func testRestartTerminatesThenSpawns() {
        let system = FakeSystem()
        system.lockPID = 1200
        system.alivePIDs = [1200]
        let controller = makeController(system: system)

        let result = controller.restartSynchronously()

        XCTAssertTrue(result.ok)
        XCTAssertNil(result.diagnostic)
        XCTAssertEqual(system.terminateCallCount, 1)
        XCTAssertEqual(system.spawnCallCount, 1, "重启必须先停再起")
    }

    func testRestartPassesPathsToDaemon() {
        let system = FakeSystem()
        system.lockPID = 1200
        system.alivePIDs = [1200]
        let controller = makeController(system: system)

        let result = controller.restartSynchronously()

        XCTAssertTrue(result.ok, "重启路径同样要带全套路径参数")
        XCTAssertEqual(system.spawnCallCount, 1)
        assertSpawnCarriesIsolation(system)
    }

    func testRestartWithoutRunningDaemonPassesPathsToDaemon() {
        let system = FakeSystem()
        let controller = makeController(system: system)

        _ = controller.restartSynchronously()

        XCTAssertEqual(system.spawnCallCount, 1)
        assertSpawnCarriesIsolation(system)
    }

    func testRestartSpawnsWithoutKillingWhenNothingRunning() {
        let system = FakeSystem()
        system.alivePIDs = []
        let controller = makeController(system: system)

        let result = controller.restartSynchronously()

        XCTAssertTrue(result.ok)
        XCTAssertEqual(system.terminateCallCount, 0, "没有在跑的守护可杀")
        XCTAssertEqual(system.spawnCallCount, 1)
    }

    func testRestartStopsWhenOldDaemonWontDie() {
        let system = FakeSystem()
        system.lockPID = 1300
        system.alivePIDs = [1300]
        system.terminateResult = false
        let controller = makeController(system: system)

        let result = controller.restartSynchronously(grace: 3)

        XCTAssertFalse(result.ok)
        XCTAssertEqual(system.spawnCallCount, 0, "旧守护没退出就不能再起一个")
        XCTAssertEqual(result.diagnostic, "旧的隧道守护 (pid 1300) 未能在 3 秒内退出")
        XCTAssertEqual(controller.lastDiagnostic, nil, "同步路径由调用方记录诊断")
    }

    func testRestartReportsMissingExecutableAfterStoppingOldDaemon() {
        let system = FakeSystem()
        system.lockPID = 1400
        system.alivePIDs = [1400]
        let controller = DaemonController(paths: makePaths(), system: system,
                                          appPIDProvider: { 777 }, locateExecutable: { nil })

        let result = controller.restartSynchronously()

        XCTAssertFalse(result.ok)
        XCTAssertEqual(system.terminateCallCount, 1, "先停旧进程再报告缺可执行文件")
        XCTAssertEqual(system.spawnCallCount, 0)
        XCTAssertEqual(result.diagnostic, "找不到隧道守护可执行文件")
    }

    func testAsyncRestartRecordsDiagnosticOnFailure() {
        let system = FakeSystem()
        system.spawnPID = nil            // nothing running, spawn fails
        let controller = makeController(system: system)
        let expectation = expectation(description: "restart completion")

        controller.restart { expectation.fulfill() }
        wait(for: [expectation], timeout: 5)

        XCTAssertEqual(controller.lastDiagnostic,
                       "隧道守护启动失败（/Applications/MagpieWebTunnel.app/Contents/MacOS/magpie-tunneld）")
    }

    // MARK: - Quit path

    func testStopSynchronouslyKillsDaemonAndClearsOwnerRecord() {
        let system = FakeSystem()
        system.lockPID = 1500
        system.alivePIDs = [1500]
        let paths = makePaths()
        try? DaemonOwner.write(DaemonOwner(daemonPID: 1500, appPID: 777), to: paths.ownerPath)
        let controller = DaemonController(paths: paths, system: system, appPIDProvider: { 777 })

        XCTAssertTrue(controller.stopSynchronously())
        XCTAssertEqual(system.terminateCallCount, 1, "退出 App 必须结束守护")
        XCTAssertFalse(system.alivePIDs.contains(1500))
        XCTAssertNil(DaemonOwner.read(path: paths.ownerPath))
    }

    func testStopSynchronouslyIsQuietWhenNothingRuns() {
        let system = FakeSystem()
        let controller = makeController(system: system)

        XCTAssertTrue(controller.stopSynchronously())
        XCTAssertEqual(system.terminateCallCount, 0)
        XCTAssertEqual(controller.lastDiagnostic, nil)
    }

    func testStopSynchronouslyReportsDaemonThatRefusesToDie() {
        let system = FakeSystem()
        system.lockPID = 1600
        system.alivePIDs = [1600]
        system.terminateResult = false
        let controller = makeController(system: system)

        XCTAssertFalse(controller.stopSynchronously(grace: 3))
        XCTAssertEqual(controller.lastDiagnostic, "隧道守护 (pid 1600) 未能在 3 秒内退出")
    }

    // MARK: - Immediate reload / apply confirmation

    func testApplyConfigurationReportsUnconfirmedWhenDaemonIsNotRunning() {
        let system = FakeSystem()
        let controller = makeController(system: system)

        let outcome = controller.applyConfiguration(digest: "abc", timeout: 0.5)

        XCTAssertEqual(outcome, .unconfirmed(detail: "隧道守护未运行"))
        XCTAssertFalse(outcome.isApplied)
        XCTAssertEqual(outcome.statusText, "配置已保存，尚未确认应用（隧道守护未运行）")
    }

    func testApplyConfigurationWaitsForAckOfThisExactRequest() {
        let system = FakeSystem()
        system.lockPID = 4242
        system.alivePIDs = [4242]
        let controller = makeController(system: system)
        let paths = makePaths()
        let coordinator = ReloadCoordinator(lockDirectory: paths.lockDirectory)

        // Stand in for the daemon: answer only requests it actually sees.
        let responder = expectation(description: "daemon answered")
        let thread = Thread {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if let request = coordinator.readRequest() {
                    let ack = ReloadAck(requestID: request.requestID, digest: request.digest,
                                        outcome: .applied, targetCount: 2)
                    try? coordinator.writeAck(ack)
                    responder.fulfill()
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        thread.start()

        let outcome = controller.applyConfiguration(digest: "digest-1", timeout: 5)
        wait(for: [responder], timeout: 6)

        XCTAssertEqual(outcome, .applied(targetCount: 2, note: nil))
        XCTAssertTrue(outcome.isApplied)
        XCTAssertEqual(outcome.statusText, "已应用")
    }

    func testApplyConfigurationIgnoresAckOfAnEarlierRequest() {
        let system = FakeSystem()
        system.lockPID = 4242
        system.alivePIDs = [4242]
        let controller = makeController(system: system)
        let coordinator = controller.reloadCoordinator
        try? coordinator.writeAck(ReloadAck(requestID: "older-request", digest: "digest-0",
                                            outcome: .applied, targetCount: 9))

        let outcome = controller.applyConfiguration(digest: "digest-1", timeout: 0.5)

        XCTAssertEqual(outcome, .unconfirmed(detail: "等待 0 秒未收到守护确认"))
    }

    func testApplyConfigurationReportsRejectedConfiguration() {
        let system = FakeSystem()
        system.lockPID = 4242
        system.alivePIDs = [4242]
        let controller = makeController(system: system)
        let coordinator = controller.reloadCoordinator

        let thread = Thread {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if let request = coordinator.readRequest() {
                    let ack = ReloadAck(requestID: request.requestID, digest: request.digest,
                                        outcome: .failed, targetCount: 0,
                                        detail: "配置文件无法读取")
                    try? coordinator.writeAck(ack)
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        thread.start()

        let outcome = controller.applyConfiguration(digest: "digest-1", timeout: 5)

        XCTAssertEqual(outcome, .rejected(detail: "配置文件无法读取"))
        XCTAssertFalse(outcome.isApplied)
        XCTAssertEqual(outcome.statusText, "配置已保存，但守护进程未能应用（配置文件无法读取）")
    }
}
