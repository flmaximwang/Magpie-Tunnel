import XCTest
@testable import MagpieTunnelCore

final class RotatingFileLoggerTests: XCTestCase {
    var dir: String!
    var logPath: String!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("magpie-logs-\(UUID().uuidString)").path
        logPath = dir + "/magpie-web-tunnel.log"
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(atPath: dir) }
        super.tearDown()
    }

    func testLogLineHasLegacyTimestampFormat() throws {
        let logger = try RotatingFileLogger(filePath: logPath)
        let date = Date(timeIntervalSince1970: 1731552000)
        logger.log("连接测试")
        let text = try String(contentsOfFile: logPath, encoding: .utf8)
        XCTAssertTrue(text.contains("] 连接测试\n"), "got: \(text)")
        // Timestamp function format itself.
        XCTAssertTrue(RotatingFileLogger.timestamp(date: date).matches(#"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"#))
    }

    func testDefaultMaxBytesIsLegacy2MB() {
        XCTAssertEqual(RotatingFileLogger.legacyMaxBytes, 2 * 1024 * 1024)
    }

    func testRotationAtThreshold() throws {
        let logger = try RotatingFileLogger(filePath: logPath, maxBytes: 64)
        for i in 0..<50 {
            logger.log("line \(i) — some padding to fill the file quickly ..........")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: logPath + ".1"), "rotated copy must exist")
        let rotated = try String(contentsOfFile: logPath + ".1", encoding: .utf8)
        XCTAssertFalse(rotated.isEmpty)
        let current = try String(contentsOfFile: logPath, encoding: .utf8)
        let currentSize = try FileManager.default.attributesOfItem(atPath: logPath)[.size] as? Int ?? 0
        XCTAssertLessThanOrEqual(currentSize, 200, "current file should be small again")
    }

    func testRotationReplacesPreviousDotOne() throws {
        let first = try RotatingFileLogger(filePath: logPath, maxBytes: 64)
        for i in 0..<50 { first.log("round one \(i) xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx") }
        let second = try RotatingFileLogger(filePath: logPath, maxBytes: 64)
        for i in 0..<50 { second.log("round two \(i) yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy") }
        let rotated = try String(contentsOfFile: logPath + ".1", encoding: .utf8)
        XCTAssertTrue(rotated.contains("round one") || rotated.contains("round two"))
        // Only the live file and one rotated file ever.
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir).sorted()
        XCTAssertEqual(entries, ["magpie-web-tunnel.log", "magpie-web-tunnel.log.1"])
    }

    func testCreatesParentDirectory() throws {
        let nested = dir + "/sub/dir/tunnel.log"
        _ = try RotatingFileLogger(filePath: nested)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested))
    }

    func testWriteAppendsRawText() throws {
        let logger = try RotatingFileLogger(filePath: logPath)
        logger.write("raw")
        logger.write("text")
        let text = try String(contentsOfFile: logPath, encoding: .utf8)
        XCTAssertEqual(text, "rawtext")
    }
}

private extension String {
    func matches(_ pattern: String) -> Bool {
        range(of: pattern, options: .regularExpression) != nil
    }
}
