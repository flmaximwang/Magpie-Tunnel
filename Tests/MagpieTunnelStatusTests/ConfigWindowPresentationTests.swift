import XCTest
@testable import MagpieTunnelCore
@testable import MagpieTunnelStatus

/// Tests for the reconciliation `ConfigWindowController.present()` performs
/// before a closed window is shown again.
///
/// The window and its draft outlive the red button, and the file on disk keeps
/// changing in the meantime, so re-presenting has to decide between adopting
/// disk and protecting the draft. The decision is a pure function, and the
/// selection mapping after a reload is another one, so both are tested here
/// without opening a window or an NSApplication.
final class ConfigWindowPresentationTests: XCTestCase {
    private var workDir: String!

    override func setUpWithError() throws {
        workDir = NSTemporaryDirectory() + "magpie-presentation-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: workDir)
    }

    private var configPath: String { workDir + "/targets.conf" }

    private let twoText = "one|3430|user@host-a|443|\ntwo|3431|user@host-b|443|\n"

    @discardableResult
    private func writeConfig(_ text: String) throws -> ConfigEditorModel {
        try text.write(toFile: configPath, atomically: false, encoding: .utf8)
        return ConfigEditorModel(path: configPath)
    }

    /// Append a tunnel the way an outside editor does: a whole new file moved
    /// over the old one, so the inode changes underneath any snapshot.
    private func appendExternally(_ line: String) throws {
        let tmp = workDir + "/external-\(UUID().uuidString).tmp"
        try (twoText + line).write(toFile: tmp, atomically: false, encoding: .utf8)
        XCTAssertEqual(rename(tmp, configPath), 0, "模拟外部保存的 rename 应成功")
    }

    // MARK: - when reconciliation runs at all

    func testOnlyAClosedOrMinimizedWindowIsReconciled() {
        XCTAssertTrue(ConfigWindowController.needsPresentationReconciliation(isVisible: false,
                                                                            isMiniaturized: false),
                      "关掉的窗口重新打开时必须对账 —— 这就是本次缺陷的路径")
        XCTAssertTrue(ConfigWindowController.needsPresentationReconciliation(isVisible: true,
                                                                            isMiniaturized: true),
                      "最小化到 Dock 的窗口再打开也要对账，它同样可能已经关了很久")
        XCTAssertFalse(ConfigWindowController.needsPresentationReconciliation(isVisible: true,
                                                                             isMiniaturized: false),
                       "已经显示在屏幕上的窗口只是被带到前台：重新读盘会清掉正在编辑的表单")
    }

    // MARK: - the status line each branch leaves behind

    func testConflictStatusNamesTheConflictAndKeepsTheDraftMessage() {
        let text = ConfigWindowController.presentationStatusText(for: .keepDraftConflict)
        XCTAssertTrue(text.contains("配置文件已在别处被修改"),
                      "冲突分支的状态行应说明文件被外部修改，实际 \(text)")
        XCTAssertTrue(text.contains("草稿保留"),
                      "冲突分支的状态行应说明草稿仍在，实际 \(text)")
        XCTAssertNotEqual(text, "已应用", "冲突时不得保留上一次的「已应用」")
    }

    func testCleanDraftStatusDescribesTheUnsavedDraftOnly() {
        XCTAssertEqual(ConfigWindowController.presentationStatusText(for: .keepDraftClean),
                       ConfigWindowController.unsavedStatusText,
                       "文件没变时应只说草稿未保存")
        XCTAssertEqual(ConfigWindowController.presentationStatusText(for: .keepDraftClean), "有未保存的改动")
        XCTAssertNotEqual(ConfigWindowController.presentationStatusText(for: .keepDraftClean),
                          "已应用", "跨会话残留的「已应用」必须被替换")
    }

    func testReloadStatusIsEmpty() {
        XCTAssertEqual(ConfigWindowController.presentationStatusText(for: .reloadFromDisk), "",
                       "没有草稿时状态行留空，而不是沿用上次的保存结果")
    }

    // MARK: - the three branches of presentationAction

    func testDraftWithChangedFileKeepsDraftAndRaisesConflict() {
        XCTAssertEqual(
            ConfigWindowController.presentationAction(hasUnsavedChanges: true, isSnapshotStale: true),
            .keepDraftConflict,
            "有草稿且文件已变：保留草稿并提示冲突，绝不重新载入覆盖它"
        )
    }

    func testDraftWithUnchangedFileKeepsDraftWithoutConflict() {
        XCTAssertEqual(
            ConfigWindowController.presentationAction(hasUnsavedChanges: true, isSnapshotStale: false),
            .keepDraftClean,
            "有草稿但文件没变：草稿与列表都不动，也不应报冲突"
        )
    }

    func testNoDraftReloadsFromDisk() {
        XCTAssertEqual(
            ConfigWindowController.presentationAction(hasUnsavedChanges: false, isSnapshotStale: true),
            .reloadFromDisk,
            "没有草稿可丢时磁盘优先 —— 这正是外部新增隧道后重开窗口看不到它的回归点"
        )
        XCTAssertEqual(
            ConfigWindowController.presentationAction(hasUnsavedChanges: false, isSnapshotStale: false),
            .reloadFromDisk,
            "文件没变也重新读盘，让状态行与列表都回到当前文件"
        )
    }

    // MARK: - decision driven by the model and the real file

    func testExternalAppendOnDraftProducesConflictBranch() throws {
        let model = try writeConfig(twoText)
        let oneID = try XCTUnwrap(model.rows.first { $0.title == "one" }?.id)
        var form = TunnelForm(target: model.draft.targets[0])
        form.remotePort = "8443"
        XCTAssertTrue(model.apply(form, to: oneID), "草稿改动应被接受")
        XCTAssertTrue(model.hasUnsavedChanges())

        try appendExternally("three|15003|ubuntu@example.invalid|443|k\n")
        XCTAssertTrue(model.snapshot.isStale(), "外部追加后快照应过期")

        XCTAssertEqual(
            ConfigWindowController.presentationAction(hasUnsavedChanges: model.hasUnsavedChanges(),
                                                       isSnapshotStale: model.snapshot.isStale()),
            .keepDraftConflict,
            "复现场景：有未保存草稿时重开窗口应保留草稿并提示，而不是回滚"
        )
        XCTAssertEqual(model.rows.map(\.title), ["one", "two"], "列表仍是草稿的旧内容")
    }

    func testExternalAppendWithoutDraftProducesReloadBranchAndShowsNewTunnel() throws {
        let model = try writeConfig(twoText)
        XCTAssertFalse(model.hasUnsavedChanges())

        try appendExternally("three|15003|ubuntu@example.invalid|443|k\n")
        XCTAssertTrue(model.snapshot.isStale(), "外部追加后快照应过期")

        XCTAssertEqual(
            ConfigWindowController.presentationAction(hasUnsavedChanges: model.hasUnsavedChanges(),
                                                       isSnapshotStale: model.snapshot.isStale()),
            .reloadFromDisk,
            "复现场景：无草稿时重开窗口应重新读盘并看到外部新增的隧道"
        )
        model.reload()
        XCTAssertEqual(model.rows.map(\.title), ["one", "two", "three"],
                       "重新载入后列表应包含外部追加的 three")
        XCTAssertFalse(model.snapshot.isStale(), "载入后快照应重新对齐磁盘")
    }

    // MARK: - selection after a reload

    func testReloadSelectionFollowsTunnelName() throws {
        let model = try writeConfig(twoText + "three|3432|user@host-c|443|\n")
        let rows = model.rows
        let two = try XCTUnwrap(rows.first { $0.title == "two" })
        XCTAssertEqual(ConfigWindowController.rowID(named: "two", in: rows), two.id,
                       "重载后应按隧道名找回同一条隧道")
        XCTAssertNil(ConfigWindowController.rowID(named: "gone", in: rows),
                     "隧道已被外部删除时不应选中任何行")
        XCTAssertNil(ConfigWindowController.rowID(named: nil, in: rows),
                     "原来没有选中行时不做猜测")
    }

    func testReloadSelectionNeverMatchesABrokenRow() throws {
        let text = "one|3430|user@host-a|443|\n第 2 行\n"
        let model = try writeConfig(text)
        let brokenRow = try XCTUnwrap(model.rows.first { $0.isBroken })
        let brokenTitle = model.brokenText(for: brokenRow.id) ?? "第 2 行"
        XCTAssertEqual(brokenRow.title, "第 \(brokenRow.lineNumber) 行")
        XCTAssertNil(ConfigWindowController.rowID(named: brokenRow.title, in: model.rows),
                     "坏行不是可编辑目标：按标题重选时不得落到它上面")
        XCTAssertNil(ConfigWindowController.rowID(named: brokenTitle, in: model.rows),
                     "坏行原文也不是隧道名")
    }
}
