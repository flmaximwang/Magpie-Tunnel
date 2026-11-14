import XCTest
@testable import MagpieTunnelCore

final class StatusStoreTests: XCTestCase {
    var dir: String!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("magpie-status-\(UUID().uuidString)").path
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(atPath: dir) }
        super.tearDown()
    }

    func testUpRecordSerializesToLegacyFormat() {
        let record = StatusRecord.up(port: 3430, epoch: 1731552000)
        XCTAssertEqual(record.serialized, "up|1731552000|port=3430\n")
    }

    func testDownRecordSerializesToLegacyFormat() {
        let record = StatusRecord.down(reason: "ssh 断开 rc=255", epoch: 1731552001)
        XCTAssertEqual(record.serialized, "down|1731552001|ssh 断开 rc=255\n")
    }

    func testParsesLegacyUpLine() {
        let record = StatusRecord.parse("up|1731552000|port=3430\n")
        XCTAssertEqual(record?.state, "up")
        XCTAssertEqual(record?.epoch, 1731552000)
        XCTAssertEqual(record?.port, 3430)
        XCTAssertEqual(record?.isUp, true)
    }

    func testParsesLegacyDownLines() {
        for line in ["down|1731552000|端口未就绪", "down|1731552000|ssh 启动失败", "down|1731552000|ssh 断开 rc=1"] {
            let record = StatusRecord.parse(line)
            XCTAssertEqual(record?.state, "down")
            XCTAssertEqual(record?.isUp, false)
            XCTAssertNil(record?.port)
            XCTAssertEqual(record?.detail, String(line.split(separator: "|", maxSplits: 2).last.map(String.init) ?? ""))
        }
    }

    func testParseToleratesUnknownStateAndMissingDetail() {
        XCTAssertEqual(StatusRecord.parse("paused|123")?.state, "paused")
        XCTAssertNil(StatusRecord.parse("garbage"))
        XCTAssertNil(StatusRecord.parse(""))
    }

    func testWriteIsAtomicAndReadable() throws {
        let store = try StatusStore(directory: dir)
        store.write(name: "TC2C4G2026", record: .up(port: 3430, epoch: 1731552000))
        let text = try String(contentsOfFile: dir + "/TC2C4G2026", encoding: .utf8)
        XCTAssertEqual(text, "up|1731552000|port=3430\n")
        // No temp leftovers.
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir)
        XCTAssertEqual(entries, ["TC2C4G2026"])
    }

    func testReadAllReturnsParsedRecords() throws {
        let store = try StatusStore(directory: dir)
        store.write(name: "a", record: .up(port: 1, epoch: 10))
        store.write(name: "b", record: .down(reason: "x", epoch: 11))
        let all = store.readAll()
        XCTAssertEqual(all["a"]?.isUp, true)
        XCTAssertEqual(all["b"]?.isUp, false)
    }

    func testRemoveDeletesFile() throws {
        let store = try StatusStore(directory: dir)
        store.write(name: "a", record: .up(port: 1))
        store.remove(name: "a")
        XCTAssertNil(store.read(name: "a"))
    }

    func testOverwriteReplacesPreviousStatus() throws {
        let store = try StatusStore(directory: dir)
        store.write(name: "a", record: .up(port: 1, epoch: 1))
        store.write(name: "a", record: .down(reason: "ssh 断开 rc=1", epoch: 2))
        let text = try String(contentsOfFile: dir + "/a", encoding: .utf8)
        XCTAssertEqual(text, "down|2|ssh 断开 rc=1\n")
    }
}
