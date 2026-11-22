import XCTest
@testable import MagpieTunnelCore

/// Tests for the editable configuration draft: round trips through comments,
/// adding/removing/undoing rows, per-field validation, external-change detection
/// and the "one write" save rule.
final class ConfigDraftTests: XCTestCase {
    private var workDir: String!

    override func setUpWithError() throws {
        workDir = NSTemporaryDirectory() + "magpie-draft-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: workDir)
    }

    private var configPath: String { workDir + "/targets.conf" }

    private let sampleText = """
    # 两台开发机
    alpha|3430|user@host-a|443|deadbeef

    beta|3431|user@host-b|443|

    """

    // MARK: - parsing

    func testCommentsAndBlankLinesArePreservedThroughSave() throws {
        try sampleText.write(toFile: configPath, atomically: true, encoding: .utf8)
        let (draft, _) = try ConfigDraft.load(path: configPath)
        // The trailing newline does not add a line: one comment + one blank.
        XCTAssertEqual(draft.preservedLineCount, 2)
        XCTAssertEqual(draft.targets.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(draft.serialize(), sampleText)
    }

    func testBrokenRowsAreKeptWithReasons() {
        let draft = ConfigDraft.from(text: "ok|3430|user@host|443|\nnot-enough\n")
        XCTAssertEqual(draft.targets.map(\.name), ["ok"])
        XCTAssertEqual(draft.unresolvedBrokenRows.count, 1)
        XCTAssertEqual(draft.unresolvedBrokenRows[0].sourceLine, 2)
        if case .broken(let reason) = draft.unresolvedBrokenRows[0].kind {
            XCTAssertTrue(reason.contains("第 2 行"), reason)
        } else {
            XCTFail("坏行应当是 .broken")
        }
    }

    /// Regression: `components(separatedBy: .newlines)` matched `\r` *and* `\n`,
    /// so a CRLF file produced one phantom blank line per line ending and every
    /// save copied those blanks back.
    func testCRLFConfigRoundTripsWithoutExtraBlankLines() {
        let crlf = "# c1\r\na|3430|u@h|443|\r\n\r\n# c2\r\nb|3431|u@h|443|\r\n"
        let draft = ConfigDraft.from(text: crlf)

        // 2 comments + the one real blank line. The final CRLF is a line
        // terminator, not an empty line — the same rule LF files follow, which
        // is why the draft stores 3 preserved lines here (the "4th line" of the
        // requirement is that terminator, counted below through the empty entry
        // `components(separatedBy:)` produces after the last newline).
        XCTAssertEqual(draft.preservedLineCount, 3)
        XCTAssertEqual(draft.rows.count, 2)
        XCTAssertEqual(draft.rows.map(\.sourceLine), [2, 5], "行号不应被幻影空行推后")
        XCTAssertEqual(draft.targets.map(\.name), ["a", "b"])

        let serialized = draft.serialize()
        XCTAssertEqual(serialized, "# c1\na|3430|u@h|443|\n\n# c2\nb|3431|u@h|443|\n",
                       "CRLF 应转成 LF，且注释/空行不多不少")
        XCTAssertFalse(serialized.contains("\r"), "写出时不再保留 \\r")
        XCTAssertFalse(serialized.contains("\n\n\n"), "不应出现连续空行")
        XCTAssertFalse(serialized.hasSuffix("\n\n"), "结尾不应多出一个空行")

        // Counting the written file the way the bug report does — splitting it
        // on "\n" keeps the empty segment after the final newline — gives 6
        // segments: 2 comments + the blank line + that empty tail (4 non-target
        // segments) and 2 target lines. `preservedLineCount` itself stays 3,
        // because the trailing newline is the file terminator that `serialize()`
        // always adds, exactly as it does for LF files (so the LF baseline does
        // not change).
        let layout = serialized.components(separatedBy: "\n")
        XCTAssertEqual(layout.count, 6, "旧的 .newlines 拆分会在写出时多出 5 个空段")
        XCTAssertEqual(layout.filter { $0.isEmpty }.count, 2,
                       "只有真正的空行和结尾空段两处空条目")
        XCTAssertEqual(layout.filter { $0.hasPrefix("#") }.count, 2)
        XCTAssertEqual(layout.filter { $0.contains("|") }.count, 2)
        XCTAssertEqual(layout.filter { $0.isEmpty || $0.hasPrefix("#") }.count, 4,
                       "4 段注释/空行")

        // Parsing the written text again yields the same draft: the round trip
        // is stable instead of growing the file on every save.
        let reparsed = ConfigDraft.from(text: serialized)
        XCTAssertEqual(reparsed.preservedLineCount, 3)
        XCTAssertEqual(reparsed.rows.count, 2)
        XCTAssertEqual(reparsed.serialize(), serialized)

        // The daemon-facing parser goes through the same splitter.
        let parsed = TargetsParser.parse(crlf)
        XCTAssertEqual(parsed.rawLines, ["# c1", "a|3430|u@h|443|", "",
                                         "# c2", "b|3431|u@h|443|"])
        XCTAssertEqual(parsed.targets.map(\.name), ["a", "b"])
        XCTAssertEqual(parsed.diagnostics, [])
    }

    func testMissingFileLoadsEmptyDraft() throws {
        let (draft, snapshot) = try ConfigDraft.load(path: configPath)
        XCTAssertTrue(draft.rows.isEmpty)
        XCTAssertFalse(snapshot.exists)
    }

    // MARK: - edits

    func testAddUpdateRemoveAndUndo() throws {
        var draft = ConfigDraft.from(text: sampleText)
        let newID = draft.addTarget(TargetConfig(name: "gamma", localPort: 3432,
                                                 sshTarget: "user@host-c", remotePort: 443,
                                                 webKey: "cafe"))
        XCTAssertEqual(draft.targets.map(\.name), ["alpha", "beta", "gamma"])

        draft.update(id: newID, target: TargetConfig(name: "gamma2", localPort: 3433,
                                                     sshTarget: "user@host-c", remotePort: 443,
                                                     webKey: ""))
        XCTAssertEqual(draft.targets.last?.name, "gamma2")

        let removed = draft.remove(id: newID)
        XCTAssertNotNil(removed)
        XCTAssertEqual(draft.targets.map(\.name), ["alpha", "beta"])

        if let removed { draft.undoRemove(removed) }
        XCTAssertEqual(draft.targets.map(\.name), ["alpha", "beta", "gamma2"])
        // Undo restores the row in its original position, above the trailing lines.
        XCTAssertEqual(draft.rows.last?.id, newID)
    }

    func testUpdateRewritesRowKeepingCommentLinesInPlace() {
        var draft = ConfigDraft.from(text: sampleText)
        let alpha = try! XCTUnwrap(draft.rows.first { row in
            if case .target(let t) = row.kind { return t.name == "alpha" }
            return false
        })
        draft.update(id: alpha.id, target: TargetConfig(name: "alpha", localPort: 3440,
                                                        sshTarget: "user@host-a", remotePort: 443,
                                                        webKey: "deadbeef"))
        XCTAssertEqual(draft.serialize(), """
        # 两台开发机
        alpha|3440|user@host-a|443|deadbeef

        beta|3431|user@host-b|443|

        """)
    }

    func testFixedBrokenRowKeepsItsLineNumber() {
        var draft = ConfigDraft.from(text: "# 注释\nkeep|3430|user@host|443|\nbroken|abc|user@host|443|\n")
        let broken = draft.rows.first { if case .broken = $0.kind { return true }; return false }
        XCTAssertEqual(broken?.sourceLine, 3)
        draft.update(id: broken!.id, target: TargetConfig(name: "fixed", localPort: 3440,
                                                         sshTarget: "user@host", remotePort: 443))
        let fixed = draft.rows.first { if case .target(let t) = $0.kind { return t.name == "fixed" }; return false }
        XCTAssertEqual(fixed?.sourceLine, 3, "修好一行不应改变它的位置")
    }

    /// Regression: `sourceLine` used to be assigned when the draft was built and
    /// only new rows counted up from `max(sourceLine) + 1`. Deleting an earlier
    /// line therefore left every later row claiming an old file line, so
    /// `blockingProblems()` pointed at the wrong line of the file that a save
    /// would actually write.
    func testSourceLinesRenumberAfterRemovingAnEarlierRow() {
        var draft = ConfigDraft.from(text: "# 注释\nalpha|3430|u@h|443|\nbeta|3431|u@h|443|\nbad\n")
        XCTAssertEqual(draft.rows.map(\.sourceLine), [2, 3, 4])
        XCTAssertEqual(draft.preservedLineCount, 1)

        let alpha = draft.rows[0]
        XCTAssertNotNil(draft.remove(id: alpha.id))

        // The written file is "# 注释" + beta + bad: 2 and 3, not 3 and 4.
        XCTAssertEqual(draft.rows.map(\.sourceLine), [2, 3], "删除后行号应立刻重排")
        XCTAssertEqual(draft.preservedLineCount, 1, "重排只改编号，不动注释/空行数量")

        let problems = draft.blockingProblems()
        XCTAssertEqual(problems.count, 1)
        XCTAssertEqual(problems[0].row.sourceLine, 3, "坏行在写出的文件里是第 3 行")
        if case .broken(let reason) = problems[0].row.kind {
            XCTAssertTrue(reason.hasPrefix("第 3 行："),
                          "坏行理由里的行号也要跟着重排：\(reason)")
        } else {
            XCTFail("这一行应是坏行")
        }

        // Renumbering is text-neutral and idempotent.
        let before = draft.serialize()
        XCTAssertEqual(before.components(separatedBy: "\n").filter { !$0.isEmpty }.count, 3)
        let second = draft.serialize()
        XCTAssertEqual(second, before, "连续两次 serialize() 必须逐字节一致")
        draft.renumberSourceLines()
        XCTAssertEqual(draft.rows.map(\.sourceLine), [2, 3], "重复重排不应移动行号")
        XCTAssertEqual(draft.serialize(), before, "重复重排不应改变文本")

        // The numbers survive the full round trip through disk.
        let reparsed = ConfigDraft.from(text: before)
        XCTAssertEqual(reparsed.rows.map(\.sourceLine), [2, 3])
        XCTAssertEqual(reparsed.serialize(), before)
    }

    func testNewRowsGetTheLineTheyWillOccupy() {
        var draft = ConfigDraft.from(text: "# 注释\nalpha|3430|u@h|443|\n")
        draft.addTarget(TargetConfig(name: "beta", localPort: 3431, sshTarget: "u@h", remotePort: 443))
        XCTAssertEqual(draft.rows.map(\.sourceLine), [2, 3])
        draft.addTarget(TargetConfig(name: "gamma", localPort: 3432, sshTarget: "u@h", remotePort: 443))
        XCTAssertEqual(draft.rows.map(\.sourceLine), [2, 3, 4])

        // Removing from the middle pulls the last row up one line, and adding
        // again must use the line that is now free.
        XCTAssertNotNil(draft.remove(id: draft.rows[1].id))
        XCTAssertEqual(draft.rows.map(\.sourceLine), [2, 3])
        draft.addTarget(TargetConfig(name: "delta", localPort: 3433, sshTarget: "u@h", remotePort: 443))
        XCTAssertEqual(draft.rows.map(\.sourceLine), [2, 3, 4], "新增行号应等于它在写出的文件中的位置")
    }

    func testFixBrokenRowTurnsItIntoATarget() {
        var draft = ConfigDraft.from(text: "keep|3430|user@host|443|\nbad\n")
        let broken = draft.rows[1]
        var seenNames: Set<String> = ["keep"]
        var seenPorts: [Int: String] = [3430: "keep"]
        let fixed = ConfigDocument.parseRow("good|3432|user@host2|443|", lineNumber: broken.sourceLine,
                                            seenNames: &seenNames, seenPorts: &seenPorts)
        XCTAssertEqual(fixed, .valid(TargetConfig(name: "good", localPort: 3432,
                                                  sshTarget: "user@host2", remotePort: 443,
                                                  webKey: "")))
        draft.update(id: broken.id, target: { if case .valid(let t) = fixed { return t }
            return TargetConfig.builtInDefaults[0] }())
        XCTAssertTrue(draft.unresolvedBrokenRows.isEmpty)
        XCTAssertEqual(draft.targets.map(\.name), ["keep", "good"])
    }

    // MARK: - validation

    func testFieldProblemsCoverEveryField() {
        let target = TargetConfig(name: "", localPort: 0, sshTarget: "", remotePort: 0, webKey: "")
        let problems = ConfigDraft().problems(for: target)
        XCTAssertEqual(problems.name, "名字不能为空")
        XCTAssertEqual(problems.sshTarget, "SSH 目标不能为空")
        XCTAssertEqual(problems.localPort, "本机端口应在 1...65535")
        XCTAssertEqual(problems.remotePort, "远端端口应在 1...65535")
        XCTAssertFalse(problems.isEmpty)
    }

    func testDuplicateNameAndPortAreReportedAgainstOtherRows() {
        let draft = ConfigDraft.from(text: sampleText)
        let clash = TargetConfig(name: "alpha", localPort: 3431, sshTarget: "user@h", remotePort: 443)
        let problems = draft.problems(for: clash)
        XCTAssertEqual(problems.name, "名字 “alpha” 与另一条隧道重复")
        XCTAssertEqual(problems.localPort, "本机端口 3431 已被另一条隧道占用")

        // Ignoring the row it duplicates leaves only the port clash with beta.
        let alphaRow = draft.rows[0]
        XCTAssertEqual(draft.problems(for: clash, ignoring: alphaRow.id).name, nil)

        // A fresh name on alpha's own port is valid once alpha is ignored.
        let replacement = TargetConfig(name: "alpha-2", localPort: 3430,
                                       sshTarget: "user@h", remotePort: 443)
        XCTAssertTrue(draft.problems(for: replacement, ignoring: alphaRow.id).isEmpty)
        XCTAssertEqual(draft.problems(for: replacement).localPort,
                       "本机端口 3430 已被另一条隧道占用")
    }

    func testUnsafeNameAndSpacesInSSH() {
        let problems = ConfigDraft().problems(for: TargetConfig(name: "a/b", localPort: 3430,
                                                                sshTarget: "user name@host",
                                                                remotePort: 443))
        XCTAssertNotNil(problems.name)
        XCTAssertEqual(problems.sshTarget, "SSH 目标不能包含空格")
    }

    func testBlockingProblemsListEveryOffendingRow() {
        let draft = ConfigDraft.from(text: "alpha|3430|user@host|443|\nbroken\n")
        let blocking = draft.blockingProblems()
        XCTAssertEqual(blocking.count, 1)
        XCTAssertEqual(blocking[0].row.sourceLine, 2)
    }

    func testValidDraftHasNoBlockingProblems() {
        XCTAssertTrue(ConfigDraft.from(text: sampleText).blockingProblems().isEmpty)
    }

    // MARK: - save

    func testSavedTextIsExactlySerialized() throws {
        var draft = ConfigDraft.from(text: sampleText)
        draft.addTarget(TargetConfig(name: "gamma", localPort: 3440, sshTarget: "user@host-c",
                                     remotePort: 443, webKey: ""))
        let expected = draft.serialize()
        let snapshot = try ConfigFileSnapshot.write(expected, to: configPath)
        XCTAssertTrue(snapshot.exists)
        XCTAssertEqual(try String(contentsOfFile: configPath, encoding: .utf8), expected)
    }

    func testEmptyDraftSerializesToOneNewline() {
        XCTAssertEqual(ConfigDraft().serialize(), "\n")
    }
}
