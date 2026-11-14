import XCTest
@testable import MagpieTunnelCore

final class SingleInstanceLockTests: XCTestCase {
    var dir: String!
    var lockPath: String!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("magpie-lock-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        lockPath = dir + "/tunneld.lock"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    func testSecondAcquireFailsWhileFirstHeld() {
        let first = SingleInstanceLock(lockFilePath: lockPath)
        XCTAssertTrue(first.tryAcquire())
        XCTAssertEqual(first.recordedPID(), getpid())

        let second = SingleInstanceLock(lockFilePath: lockPath)
        XCTAssertFalse(second.tryAcquire())
        XCTAssertEqual(second.otherPID, getpid())
    }

    func testReleaseAllowsReacquire() {
        let first = SingleInstanceLock(lockFilePath: lockPath)
        XCTAssertTrue(first.tryAcquire())
        first.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath))

        let second = SingleInstanceLock(lockFilePath: lockPath)
        XCTAssertTrue(second.tryAcquire())
    }

    func testStaleLockFileDoesNotBlockAfterCrash() throws {
        // Simulate a crashed holder: lock file exists but nobody flocks it.
        try "999999\n".write(toFile: lockPath, atomically: true, encoding: .utf8)
        let lock = SingleInstanceLock(lockFilePath: lockPath)
        XCTAssertTrue(lock.tryAcquire())
    }

    func testLegacyLiveDaemonBlocksAcquire() throws {
        let legacyDir = dir + "/tunnel.lock"
        try FileManager.default.createDirectory(atPath: legacyDir, withIntermediateDirectories: false)
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate(); sleeper.waitUntilExit() }
        try "\(sleeper.processIdentifier)\n".write(toFile: legacyDir + "/pid", atomically: true, encoding: .utf8)

        let lock = SingleInstanceLock(lockFilePath: lockPath, legacyLockDirectory: legacyDir)
        XCTAssertFalse(lock.tryAcquire())
        XCTAssertEqual(lock.otherPID, sleeper.processIdentifier)
    }

    func testLegacyStaleLockIsCleanedUp() throws {
        let legacyDir = dir + "/tunnel.lock"
        try FileManager.default.createDirectory(atPath: legacyDir, withIntermediateDirectories: false)
        try "999999\n".write(toFile: legacyDir + "/pid", atomically: true, encoding: .utf8)

        let lock = SingleInstanceLock(lockFilePath: lockPath, legacyLockDirectory: legacyDir)
        XCTAssertTrue(lock.tryAcquire())
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyDir), "stale legacy lock should be removed")
    }

    func testIsAliveDetectsRealAndDeadPIDs() {
        XCTAssertTrue(SingleInstanceLock.isAlive(getpid()))
        XCTAssertFalse(SingleInstanceLock.isAlive(999999))
        XCTAssertFalse(SingleInstanceLock.isAlive(-1))
    }
}
