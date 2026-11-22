import XCTest
@testable import MagpieTunnelCore

/// Tests for the reload rendezvous: digest stability, request/ack round trips
/// through the lock directory, and log tailing across rotation.
final class ReloadCoordinatorTests: XCTestCase {
    private var workDir: String!

    override func setUpWithError() throws {
        workDir = NSTemporaryDirectory() + "magpie-reload-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: workDir)
    }

    private var lockDir: String { workDir + "/lock" }

    // MARK: - digest

    func testDigestIsStableAndDistinguishesText() {
        let a = ConfigDigest.digest("alpha|3430|user@host|443|\n")
        XCTAssertEqual(a, ConfigDigest.digest("alpha|3430|user@host|443|\n"))
        XCTAssertEqual(a.count, 16)
        XCTAssertNotEqual(a, ConfigDigest.digest("alpha|3431|user@host|443|\n"))
        XCTAssertNotEqual(a, ConfigDigest.digest(""))
    }

    // MARK: - request / ack

    func testRequestRoundTrip() throws {
        let coordinator = ReloadCoordinator(lockDirectory: lockDir)
        let request = ReloadRequest(requestID: "abc-123", digest: ConfigDigest.digest("x"))
        try coordinator.writeRequest(request)
        XCTAssertEqual(coordinator.readRequest(), request)
        XCTAssertNil(ReloadAck.parse(try String(contentsOfFile: coordinator.requestPath,
                                                encoding: .utf8)))
    }

    func testAckRoundTripWithDetailContainingSeparator() throws {
        let coordinator = ReloadCoordinator(lockDirectory: lockDir)
        let ack = ReloadAck(requestID: "abc-123", digest: "0123456789abcdef",
                            outcome: .failed, targetCount: 2, epoch: 1700000000,
                            detail: "第 3 行：a|b")
        try coordinator.writeAck(ack)
        let read = coordinator.readAck()
        XCTAssertEqual(read, ack)
        XCTAssertEqual(read?.detail, "第 3 行：a|b")
    }

    func testAppliedAckHasEmptyDetailByDefault() throws {
        let coordinator = ReloadCoordinator(lockDirectory: lockDir)
        let ack = ReloadAck(requestID: "r1", digest: "d1", outcome: .applied, targetCount: 3)
        try coordinator.writeAck(ack)
        XCTAssertEqual(coordinator.readAck()?.targetCount, 3)
        XCTAssertEqual(coordinator.readAck()?.outcome, .applied)
        XCTAssertEqual(coordinator.readAck()?.detail, "")
    }

    func testMalformedFilesReadAsNil() throws {
        let coordinator = ReloadCoordinator(lockDirectory: lockDir)
        try FileManager.default.createDirectory(atPath: lockDir, withIntermediateDirectories: true)
        try "garbage".write(toFile: coordinator.requestPath, atomically: true, encoding: .utf8)
        XCTAssertNil(coordinator.readRequest())
        try "id|digest|nonsense|1|2|".write(toFile: coordinator.ackPath, atomically: true, encoding: .utf8)
        XCTAssertNil(coordinator.readAck())
    }

    func testClearRemovesBothFiles() throws {
        let coordinator = ReloadCoordinator(lockDirectory: lockDir)
        try coordinator.writeRequest(ReloadRequest(requestID: "r", digest: "d"))
        try coordinator.writeAck(ReloadAck(requestID: "r", digest: "d", outcome: .applied, targetCount: 0))
        coordinator.clear()
        XCTAssertNil(coordinator.readRequest())
        XCTAssertNil(coordinator.readAck())
    }

    // MARK: - daemon owner

    func testOwnerRoundTrip() throws {
        let path = lockDir + "/daemon.owner"
        let owner = DaemonOwner(daemonPID: 4321, appPID: 9876, epoch: 1700000000)
        try DaemonOwner.write(owner, to: path)
        XCTAssertEqual(DaemonOwner.read(path: path), owner)
        DaemonOwner.remove(path: path)
        XCTAssertNil(DaemonOwner.read(path: path))
    }

    func testOwnerParsingRejectsNonsense() {
        XCTAssertNil(DaemonOwner.parse(""))
        XCTAssertNil(DaemonOwner.parse("not-pids"))
        XCTAssertNil(DaemonOwner.parse("-1|0|"))
        XCTAssertEqual(DaemonOwner.parse("42|7\n")?.daemonPID, 42)
        XCTAssertEqual(DaemonOwner.parse("42|7\n")?.epoch, 0)
    }
}

/// Log tailing: initial load, incremental appends, rotation, truncation and the
/// search helper the log window uses.
final class LogTailTests: XCTestCase {
    private var workDir: String!

    override func setUpWithError() throws {
        workDir = NSTemporaryDirectory() + "magpie-logtail-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: workDir)
    }

    private var logPath: String { workDir + "/app.log" }

    func testMissingFileReadsEmpty() {
        let reader = LogTailReader(path: logPath)
        XCTAssertEqual(reader.read(), .empty)
    }

    func testInitialReadThenIncrementalAppend() throws {
        try "one\ntwo\n".write(toFile: logPath, atomically: true, encoding: .utf8)
        let reader = LogTailReader(path: logPath)
        XCTAssertEqual(reader.read().text, "one\ntwo\n")
        XCTAssertFalse(reader.read().didReset)

        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
        try handle.seekToEnd()
        handle.write("three\n".data(using: .utf8)!)
        try handle.close()
        let chunk = reader.read()
        XCTAssertEqual(chunk.text, "three\n")
        XCTAssertFalse(chunk.didReset)
    }

    func testRotationResetsReader() throws {
        try "old-a\nold-b\n".write(toFile: logPath, atomically: true, encoding: .utf8)
        let reader = LogTailReader(path: logPath)
        XCTAssertEqual(reader.read().text, "old-a\nold-b\n")

        // A new file at the same path: different inode, so the reader starts over.
        let rotated = workDir + "/app.log.1"
        try FileManager.default.moveItem(atPath: logPath, toPath: rotated)
        try "new-a\n".write(toFile: logPath, atomically: true, encoding: .utf8)
        let chunk = reader.read()
        XCTAssertTrue(chunk.didReset)
        XCTAssertEqual(chunk.text, "new-a\n")
    }

    func testTruncationInPlaceResetsReader() throws {
        try "aaaaaaaa\ntail\n".write(toFile: logPath, atomically: true, encoding: .utf8)
        let reader = LogTailReader(path: logPath)
        XCTAssertEqual(reader.read().text, "aaaaaaaa\ntail\n")
        try "short\n".write(toFile: logPath, atomically: false, encoding: .utf8)
        let chunk = reader.read()
        XCTAssertTrue(chunk.didReset)
        XCTAssertEqual(chunk.text, "short\n")
    }

    func testLargeFileLoadsTailOnlyAndDropsPartialLine() throws {
        var text = ""
        for index in 0..<2000 { text += "line \(index) ................\n" }
        try text.write(toFile: logPath, atomically: true, encoding: .utf8)

        let reader = LogTailReader(path: logPath, maxInitialBytes: 4096)
        let chunk = reader.read()
        XCTAssertTrue(chunk.didSkipHead)
        XCTAssertTrue(chunk.text.hasPrefix("line "), "首个半行应被丢弃: \(chunk.text.prefix(40))")
        XCTAssertTrue(chunk.text.hasSuffix("line 1999 ................\n"))
        XCTAssertLessThan(chunk.text.count, text.count)
    }

    func testSearchIsCaseInsensitiveAndLimited() {
        let text = "Error: boom\nok\nerror again\nERROR uppercase\n"
        let ranges = LogSearch.ranges(of: "error", in: text)
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(LogSearch.ranges(of: "boom", in: text).count, 1)
        XCTAssertEqual(LogSearch.ranges(of: "   ", in: text), [])
        XCTAssertEqual(LogSearch.ranges(of: "missing", in: text), [])
        XCTAssertEqual(LogSearch.ranges(of: "error", in: text, limit: 2).count, 2)
    }
}
