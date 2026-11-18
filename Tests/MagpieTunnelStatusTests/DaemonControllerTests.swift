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

        func recordedPID(lockFilePath: String) -> Int32? { lockPID }
        func legacyPID(lockDirectory: String) -> Int32? { legacyPIDValue }
        func isAlive(_ pid: Int32) -> Bool { alivePIDs.contains(pid) }

        func terminate(_ pid: Int32, grace: TimeInterval) -> Bool {
            terminateCallCount += 1
            if terminateResult { alivePIDs.remove(pid) }
            return terminateResult
        }

        func spawn(executable: String, logPath: String) -> Int32? {
            spawnCallCount += 1
            lastSpawnExecutable = executable
            lastSpawnLogPath = logPath
            if let pid = spawnPID { alivePIDs.insert(pid) }
            return spawnPID
        }
    }

    private func makeController(system: FakeSystem,
                                executable: String = "/Applications/MagpieWebTunnel.app/Contents/MacOS/magpie-tunneld")
        -> DaemonController {
        DaemonController(paths: makePaths(),
                         system: system,
                         locateExecutable: { executable })
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
        XCTAssertNil(controller.lastDiagnostic)
    }

    func testStartIfNeededNeverSpawnsWhenDaemonAlreadyLive() {
        let system = FakeSystem()
        system.lockPID = 900
        system.alivePIDs = [900]
        let controller = makeController(system: system)
        controller.startIfNeeded()

        XCTAssertEqual(system.spawnCallCount, 0, "第二次打开 App 不能再起一个守护")
        XCTAssertNil(controller.lastDiagnostic)
    }

    func testStartIfNeededReportsMissingBundledExecutable() {
        let system = FakeSystem()
        let controller = DaemonController(paths: makePaths(), system: system, locateExecutable: { nil })
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
        let controller = DaemonController(paths: makePaths(), system: system, locateExecutable: { nil })

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
}
