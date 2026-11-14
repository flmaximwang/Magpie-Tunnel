import XCTest
@testable import MagpieTunnelCore

final class TargetsParserTests: XCTestCase {
    var sample: String {
        """
        # magpie 隧道目标配置 —— 改这一个文件，隧道守护和菜单栏 App 都跟着变
        # 每行：名字|本机端口|ssh目标|远端端口|web key
        #   key 留空 = 该机 magpie web 每次启动会换 key（菜单栏只显示不带 key 的地址）
        # TC2C4G2026 的 key 固定写在 compose 的 MAGPIE_WEB_KEY 里，所以能永久用同一链接。
        TC2C4G2026|3430|ubuntu@43.142.18.254|3430|3bdf4869eb195854f1f322fee217dc6c

        ZLab4090D|3431|wangfanlin1@100.68.85.3|3430|
        """ + "\n"
    }

    func testParsesLegacyConfigExactly() {
        let parsed = TargetsParser.parse(sample)
        XCTAssertEqual(parsed.targets.count, 2)
        XCTAssertEqual(parsed.diagnostics, [])

        let first = parsed.targets[0]
        XCTAssertEqual(first.name, "TC2C4G2026")
        XCTAssertEqual(first.localPort, 3430)
        XCTAssertEqual(first.sshTarget, "ubuntu@43.142.18.254")
        XCTAssertEqual(first.remotePort, 3430)
        XCTAssertEqual(first.webKey, "3bdf4869eb195854f1f322fee217dc6c")

        let second = parsed.targets[1]
        XCTAssertEqual(second.name, "ZLab4090D")
        XCTAssertEqual(second.webKey, "")
    }

    func testRoundTripPreservesCommentsAndBlankLines() {
        let parsed = TargetsParser.parse(sample)
        let serialized = TargetsParser.serialize(parsed.rawLines)
        XCTAssertEqual(serialized, sample)
    }

    func testFourFieldLineIsValidWithEmptyKey() {
        let parsed = TargetsParser.parse("alpha|20001|user@host|3430\n")
        XCTAssertEqual(parsed.targets, [TargetConfig(name: "alpha", localPort: 20001,
                                                     sshTarget: "user@host", remotePort: 3430, webKey: "")])
        XCTAssertEqual(parsed.diagnostics, [])
    }

    func testConfLineMatchesLegacyFormat() {
        let withKey = TargetConfig.builtInDefaults[0]
        XCTAssertEqual(withKey.confLine, "TC2C4G2026|3430|ubuntu@43.142.18.254|3430|3bdf4869eb195854f1f322fee217dc6c")
        let keyless = TargetConfig.builtInDefaults[1]
        XCTAssertEqual(keyless.confLine, "ZLab4090D|3431|wangfanlin1@100.68.85.3|3430|")
    }

    func testBuiltInDefaultsMatchLegacyDaemon() {
        XCTAssertEqual(TargetConfig.builtInDefaults.count, 2)
        XCTAssertEqual(TargetConfig.builtInDefaults[0].localPort, 3430)
        XCTAssertEqual(TargetConfig.builtInDefaults[1].localPort, 3431)
    }

    func testDuplicateNameRejected() {
        let parsed = TargetsParser.parse("a|20001|h|3430\na|20002|h|3430\n")
        XCTAssertEqual(parsed.targets.map(\.name), ["a"])
        XCTAssertEqual(parsed.targets[0].localPort, 20001)
        XCTAssertEqual(parsed.diagnostics.count, 1)
        XCTAssertTrue(parsed.diagnostics[0].contains("重复"))
    }

    func testDuplicateLocalPortRejected() {
        let parsed = TargetsParser.parse("a|20001|h|3430\nb|20001|h2|3430\n")
        XCTAssertEqual(parsed.targets.map(\.name), ["a"])
        XCTAssertEqual(parsed.diagnostics.count, 1)
        XCTAssertTrue(parsed.diagnostics[0].contains("20001"))
    }

    func testInvalidPortRangeRejected() {
        for bad in ["0", "65536", "-1", "abc", ""] {
            let parsed = TargetsParser.parse("t|\(bad)|h|3430\n")
            XCTAssertTrue(parsed.targets.isEmpty, "port \(bad) should be rejected")
            XCTAssertFalse(parsed.diagnostics.isEmpty, "port \(bad) should produce a diagnostic")
        }
    }

    func testRemotePortValidated() {
        let parsed = TargetsParser.parse("t|20001|h|99999\n")
        XCTAssertTrue(parsed.targets.isEmpty)
        XCTAssertEqual(parsed.diagnostics.count, 1)
    }

    func testTooFewAndTooManyFields() {
        XCTAssertFalse(TargetsParser.parse("only|three|fields\n").diagnostics.isEmpty)
        XCTAssertFalse(TargetsParser.parse("a|1|h|2|k|extra\n").diagnostics.isEmpty)
    }

    func testUnsafeNameRejected() {
        for bad in ["../evil", "a/b", ".hidden", "a\\b", "a:b"] {
            let parsed = TargetsParser.parse("\(bad)|20001|h|3430\n")
            XCTAssertTrue(parsed.targets.isEmpty, "name \(bad) must be rejected")
        }
    }

    func testEmptySSHTargetRejected() {
        let parsed = TargetsParser.parse("t|20001||3430\n")
        XCTAssertTrue(parsed.targets.isEmpty)
        XCTAssertEqual(parsed.diagnostics.count, 1)
    }

    func testEmptyFileYieldsZeroTargets() {
        let parsed = TargetsParser.parse("")
        XCTAssertEqual(parsed.targets, [])
        XCTAssertEqual(parsed.diagnostics, [])
    }

    func testCommentOnlyFileYieldsZeroTargets() {
        let parsed = TargetsParser.parse("# 只注释\n\n# 另一条\n")
        XCTAssertEqual(parsed.targets, [])
    }

    func testCRLFAndMissingTrailingNewlineTolerated() {
        let parsed = TargetsParser.parse("a|20001|h|3430|key\r\nb|20002|h|3430|")
        XCTAssertEqual(parsed.targets.map(\.name), ["a", "b"])
        XCTAssertEqual(parsed.targets[0].webKey, "key")
        XCTAssertEqual(parsed.targets[1].webKey, "")
        XCTAssertEqual(parsed.diagnostics, [])
    }

    func testParseFileFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("magpie-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("targets.conf").path
        try sample.write(toFile: path, atomically: true, encoding: .utf8)
        let parsed = try TargetsParser.parseFile(at: path)
        XCTAssertEqual(parsed.targets.count, 2)
    }
}
