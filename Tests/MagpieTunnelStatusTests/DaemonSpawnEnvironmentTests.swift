import XCTest
@testable import MagpieTunnelStatus

/// Locks the *live* spawn path: `LiveDaemonSystem.spawn` must hand the child
/// exactly the environment dictionary it was given, because the daemon resolves
/// `MAGPIE_TUNNEL_CONFIG / STATUS_DIR / LOG_DIR / LOCK_DIR / SSH_BIN` from it.
///
/// This is the one test that actually launches a process — `/usr/bin/env`, which
/// exits immediately and touches nothing.
final class DaemonSpawnEnvironmentTests: XCTestCase {
    private var workDir: String!

    override func setUpWithError() throws {
        workDir = NSTemporaryDirectory() + "magpie-spawn-env-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: workDir)
    }

    func testSpawnPassesExplicitEnvironmentToChild() throws {
        let dir: String = workDir
        let logPath = dir + "/spawn.log"
        let system = LiveDaemonSystem()
        let sshBin = dir + "/mock-ssh"
        let lockDir = dir + "/lock"
        let environment = ["MAGPIE_TUNNEL_SSH_BIN": sshBin,
                           "MAGPIE_TUNNEL_LOCK_DIR": lockDir]

        XCTAssertNotNil(system.spawn(executable: "/usr/bin/env", logPath: logPath,
                                     arguments: [], environment: environment),
                        "spawn should report the child's pid")

        // The child writes its own environment; give it a moment to exit.
        let deadline = Date().addingTimeInterval(5)
        var text = ""
        while Date() < deadline {
            text = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
            if text.contains("MAGPIE_TUNNEL_SSH_BIN=") { break }
            Thread.sleep(forTimeInterval: 0.05)
        }

        XCTAssertTrue(text.contains("MAGPIE_TUNNEL_SSH_BIN=\(sshBin)"),
                      "子进程必须拿到显式传入的 MAGPIE_TUNNEL_SSH_BIN，实际日志:\n\(text)")
        XCTAssertTrue(text.contains("MAGPIE_TUNNEL_LOCK_DIR=\(lockDir)"),
                      "隔离锁目录必须原样传给守护，实际日志:\n\(text)")
    }
}
