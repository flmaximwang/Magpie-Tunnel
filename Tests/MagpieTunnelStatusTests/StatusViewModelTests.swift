import XCTest
@testable import MagpieTunnelCore
@testable import MagpieTunnelStatus

/// File-driven tests for StatusViewModel.refresh() and the headless
/// `--smoke-test` mode of the built binary. Everything stays in temp dirs.
final class StatusViewModelTests: XCTestCase {
    private var workDir: String!

    override func setUpWithError() throws {
        workDir = NSTemporaryDirectory() + "magpie-status-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: workDir + "/status", withIntermediateDirectories: true)
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

        XCTAssertEqual(state.summaryTitle, "magpie 隧道 1/2")
        XCTAssertFalse(state.allUp)
        XCTAssertEqual(state.targetRows.map(\.title),
                       ["✓ alpha localhost:3430", "✗ beta localhost:3431"])
        XCTAssertEqual(state.targetRows[0].url, "http://127.0.0.1:3430/?k=deadbeef")
        XCTAssertEqual(state.targetRows[1].url, "http://127.0.0.1:3431/")
    }

    func testRefreshPicksUpStatusChanges() throws {
        try writeConfig("alpha|3430|user@host|443|\n")
        let store = try StatusStore(directory: workDir + "/status")
        let viewModel = StatusViewModel(paths: makePaths())

        XCTAssertEqual(viewModel.refresh().summaryTitle, "magpie 隧道 0/1")
        store.write(name: "alpha", record: .up(port: 3430))
        let state = viewModel.refresh()
        XCTAssertEqual(state.summaryTitle, "magpie 隧道 1/1")
        XCTAssertTrue(state.allUp)
        XCTAssertEqual(state.iconEmoji, "🔗")
    }

    func testMissingConfigFallsBackToBuiltInDefaults() throws {
        let viewModel = StatusViewModel(paths: makePaths())
        let state = viewModel.refresh()
        // The two legacy default targets, both without status files → 0/2.
        XCTAssertEqual(state.targetRows.map(\.name), ["TC2C4G2026", "ZLab4090D"])
        XCTAssertEqual(state.summaryTitle, "magpie 隧道 0/2")
    }

    func testEmptyConfigRendersZeroTargets() throws {
        try writeConfig("# nothing configured\n")
        let state = StatusViewModel(paths: makePaths()).refresh()
        XCTAssertEqual(state.summaryTitle, "magpie 隧道 0/0")
        XCTAssertTrue(state.targetRows.isEmpty)
        XCTAssertEqual(state.iconEmoji, "🔗⃠")
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
        XCTAssertTrue(output.contains("magpie 隧道 1/1"), "输出应含摘要: \(output)")
        XCTAssertTrue(output.contains("✓ alpha localhost:3430"), "输出应含目标行: \(output)")
        XCTAssertTrue(output.contains("http://127.0.0.1:3430/?k=deadbeef"), "输出应含 URL: \(output)")
        XCTAssertFalse(output.contains("?key="), "绝不能用 ?key=: \(output)")
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
