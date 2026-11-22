import XCTest
@testable import MagpieTunnelCore
@testable import MagpieTunnelStatus

/// File-driven tests for `StatusViewModel.refresh()` and the headless
/// `--smoke-test` mode of the built binary. Everything stays in temp dirs.
final class StatusViewModelTests: XCTestCase {
    private var workDir: String!

    override func setUpWithError() throws {
        workDir = NSTemporaryDirectory() + "magpie-status-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: workDir + "/status",
                                                withIntermediateDirectories: true)
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

    private func writeConfig(_ text: String) throws {
        try text.write(toFile: workDir + "/targets.conf", atomically: true, encoding: .utf8)
    }

    func testRefreshReadsConfigAndStatusFiles() throws {
        try writeConfig("alpha|3430|user@host|443|deadbeef\nbeta|3431|user@host|443|\n")
        let store = try StatusStore(directory: workDir + "/status")
        store.write(name: "alpha", record: .up(port: 3430))

        let viewModel = StatusViewModel(paths: makePaths())
        let state = viewModel.refresh()

        XCTAssertEqual(state.subtitle, "2 条隧道，1 条已连接")
        XCTAssertFalse(state.allUp)
        XCTAssertEqual(state.rows.map(\.title),
                       ["alpha  127.0.0.1:3430  已连接", "beta  127.0.0.1:3431  状态未知"])
        XCTAssertEqual(state.rows[0].url, "http://127.0.0.1:3430/?k=deadbeef")
        XCTAssertEqual(state.rows[1].url, "http://127.0.0.1:3431/")
        XCTAssertEqual(viewModel.lastDiagnostics, [])
    }

    func testRefreshPicksUpStatusChanges() throws {
        try writeConfig("alpha|3430|user@host|443|\n")
        let store = try StatusStore(directory: workDir + "/status")
        let viewModel = StatusViewModel(paths: makePaths())

        XCTAssertEqual(viewModel.refresh().subtitle, "1 条隧道，状态未知")
        store.write(name: "alpha", record: .up(port: 3430))
        let state = viewModel.refresh()
        XCTAssertEqual(state.subtitle, "1 条隧道，已连接")
        XCTAssertTrue(state.allUp)
        XCTAssertEqual(state.iconState, .healthy)
    }

    func testMissingConfigMeansNoTunnelsNotBuiltInDefaults() throws {
        // A missing file is "nothing configured". Falling back to the sample
        // targets would list tunnels the user never asked for — and would
        // resurrect the last tunnel they just deleted.
        let state = StatusViewModel(paths: makePaths()).refresh()
        XCTAssertTrue(state.rows.isEmpty)
        XCTAssertEqual(state.emptyState, .noTunnels)
        XCTAssertEqual(state.subtitle, "尚未配置隧道")
        XCTAssertEqual(state.iconState, .degraded)
    }

    func testEmptyConfigRendersZeroTargets() throws {
        try writeConfig("# nothing configured\n")
        let state = StatusViewModel(paths: makePaths()).refresh()
        XCTAssertTrue(state.rows.isEmpty)
        XCTAssertEqual(state.emptyState, .noTunnels)
    }

    func testBrokenLinesAreReportedWithLineNumbers() throws {
        try writeConfig("""
        # comment
        good|3430|user@host|443|
        broken

        """)
        let viewModel = StatusViewModel(paths: makePaths())
        let state = viewModel.refresh()
        XCTAssertEqual(state.rows.map(\.name), ["good"])
        XCTAssertEqual(state.configDiagnostics.count, 1)
        XCTAssertTrue(state.configDiagnostics[0].contains("第 3 行"), "\(state.configDiagnostics)")
        XCTAssertEqual(state.subtitle, "1 条隧道，另有 1 行配置错误")
        XCTAssertEqual(state.iconState, .degraded)
    }

    func testOnlyBrokenLinesOfferFix() throws {
        try writeConfig("broken\n")
        let state = StatusViewModel(paths: makePaths()).refresh()
        XCTAssertEqual(state.emptyState, .brokenConfiguration(count: 1))
        XCTAssertEqual(state.emptyState.actionTitle, "修正配置")
    }

    // MARK: - binary smoke test

    func testSmokeTestModeOfBuiltBinary() throws {
        try writeConfig("alpha|3430|user@host|443|deadbeef\n")
        let store = try StatusStore(directory: workDir + "/status")
        store.write(name: "alpha", record: .up(port: 3430))

        let binary = try XCTUnwrap(Self.statusBinaryPath())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--smoke-test", "--config", workDir + "/targets.conf",
                             "--status-dir", workDir + "/status"]
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("MAGPIE_TUNNEL_") }
        environment["HOME"] = workDir // full isolation of default paths too
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("icon=healthy"), "输出应含图标状态: \(output)")
        XCTAssertTrue(output.contains("1 条隧道，已连接"), "输出应含副标题: \(output)")
        XCTAssertTrue(output.contains("alpha  127.0.0.1:3430  已连接"), "输出应含隧道行: \(output)")
        XCTAssertTrue(output.contains("http://127.0.0.1:3430/?k=deadbeef"), "输出应含 URL: \(output)")
        XCTAssertFalse(output.contains("?key="), "绝不能用 ?key=: \(output)")
    }

    func testSmokeTestEmptyConfigShowsAddPrompt() throws {
        let binary = try XCTUnwrap(Self.statusBinaryPath())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--smoke-test", "--config", workDir + "/missing.conf",
                             "--status-dir", workDir + "/status"]
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("MAGPIE_TUNNEL_") }
        environment["HOME"] = workDir
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("icon=degraded"), output)
        XCTAssertTrue(output.contains("尚未配置隧道"), output)
        XCTAssertTrue(output.contains("按钮: 添加隧道"), output)
    }

    private static func statusBinaryPath() -> String? {
        let testFile = #filePath as NSString
        let repoRoot = testFile.deletingLastPathComponent // .../Tests/MagpieTunnelStatusTests
            .components(separatedBy: "/").dropLast(2).joined(separator: "/")
        for candidate in [repoRoot + "/.build/out/Products/Debug/MagpieTunnelStatus",
                          repoRoot + "/.build/debug/MagpieTunnelStatus",
                          repoRoot + "/.build/arm64-apple-macosx/debug/MagpieTunnelStatus"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
