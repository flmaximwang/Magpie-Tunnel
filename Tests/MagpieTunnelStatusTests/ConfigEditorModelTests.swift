import XCTest
@testable import MagpieTunnelCore
@testable import MagpieTunnelStatus

/// Tests for the configuration window's draft/validation/save model, with no
/// AppKit and no real support directory: every file used here lives under a
/// per-run temporary directory.
///
/// The behaviours locked down here are the ones the config-window spec calls
/// for: one write for all changes, comments and blank lines preserved, a broken
/// line blocks the save and is shown with its line number, an external edit is
/// never overwritten silently, deleting every tunnel writes an empty config
/// (not the built-in defaults), and a failed write keeps the draft intact.
final class ConfigEditorModelTests: XCTestCase {
    private var workDir: String!

    override func setUpWithError() throws {
        workDir = NSTemporaryDirectory() + "magpie-editor-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: workDir)
    }

    private var configPath: String { workDir + "/targets.conf" }

    /// comment(1), alpha(2), blank(3), beta(4)
    private let sampleText = "# 两台开发机\nalpha|3430|user@host-a|443|deadbeef\n\nbeta|3431|user@host-b|443|\n"

    /// comment(1), alpha(2), beta(3), gamma(4)
    private let threeText = "# 三台开发机\nalpha|3430|user@host-a|443|deadbeef\nbeta|3431|user@host-b|443|\ngamma|3432|user@host-c|443|\n"

    /// comment(1), alpha(2), blank(3), comment(4), beta(5), blank(6)
    private let commentsText = "# 注释一\nalpha|3430|user@host-a|443|deadbeef\n\n# 注释二\nbeta|3431|user@host-b|443|\n\n"

    // MARK: - helpers

    @discardableResult
    private func makeModel(_ text: String, at path: String? = nil) throws -> ConfigEditorModel {
        let target = path ?? configPath
        try text.write(toFile: target, atomically: false, encoding: .utf8)
        return ConfigEditorModel(path: target)
    }

    private func writeFile(_ text: String, to path: String) throws {
        try text.write(toFile: path, atomically: false, encoding: .utf8)
    }

    private func diskText(at path: String? = nil) throws -> String {
        try String(contentsOfFile: path ?? configPath, encoding: .utf8)
    }

    private func targetID(_ name: String, in model: ConfigEditorModel) throws -> UUID {
        try XCTUnwrap(model.rows.first { !$0.isBroken && $0.title == name }?.id,
                       "配置里应有一行名为 \(name) 的隧道")
    }

    private func form(named name: String = "alpha",
                      localPort: String = "3430",
                      sshTarget: String = "user@host-a",
                      remotePort: String = "443",
                      webKey: String = "deadbeef") -> TunnelForm {
        TunnelForm(name: name, localPort: localPort, sshTarget: sshTarget,
                   remotePort: remotePort, webKey: webKey)
    }

    // MARK: - loading

    func testLoadBuildsRowsAndSkipsCommentsAndBlankLines() throws {
        let model = try makeModel(sampleText)

        XCTAssertEqual(model.loadState, .loaded, "合法配置应加载成功")
        XCTAssertEqual(model.draft.rows.count, 2, "注释和空行不应变成隧道行")
        XCTAssertEqual(model.draft.preservedLineCount, 2, "1 条注释 + 1 个空行应原样保留")
        XCTAssertEqual(model.rows.map(\.lineNumber), [2, 4], "行号应是文件中的 1 基行号")
        XCTAssertEqual(model.rows.map(\.title), ["alpha", "beta"], "列表标题应是隧道名")
        XCTAssertEqual(model.rows.map(\.subtitle), ["127.0.0.1:3430", "127.0.0.1:3431"],
                       "副标题应是本机监听地址")
        XCTAssertEqual(model.rows.map(\.isBroken), [false, false], "合法行不应是坏行")

        let alphaID = try targetID("alpha", in: model)
        XCTAssertEqual(model.form(for: alphaID),
                       TunnelForm(name: "alpha", localPort: "3430", sshTarget: "user@host-a",
                                  remotePort: "443", webKey: "deadbeef"),
                       "form(for:) 应读回五个字段")

        XCTAssertEqual(model.draft.targets.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(ConfigDraft.from(text: sampleText).rows.count, 2,
                       "from(text:) 同样只把目标行算作可编辑行")
        XCTAssertFalse(model.hasUnsavedChanges(), "刚加载的模型不应有未保存改动")
        XCTAssertTrue(model.snapshot.exists, "已存在的配置文件快照应标记 exists")
        XCTAssertEqual(model.snapshot.text, sampleText, "快照应保存原始文本")
    }

    func testMissingFileStartsWithEmptyDraft() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath),
                       "临时目录里不应已有配置文件")

        let model = ConfigEditorModel(path: configPath)
        XCTAssertEqual(model.loadState, .loaded, "文件不存在不应算作读取失败")
        XCTAssertTrue(model.rows.isEmpty, "缺失配置应从零条隧道开始")
        XCTAssertFalse(model.snapshot.exists, "缺失文件的快照应标记不存在")
        XCTAssertFalse(model.hasUnsavedChanges())

        let id = model.addTunnel()
        XCTAssertEqual(model.form(for: id)?.localPort, "3430", "空配置新增时从 3430 开始找端口")
    }

    // MARK: - broken rows

    func testBrokenLineVariantsAreReportedAndBlockSave() throws {
        let base = "# 注释\nalpha|3430|user@host-a|443|\n"
        let cases: [(bad: String, fragment: String)] = [
            ("broken|3430|user@host-b", "字段数 3"),
            ("bad-port|abc|user@host-b|443|", "本机端口"),
            ("range-port|70000|user@host-b|443|", "不合法"),
            ("alpha|3431|user@host-b|443|", "重复"),
            ("clash|3430|user@host-b|443|", "冲突"),
        ]

        for (index, item) in cases.enumerated() {
            let path = workDir + "/variant-\(index).conf"
            let text = base + item.bad + "\n"
            try writeFile(text, to: path)
            let model = ConfigEditorModel(path: path)

            XCTAssertEqual(model.rows.count, 2, "坏行 “\(item.bad)” 仍应出现在列表里")
            XCTAssertTrue(model.rows[1].isBroken, "坏行 “\(item.bad)” 应标记为 isBroken")
            XCTAssertEqual(model.rows[1].lineNumber, 3, "坏行行号应为 3")

            let brokenID = model.rows[1].id
            XCTAssertEqual(model.brokenText(for: brokenID), item.bad,
                           "brokenText(for:) 应返回该行原始文本")
            XCTAssertNil(model.form(for: brokenID), "坏行不应有可编辑表单")

            let blocking = model.draft.blockingProblems()
            XCTAssertEqual(blocking.count, 1, "坏行 “\(item.bad)” 应只产生一条阻塞问题")
            XCTAssertEqual(blocking[0].row.sourceLine, 3)
            XCTAssertTrue(blocking[0].message.hasPrefix("第 3 行："),
                          "阻塞信息应以“第 3 行：”开头，实际 \(blocking[0].message)")
            XCTAssertTrue(blocking[0].message.contains(item.fragment),
                          "阻塞信息应包含“\(item.fragment)”，实际 \(blocking[0].message)")

            let result = model.save()
            switch result {
            case .blocked(let problems):
                XCTAssertEqual(problems.count, 1, "坏行 “\(item.bad)” 应只阻塞一条")
                XCTAssertEqual(problems[0].line, 3, "SaveProblem 应带上行号")
                XCTAssertEqual(problems[0].message, blocking[0].message,
                               "SaveProblem 的 message 应原样透传阻塞信息")
                XCTAssertTrue(problems[0].message.contains("请修正或删除这一行"),
                              "行级问题应提示修正或删除")
            default:
                XCTFail("坏行 “\(item.bad)” 时保存应返回 .blocked，实际 \(result)")
                continue
            }
            XCTAssertEqual(try diskText(at: path), text, "被阻止的保存不应改动文件")
        }
    }

    func testRepairBrokenLineReplacesRawTextInPlace() throws {
        let text = "# 注释\nalpha|3430|user@host-a|443|\nnot-enough\ngamma|3432|user@host-c|443|\n"
        let model = try makeModel(text)
        let brokenID = model.rows[1].id
        XCTAssertTrue(model.rows[1].isBroken, "第 3 行应是坏行")
        let brokenLineNumber = model.rows[1].lineNumber

        XCTAssertFalse(model.repairBroken(id: brokenID, text: ""), "空文本不应被当作修复")
        XCTAssertFalse(model.repairBroken(id: brokenID, text: "# 注释"), "注释文本不应被当作修复")
        XCTAssertTrue(model.rows[1].isBroken, "被拒绝的修复不应改变行状态")

        XCTAssertTrue(model.repairBroken(id: brokenID,
                                         text: "beta|3431|user@host-b|443|"),
                      "合法文本应修复该行")
        XCTAssertFalse(model.rows[1].isBroken, "修复后不再是坏行")
        XCTAssertEqual(model.rows[1].title, "beta", "修复后应使用新名字")
        XCTAssertEqual(model.rows[1].lineNumber, brokenLineNumber, "修复不应改变行号")
        XCTAssertEqual(model.rows[1].subtitle, "127.0.0.1:3431")
        XCTAssertNil(model.brokenText(for: brokenID), "修复后不应再返回坏行原文")
        XCTAssertTrue(model.hasUnsavedChanges(), "修复应算未保存改动")
        XCTAssertTrue(model.draft.blockingProblems().isEmpty, "修复后不应再有阻塞问题")

        let result = model.save()
        guard case .written(let written) = result else {
            XCTFail("修复后保存应成功，实际 \(result)")
            return
        }
        XCTAssertEqual(written, "# 注释\nalpha|3430|user@host-a|443|\n"
            + "beta|3431|user@host-b|443|\ngamma|3432|user@host-c|443|\n",
            "修复行应在原位置写入合法内容")
        XCTAssertEqual(try diskText(), written)

        // Invalid replacement keeps the row broken but updates its raw text.
        let another = try makeModel("bad-line\n", at: workDir + "/another.conf")
        let id = another.rows[0].id
        XCTAssertTrue(another.repairBroken(id: id, text: "still|bad"))
        XCTAssertTrue(another.rows[0].isBroken, "仍然不合法的修复应保持坏行")
        XCTAssertEqual(another.brokenText(for: id), "still|bad", "坏行应保留用户输入的新文本")
        switch another.save() {
        case .blocked(let problems):
            XCTAssertEqual(problems.count, 1)
            XCTAssertEqual(problems[0].line, 1)
        default:
            XCTFail("仍有坏行时保存应被阻止")
        }
    }

    // MARK: - field validation

    func testFieldProblemsCoverEveryFormField() throws {
        let model = try makeModel(sampleText)
        let alphaID = try targetID("alpha", in: model)

        let emptyName = model.problems(for: alphaID, form: form(named: ""))
        XCTAssertEqual(emptyName.name, "名字不能为空", "空名称应报错")

        let emptyPort = model.problems(for: alphaID, form: form(localPort: ""))
        XCTAssertNotNil(emptyPort.localPort, "空本机端口应报错")

        let textPort = model.problems(for: alphaID, form: form(localPort: "abc"))
        XCTAssertNotNil(textPort.localPort, "非数字本机端口应报错")

        let bigPort = model.problems(for: alphaID, form: form(localPort: "70000"))
        XCTAssertEqual(bigPort.localPort, "本机端口应在 1...65535", "越界本机端口应报错")

        let duplicateName = model.problems(for: alphaID,
                                           form: form(named: "beta", localPort: "3430"))
        XCTAssertEqual(duplicateName.name, "名字 “beta” 与另一条隧道重复",
                       "重复名字应报错")

        let duplicatePort = model.problems(for: alphaID,
                                           form: form(named: "alpha", localPort: "3431"))
        XCTAssertEqual(duplicatePort.localPort, "本机端口 3431 已被另一条隧道占用",
                       "重复本机端口应报错")

        let emptySSH = model.problems(for: alphaID, form: form(sshTarget: ""))
        XCTAssertEqual(emptySSH.sshTarget, "SSH 目标不能为空", "空 SSH 目标应报错")

        let spacedSSH = model.problems(for: alphaID, form: form(sshTarget: "user name@host"))
        XCTAssertEqual(spacedSSH.sshTarget, "SSH 目标不能包含空格",
                       "含空格的 SSH 目标应报错")

        let textRemote = model.problems(for: alphaID, form: form(remotePort: "abc"))
        XCTAssertNotNil(textRemote.remotePort, "非数字远端端口应报错")

        let valid = model.problems(for: alphaID, form: form())
        XCTAssertTrue(valid.isEmpty, "合法表单不应有字段问题")
        XCTAssertNil(valid.name)
        XCTAssertNil(valid.localPort)
        XCTAssertNil(valid.sshTarget)
        XCTAssertNil(valid.remotePort)
    }

    // MARK: - save round trip

    func testSaveRoundTripsSerializedTextAndPreservesCommentsAndBlanks() throws {
        let model = try makeModel(commentsText)
        XCTAssertEqual(model.draft.preservedLineCount, 4, "2 条注释 + 2 个空行应被保留")

        let betaID = try targetID("beta", in: model)
        XCTAssertTrue(model.apply(form(named: "beta", localPort: "3431",
                                       sshTarget: "user@host-b", remotePort: "8443",
                                       webKey: ""), to: betaID),
                      "修改远端端口应被接受")
        XCTAssertTrue(model.hasUnsavedChanges(), "修改后应有未保存改动")

        let serialized = model.draft.serialize()
        let result = model.save()
        guard case .written(let text) = result else {
            XCTFail("合法草稿保存应成功，实际 \(result)")
            return
        }
        XCTAssertEqual(text, serialized, "save() 返回的文本应等于 serialize()")
        XCTAssertEqual(try diskText(), serialized, "磁盘内容应等于 serialize()")

        let expected = "# 注释一\nalpha|3430|user@host-a|443|deadbeef\n"
            + "\n# 注释二\nbeta|3431|user@host-b|8443|\n\n"
        XCTAssertEqual(text, expected, "注释与空行应留在原位，只有目标行内容变化")
        XCTAssertEqual(model.draft.preservedLineCount, 4, "保存不应丢掉任何注释或空行")

        // Re-parse the written file: still 2 comments + 2 blanks, rows at the
        // same lines 2 and 5 (nothing merged or moved).
        let reparsed = ConfigDraft.from(text: try diskText())
        XCTAssertEqual(reparsed.preservedLineCount, 4, "重新解析后注释与空行数量不变")
        XCTAssertEqual(reparsed.rows.map(\.sourceLine), [2, 5], "目标行仍在第 2、5 行")
        XCTAssertEqual(reparsed.targets.map(\.name), ["alpha", "beta"])
    }

    // MARK: - adding

    func testAddTunnelReturnsReadableIDAndUsesFreePort() throws {
        let model = try makeModel("alpha|3430|user@host-a|443|\nbeta|3432|user@host-b|443|\n")
        XCTAssertEqual(model.rows.count, 2)

        let firstID = model.addTunnel()
        XCTAssertTrue(model.hasUnsavedChanges(), "新增后应显示未保存改动")
        XCTAssertEqual(model.rows.count, 3, "新增应追加一行")
        XCTAssertEqual(model.rows.last?.id, firstID, "新增应追加在列表末尾")

        let first = try XCTUnwrap(model.form(for: firstID),
                                  "addTunnel 返回的 UUID 应能通过 form(for:) 读回")
        XCTAssertEqual(first.localPort, "3431", "3430 被占用时应跳过它，用 3431")
        XCTAssertEqual(first.remotePort, "443", "新增行远端端口默认 443")
        XCTAssertEqual(first.name, "", "新增行名称留空待填")
        XCTAssertEqual(first.sshTarget, "")
        XCTAssertEqual(model.rows.last?.lineNumber, 3, "新行行号应接在最后一行之后")

        let secondID = model.addTunnel()
        let second = try XCTUnwrap(model.form(for: secondID))
        XCTAssertEqual(second.localPort, "3433", "3430...3432 都占用后应使用 3433")
        XCTAssertEqual(model.rows.last?.lineNumber, 4)

        let usedPorts = Set(model.rows.compactMap { model.form(for: $0.id)?.localPortValue })
        XCTAssertEqual(usedPorts.count, model.rows.count,
                       "新增的默认本机端口不应与任何现有行冲突")
    }

    // MARK: - editing

    func testApplyRewritesOnlyEditedRow() throws {
        let model = try makeModel(threeText)
        let betaID = try targetID("beta", in: model)
        let changed = form(named: "beta", localPort: "3431", sshTarget: "user@host-b",
                           remotePort: "8443", webKey: "")

        XCTAssertTrue(model.apply(changed, to: betaID), "修改远端端口应被接受")
        XCTAssertTrue(model.hasUnsavedChanges(), "修改后应有未保存改动")
        XCTAssertEqual(model.form(for: betaID)?.remotePort, "8443", "草稿应记住新端口")
        XCTAssertFalse(model.apply(changed, to: betaID), "内容没变时 apply 应返回 false")

        let result = model.save()
        guard case .written(let text) = result else {
            XCTFail("修改后的合法草稿应保存成功，实际 \(result)")
            return
        }
        let onDisk = try diskText()
        let expected = "# 三台开发机\nalpha|3430|user@host-a|443|deadbeef\n"
            + "beta|3431|user@host-b|8443|\ngamma|3432|user@host-c|443|\n"
        XCTAssertEqual(onDisk, expected, "只应改写被修改的行，未改的行原样保留")
        XCTAssertEqual(text, onDisk, "save() 返回的文本应等于磁盘内容")
        XCTAssertFalse(model.hasUnsavedChanges(), "保存成功后不应再有未保存改动")
        XCTAssertEqual(model.rows.map(\.lineNumber), [2, 3, 4], "行号与顺序不应变化")
    }

    // MARK: - deleting

    func testDeleteAndUndoRestoreOriginalIndex() throws {
        let model = try makeModel(threeText)
        let betaID = try targetID("beta", in: model)
        let gammaID = try targetID("gamma", in: model)
        let originalIndex = try XCTUnwrap(model.rows.firstIndex { $0.id == betaID })

        XCTAssertFalse(model.canUndoDelete(), "删除前不应能撤销")
        XCTAssertTrue(model.delete(id: betaID), "删除应成功")
        XCTAssertEqual(model.rows.map(\.title), ["alpha", "gamma"], "删除后该行应从列表消失")
        XCTAssertEqual(model.pendingDeletionNames, ["beta"], "待删除名单应记下名字")
        XCTAssertTrue(model.canUndoDelete(), "删除后应能撤销")
        XCTAssertTrue(model.hasUnsavedChanges(), "删除后应有未保存改动")

        model.undoDelete()
        XCTAssertEqual(model.rows.map(\.title), ["alpha", "beta", "gamma"], "撤销应恢复该行")
        let restoredIndex = try XCTUnwrap(model.rows.firstIndex { $0.id == betaID })
        XCTAssertEqual(restoredIndex, originalIndex, "撤销应恢复到原位置")
        XCTAssertTrue(model.pendingDeletionNames.isEmpty, "撤销后待删除名单应清空")
        XCTAssertFalse(model.canUndoDelete(), "撤销后不应再能撤销")
        XCTAssertTrue(model.hasUnsavedChanges(), "撤销删除仍是未保存改动")

        // A second deletion replaces the single undo slot: undoing it restores
        // only the most recent row, and keeps the earlier pending deletion.
        XCTAssertTrue(model.delete(id: betaID))
        XCTAssertTrue(model.delete(id: gammaID))
        XCTAssertEqual(model.pendingDeletionNames, ["beta", "gamma"])
        model.undoDelete()
        XCTAssertEqual(model.rows.map(\.title), ["alpha", "gamma"], "只应恢复最近删除的行")
        XCTAssertEqual(try XCTUnwrap(model.rows.firstIndex { $0.id == gammaID }), 1,
                       "gamma 应回原位")
        XCTAssertEqual(model.pendingDeletionNames, ["beta"], "beta 仍在待删除名单里")
        XCTAssertFalse(model.canUndoDelete(), "撤销一次后不应再能撤销")
        let countAfterUndo = model.rows.count
        model.undoDelete()
        XCTAssertEqual(model.rows.count, countAfterUndo, "没有可撤销的行时再次撤销不应改动列表")
        XCTAssertEqual(model.pendingDeletionNames, ["beta"], "无撤销可用时待删除名单不应变化")
    }

    /// Regression: undoing a broken line's deletion used to call
    /// `pendingDeletionNames.removeLast()` unconditionally, so it popped some
    /// *other* tunnel's pending deletion and the save confirmation stopped
    /// listing it — while that tunnel was still gone.
    func testUndoAfterDeletingBrokenRowKeepsOtherPendingName() throws {
        let text = "# 注释\nalpha|3430|user@host-a|443|\nbeta|3431|user@host-b|443|\nbroken-line\n"
        let model = try makeModel(text)
        let betaID = try targetID("beta", in: model)
        let brokenRow = try XCTUnwrap(model.rows.first { $0.isBroken }, "应有一行坏行")
        XCTAssertEqual(brokenRow.lineNumber, 4)

        // Delete a target, then the broken line: the single undo slot now holds
        // the broken row, which never put a name on the list.
        XCTAssertTrue(model.delete(id: betaID))
        XCTAssertEqual(model.pendingDeletionNames, ["beta"], "删 beta 应记下名字")
        XCTAssertTrue(model.delete(id: brokenRow.id))
        XCTAssertEqual(model.pendingDeletionNames, ["beta"], "删坏行不应记名字")
        XCTAssertEqual(model.rows.map(\.title), ["alpha"], "坏行应从列表消失")

        model.undoDelete()
        XCTAssertEqual(model.rows.map(\.title), ["alpha", "第 3 行"], "撤销应恢复坏行")
        XCTAssertEqual(model.pendingDeletionNames, ["beta"],
                       "撤销坏行不得动 beta 的待删除记录")

        // The save confirmation still has beta to warn about, and saving is
        // blocked by the restored broken row instead of silently dropping beta.
        let blocked = model.save()
        guard case .blocked(let problems) = blocked else {
            XCTFail("坏行恢复后保存应被拦住，实际 \(blocked)")
            return
        }
        XCTAssertEqual(problems.map(\.line), [3], "坏行在写出的文件里是第 3 行")
        XCTAssertEqual(try diskText(), text, "被拦住的保存不得写入磁盘")

        // Undoing a *target* deletion still takes its name back off the list.
        let alphaID = try targetID("alpha", in: model)
        XCTAssertTrue(model.delete(id: alphaID))
        XCTAssertEqual(model.pendingDeletionNames, ["beta", "alpha"])
        model.undoDelete()
        XCTAssertEqual(model.pendingDeletionNames, ["beta"],
                       "撤销删除目标应撤回它的待删除记录")
        XCTAssertEqual(model.rows.map(\.title), ["alpha", "第 3 行"], "alpha 应回到原位")

        // Removing the broken line lets a save through, and the deletion list
        // survives until that save — beta is still listed as going away.
        let brokenRowAgain = try XCTUnwrap(model.rows.first { $0.isBroken })
        XCTAssertTrue(model.delete(id: brokenRowAgain.id))
        XCTAssertEqual(model.pendingDeletionNames, ["beta"], "删坏行仍不应动待删除名单")
        let result = model.save()
        guard case .written(let written) = result else {
            XCTFail("删掉坏行后应能保存，实际 \(result)")
            return
        }
        XCTAssertEqual(written, "# 注释\nalpha|3430|user@host-a|443|\n",
                       "beta 是真正被删掉的，保存应把它写掉")
        XCTAssertEqual(model.pendingDeletionNames, [], "保存成功后名单清空")
    }

    /// Regression: `sourceLine` went stale after a deletion, so the "第 N 行"
    /// told to the user did not match the file a save would write.
    func testLineNumbersFollowWrittenOrderAfterDeletion() throws {
        let text = "# 注释\nalpha|3430|user@host-a|443|\nbeta|3431|user@host-b|443|\nbad\n"
        let model = try makeModel(text)
        XCTAssertEqual(model.rows.map(\.lineNumber), [2, 3, 4])

        let alphaID = try targetID("alpha", in: model)
        XCTAssertTrue(model.delete(id: alphaID))
        XCTAssertEqual(model.rows.map(\.lineNumber), [2, 3],
                       "删掉第 2 行后，剩下的行号应各减一")

        let blocked = model.save()
        guard case .blocked(let problems) = blocked else {
            XCTFail("坏行未处理时保存应被拦住，实际 \(blocked)")
            return
        }
        XCTAssertEqual(problems.count, 1)
        XCTAssertEqual(problems[0].line, 3, "坏行在写出的文件里是第 3 行，不是第 4 行")
        XCTAssertTrue(problems[0].message.hasPrefix("第 3 行："),
                      "坏行理由里的行号也要跟着重算：\(problems[0].message)")

        // Adding a row now reuses the freed line rather than max+1 of the old
        // numbers, and never collides with a row that already sits there.
        let addedID = model.addTunnel()
        XCTAssertTrue(model.apply(form(named: "delta", localPort: "3434",
                                       sshTarget: "user@host-d", remotePort: "443",
                                       webKey: ""), to: addedID))
        XCTAssertEqual(model.rows.map(\.lineNumber), [2, 3, 4])

        // Delete alpha's successor and save: the remaining rows must be
        // numbered exactly as they appear on disk.
        let betaID = try targetID("beta", in: model)
        XCTAssertTrue(model.delete(id: betaID))
        let brokenRow = try XCTUnwrap(model.rows.first { $0.isBroken })
        XCTAssertTrue(model.delete(id: brokenRow.id))
        let result = model.save()
        guard case .written(let written) = result else {
            XCTFail("删掉坏行后应能保存，实际 \(result)")
            return
        }
        XCTAssertEqual(written, "# 注释\ndelta|3434|user@host-d|443|\n")
        XCTAssertEqual(model.rows.map(\.lineNumber), [2])
        let reparsed = ConfigDraft.from(text: try diskText())
        XCTAssertEqual(reparsed.rows.map(\.sourceLine), model.rows.map(\.lineNumber),
                       "草稿行号应与重新读出的文件行号一致")
    }

    /// Regression: an existing file whose bytes cannot be decoded looked like a
    /// *missing* file to the snapshot, so saving silently replaced it.
    func testUnreadableExistingFileRefusesToSave() throws {
        // Invalid UTF-8: the file exists and stat succeeds, but decoding fails.
        let garbage = Data([0x23, 0x20, 0x6F, 0x6B, 0xFF, 0xFE, 0x00])
        try garbage.write(to: URL(fileURLWithPath: configPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: configPath))

        let model = ConfigEditorModel(path: configPath)
        XCTAssertEqual(model.loadState, .unreadable("文件无法读取（可能是权限或编码问题）"))
        XCTAssertTrue(model.isExistingButUnreadable,
                      "存在但读不出来的常规文件应被标记，否则保存会覆盖它")
        XCTAssertFalse(model.snapshot.exists, "读不出来时快照看起来像文件不存在")
        XCTAssertFalse(model.snapshot.isStale(), "快照不陈旧，所以只有专用标记能拦住保存")
        XCTAssertTrue(model.rows.isEmpty, "读不出来时从空草稿开始")

        // The user adds a tunnel in the empty list: the save must refuse rather
        // than replace the file the user never saw.
        let id = model.addTunnel()
        XCTAssertTrue(model.apply(form(named: "alpha", localPort: "3430",
                                       sshTarget: "user@host-a", remotePort: "443",
                                       webKey: ""), to: id))
        let result = model.save()
        guard case .failed(let message) = result else {
            XCTFail("存在但不可读的文件上保存应失败，实际 \(result)")
            return
        }
        XCTAssertTrue(message.contains("配置文件存在但无法读取"), "实际：\(message)")
        XCTAssertTrue(message.contains("没有保存"), "实际：\(message)")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: configPath)), garbage,
                       "原始字节必须原样保留，不能被草稿覆盖")
        XCTAssertTrue(model.hasUnsavedChanges(), "被拒绝的保存不应清掉未保存状态")
        XCTAssertEqual(model.rows.count, 1, "被拒绝的保存不应丢掉草稿")

        // Once the file becomes readable again, a reload clears the flag and
        // saving works normally.
        try writeFile("original|3430|user@host-o|443|\n", to: configPath)
        model.reload()
        XCTAssertFalse(model.isExistingButUnreadable, "文件恢复可读后应解除拦截")
        let reloaded = model.save()
        guard case .written(let written) = reloaded else {
            XCTFail("恢复可读后保存应成功，实际 \(reloaded)")
            return
        }
        XCTAssertEqual(written, "original|3430|user@host-o|443|\n")
        XCTAssertEqual(try diskText(), written)
    }

    /// The CRLF round trip through the editor, not just the draft: writing must
    /// not duplicate comments/blank lines and must not grow an extra blank on
    /// every save.
    func testCRLFConfigSavedFromEditorHasNoPhantomBlanks() throws {
        let crlf = "# c1\r\nalpha|3430|u@h|443|\r\n\r\n# c2\r\nbeta|3431|u@h|443|\r\n"
        let model = try makeModel(crlf)
        XCTAssertEqual(model.rows.map(\.lineNumber), [2, 5], "行号不应被幻影空行推后")
        XCTAssertEqual(model.draft.preservedLineCount, 3, "2 条注释 + 1 个空行")

        let result = model.save()
        guard case .written(let written) = result else {
            XCTFail("CRLF 配置应能保存，实际 \(result)")
            return
        }
        XCTAssertEqual(written, "# c1\nalpha|3430|u@h|443|\n\n# c2\nbeta|3431|u@h|443|\n")
        XCTAssertEqual(try diskText(), written, "写出的文件改用 LF，且不多出空行")
        XCTAssertFalse(written.contains("\n\n\n"), "不应出现连续空行")

        let reloaded = ConfigEditorModel(path: configPath)
        XCTAssertEqual(reloaded.rows.map(\.title), ["alpha", "beta"])
        XCTAssertEqual(reloaded.draft.preservedLineCount, 3,
                       "重新载入后注释/空行数量不变（保存不会让文件越来越长）")
        let again = reloaded.save()
        guard case .written(let second) = again else {
            XCTFail("重新载入后应能再保存，实际 \(again)")
            return
        }
        XCTAssertEqual(second, written, "再次保存必须字节一致")
    }

    func testSavingAfterDeletingAllTunnelsWritesEmptyConfig() throws {
        let model = try makeModel("alpha|3430|user@host-a|443|\nbeta|3431|user@host-b|443|\n")
        for row in model.rows { _ = model.delete(id: row.id) }
        XCTAssertTrue(model.rows.isEmpty, "删光后草稿应为空")
        XCTAssertEqual(model.pendingDeletionNames, ["alpha", "beta"])

        let result = model.save()
        guard case .written(let text) = result else {
            XCTFail("空草稿应能保存，实际 \(result)")
            return
        }
        XCTAssertEqual(text, "\n", "零目标的配置序列化为单个换行")
        let onDisk = try diskText()
        XCTAssertEqual(onDisk, "\n", "磁盘上应是空配置，而不是内置默认目标")
        XCTAssertFalse(onDisk.contains("TC2C4G2026"), "不得回退到内置默认目标")
        XCTAssertFalse(onDisk.contains("|"), "不得写入任何 target 行")
        XCTAssertFalse(model.hasUnsavedChanges())
        XCTAssertEqual(model.pendingDeletionNames, [])

        let reloaded = ConfigEditorModel(path: configPath)
        XCTAssertTrue(reloaded.rows.isEmpty, "保存后重新加载应为 0 条隧道")
        XCTAssertEqual(reloaded.draft.targets.count, 0, "重新加载后目标数应为 0")

        // A config with a comment keeps the comment while all targets go away.
        let commentModel = try makeModel("# 保留注释\nalpha|3430|user@host-a|443|\nbeta|3431|user@host-b|443|\n")
        for row in commentModel.rows { _ = commentModel.delete(id: row.id) }
        let commentResult = commentModel.save()
        guard case .written(let commentText) = commentResult else {
            XCTFail("带注释的空草稿应能保存，实际 \(commentResult)")
            return
        }
        XCTAssertEqual(commentText, "# 保留注释\n", "注释应保留，目标行应全部消失")
        XCTAssertEqual(try diskText(), "# 保留注释\n")
    }

    // MARK: - external edits

    func testExternalEditIsNotOverwrittenAndReloadAdoptsIt() throws {
        let original = "alpha|3430|user@host-a|443|\nbeta|3431|user@host-b|443|\n"
        let model = try makeModel(original)
        let alphaID = try targetID("alpha", in: model)
        XCTAssertTrue(model.apply(form(named: "alpha", localPort: "3430",
                                       sshTarget: "user@host-a", remotePort: "8443",
                                       webKey: "deadbeef"), to: alphaID))
        XCTAssertTrue(model.hasUnsavedChanges())

        // Simulate an editor saving: write a temp file, then rename over the
        // config so the inode changes underneath the snapshot.
        let external = "# 外部修改\nalpha|3430|user@host-external|443|\ndelta|3440|user@host-d|443|\n"
        let tmp = workDir + "/external-\(UUID().uuidString).tmp"
        try writeFile(external, to: tmp)
        let renamed = rename(tmp, configPath)
        XCTAssertEqual(renamed, 0, "模拟外部保存的 rename 应成功")

        XCTAssertEqual(model.save(), .conflict, "外部改动后保存必须报冲突")
        XCTAssertEqual(try diskText(), external, "冲突时不得覆盖外部写入的内容")
        XCTAssertTrue(model.hasUnsavedChanges(), "冲突后草稿必须保留")
        XCTAssertEqual(model.form(for: alphaID)?.remotePort, "8443", "草稿里的改动应还在")

        model.reload()
        XCTAssertFalse(model.hasUnsavedChanges(), "重新载入后应没有未保存改动")
        XCTAssertEqual(model.rows.map(\.title), ["alpha", "delta"], "重新载入应拿到外部内容")
        let deltaID = try targetID("delta", in: model)
        XCTAssertEqual(model.form(for: deltaID)?.sshTarget, "user@host-d")

        let afterReload = model.save()
        guard case .written(let text) = afterReload else {
            XCTFail("重新载入后保存应成功（冲突已清除），实际 \(afterReload)")
            return
        }
        XCTAssertEqual(text, external, "重新载入后再保存应保持外部内容")
        XCTAssertEqual(try diskText(), external)
    }

    // MARK: - write failure

    func testWriteFailureKeepsDraftIntact() throws {
        // A path that exists but is a directory: reading it fails, writing
        // cannot replace it with a regular file.
        let dirPath = workDir + "/confdir"
        try FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        let model = ConfigEditorModel(path: dirPath)
        XCTAssertEqual(model.loadState,
                       .unreadable("文件无法读取（可能是权限或编码问题）"),
                       "不可读的路径应处于 unreadable 状态")
        XCTAssertTrue(model.rows.isEmpty, "读不到的配置按空草稿开始")

        let id = model.addTunnel()
        XCTAssertTrue(model.apply(form(named: "gamma", localPort: "3430",
                                       sshTarget: "user@host-g", remotePort: "443",
                                       webKey: ""), to: id))
        XCTAssertTrue(model.hasUnsavedChanges())

        let result = model.save()
        guard case .failed(let message) = result else {
            XCTFail("配置路径是目录时保存应失败，实际 \(result)")
            return
        }
        XCTAssertTrue(message.contains("无法写入配置文件"),
                      "失败信息应说明无法写入，实际 \(message)")
        XCTAssertTrue(model.hasUnsavedChanges(), "写入失败后草稿必须保留")
        XCTAssertEqual(model.rows.count, 1, "写入失败后列表内容不应丢失")
        XCTAssertEqual(model.form(for: id)?.name, "gamma", "写入失败后字段内容不应丢失")
        XCTAssertNil(model.savedDigest, "写入失败不应记录已保存摘要")

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirPath, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "失败后配置路径仍是目录，未被替换")
        let contents = try FileManager.default.contentsOfDirectory(atPath: workDir)
        XCTAssertEqual(contents.sorted(), ["confdir"], "写入失败后不应留下 .tmp 文件")
    }

    // MARK: - port suggestion bounds

    /// The port walk stops at 65535 instead of running off the valid range, and
    /// falls back to the usual start when nothing is free (the form's
    /// duplicate-port problem then blocks the save).
    func testFreeLocalPortWalkIsBounded() throws {
        XCTAssertEqual(ConfigEditorModel.freeLocalPort(used: []), 3430, "空草稿从 3430 开始")
        XCTAssertEqual(ConfigEditorModel.freeLocalPort(used: [3430, 3431]), 3432, "跳过已占用端口")
        XCTAssertEqual(ConfigEditorModel.freeLocalPort(startingAt: 65533, used: []), 65533)
        XCTAssertEqual(ConfigEditorModel.freeLocalPort(startingAt: 65533,
                                                       used: [65533, 65534]),
                       65535, "上限 65535 本身仍是合法端口")
        XCTAssertEqual(ConfigEditorModel.freeLocalPort(startingAt: 65534,
                                                       used: [65534, 65535]),
                       65534, "无端口可用时应回落而不是越过 65535")
        XCTAssertEqual(ConfigEditorModel.freeLocalPort(startingAt: 65535, used: [65535]), 65535,
                       "从上限起步且被占用时也不得越界")
    }

    // MARK: - successful save state

    func testSuccessfulSaveClearsDirtyAndMatchesDigest() throws {
        let model = try makeModel(threeText)
        let alphaID = try targetID("alpha", in: model)
        let betaID = try targetID("beta", in: model)

        XCTAssertTrue(model.delete(id: betaID), "删除 beta 应成功")
        XCTAssertEqual(model.pendingDeletionNames, ["beta"])
        XCTAssertTrue(model.apply(form(named: "alpha", localPort: "3430",
                                       sshTarget: "user@host-a", remotePort: "8443",
                                       webKey: "deadbeef"), to: alphaID))

        let result = model.save()
        guard case .written(let text) = result else {
            XCTFail("合法草稿保存应成功，实际 \(result)")
            return
        }
        let onDisk = try diskText()
        XCTAssertEqual(onDisk, "# 三台开发机\nalpha|3430|user@host-a|8443|deadbeef\n"
            + "gamma|3432|user@host-c|443|\n", "应写入修改后的内容并删掉 beta")
        XCTAssertEqual(text, onDisk, "save() 返回文本应等于写入的内容")
        XCTAssertFalse(model.hasUnsavedChanges(), "保存成功后不应再有未保存改动")
        XCTAssertEqual(model.pendingDeletionNames, [], "保存成功后待删除名单应清空")
        XCTAssertFalse(model.canUndoDelete(), "保存成功后删除不可再撤销")
        XCTAssertEqual(model.savedText, onDisk, "savedText 应是这次写入的文本")
        XCTAssertEqual(model.savedDigest, ConfigDigest.digest(onDisk),
                       "savedDigest 应等于磁盘内容的摘要")
        XCTAssertEqual(model.savedDigest, ConfigDigest.digest(model.draft.serialize()),
                       "savedDigest 也应等于草稿序列化文本的摘要")
        XCTAssertEqual(model.savedDigest?.count ?? 0, 16, "摘要是 16 位十六进制")
        XCTAssertFalse(model.snapshot.isStale(), "保存后快照应是最新的")
    }

    // MARK: - blocked save structure

    func testBlockedSaveDistinguishesBrokenRowFromFieldProblem() throws {
        let text = "# 注释\nalpha|3430|user@host-a|443|\nbroken-line\n"
        let model = try makeModel(text)
        let alphaID = try targetID("alpha", in: model)

        XCTAssertTrue(model.apply(form(named: "", localPort: "3430",
                                       sshTarget: "user@host-a", remotePort: "443",
                                       webKey: ""), to: alphaID),
                      "把名称改成空串应被接受为草稿改动（它在保存前才被校验）")
        XCTAssertTrue(model.hasUnsavedChanges())

        let result = model.save()
        guard case .blocked(let problems) = result else {
            XCTFail("坏行 + 非法表单时保存应先返回 .blocked，实际 \(result)")
            return
        }
        XCTAssertEqual(problems.count, 2, "字段级问题和行级问题各一条")
        XCTAssertEqual(problems[0].line, 2, "字段级问题应指向表单所在行")
        XCTAssertEqual(problems[0].message, "名字不能为空",
                       "字段级问题是字段错误原文")
        XCTAssertFalse(problems[0].message.hasPrefix("第 "),
                       "字段级问题不应自带行号前缀，行号由 SaveProblem.line 提供")
        XCTAssertEqual(problems[1].line, 3, "行级问题应指向坏行")
        XCTAssertTrue(problems[1].message.hasPrefix("第 3 行："),
                      "行级问题自带行号：实际 \(problems[1].message)")
        XCTAssertTrue(problems[1].message.contains("请修正或删除这一行"),
                      "行级问题应提示修正或删除")
        XCTAssertEqual(problems[1].message, model.draft.blockingProblems().last?.message,
                       "行级问题应原样来自 blockingProblems()")
        XCTAssertEqual(try diskText(), text, "被阻止的保存不应写入任何内容")
        XCTAssertTrue(model.hasUnsavedChanges(), "被阻止时草稿必须保留")
    }
}
