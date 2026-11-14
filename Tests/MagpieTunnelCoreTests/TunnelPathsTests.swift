import XCTest
@testable import MagpieTunnelCore

final class TunnelPathsTests: XCTestCase {
    func testDefaultsMatchLegacyLayout() {
        let paths = TunnelPaths.defaults(home: "/Users/tester", environment: [:])
        XCTAssertEqual(paths.configPath, "/Users/tester/Library/Application Support/MagpieWebTunnel/targets.conf")
        XCTAssertEqual(paths.statusDirectory, "/Users/tester/Library/Application Support/MagpieWebTunnel/status")
        XCTAssertEqual(paths.logDirectory, "/Users/tester/Library/Logs")
        XCTAssertEqual(paths.lockDirectory, "/Users/tester/Library/Application Support/MagpieWebTunnel")
        XCTAssertEqual(paths.sshBinary, "/usr/bin/ssh")
    }

    func testMainAndTargetLogPathsMatchLegacyNames() {
        let paths = TunnelPaths.defaults(home: "/Users/tester", environment: [:])
        XCTAssertEqual(paths.mainLogPath, "/Users/tester/Library/Logs/magpie-web-tunnel.log")
        XCTAssertEqual(paths.targetLogPath(name: "TC2C4G2026"),
                       "/Users/tester/Library/Logs/magpie-web-tunnel-TC2C4G2026.log")
    }

    func testLockPaths() {
        let paths = TunnelPaths.defaults(home: "/Users/tester", environment: [:])
        XCTAssertEqual(paths.lockFilePath,
                       "/Users/tester/Library/Application Support/MagpieWebTunnel/tunneld.lock")
        XCTAssertEqual(paths.legacyLockDirectory,
                       "/Users/tester/Library/Application Support/MagpieWebTunnel/tunnel.lock")
    }

    func testEnvironmentOverrides() {
        let env = [
            "MAGPIE_TUNNEL_CONFIG": "/tmp/x/targets.conf",
            "MAGPIE_TUNNEL_STATUS_DIR": "/tmp/x/status",
            "MAGPIE_TUNNEL_LOG_DIR": "/tmp/x/logs",
            "MAGPIE_TUNNEL_LOCK_DIR": "/tmp/x/lock",
            "MAGPIE_TUNNEL_SSH_BIN": "/tmp/x/mock-ssh",
        ]
        let paths = TunnelPaths.defaults(home: "/Users/tester", environment: env)
        XCTAssertEqual(paths.configPath, "/tmp/x/targets.conf")
        XCTAssertEqual(paths.statusDirectory, "/tmp/x/status")
        XCTAssertEqual(paths.logDirectory, "/tmp/x/logs")
        XCTAssertEqual(paths.lockDirectory, "/tmp/x/lock")
        XCTAssertEqual(paths.sshBinary, "/tmp/x/mock-ssh")
        XCTAssertEqual(paths.lockFilePath, "/tmp/x/lock/tunneld.lock")
    }
}
