import XCTest
@testable import MagpieTunnelCore

/// Regression tests for the log window's "reopening the window doubled the
/// text" bug.
///
/// The window is AppKit code and is not unit-testable, so the decision it used
/// to get wrong — "is this the same source, or do I have to clear the view?" —
/// lives in `LogSourceFeed`, which these tests drive. `LogWindowController` now
/// mirrors exactly what is asserted here:
/// - `bind(path:) == false` → keep the text view and the reader, append only
///   what arrived since the last read;
/// - `bind(path:) == true` → clear the text view, then append from offset 0;
/// - a `didReset` chunk on an unchanged path still clears the view.
final class LogSourceFeedTests: XCTestCase {
    private var workDir: String!

    override func setUpWithError() throws {
        workDir = NSTemporaryDirectory() + "magpie-logfeed-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: workDir)
    }

    private var appLogPath: String { workDir + "/app.log" }
    private var tunnelLogPath: String { workDir + "/tunnel.log" }

    private func append(_ text: String, to path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        handle.write(text.data(using: .utf8)!)
        try handle.close()
    }

    /// Applies one "present this source" cycle the way the window does:
    /// bind → clear when the binding says so → read → clear on didReset →
    /// append. Returns the chunk so a test can assert on `didReset`.
    @discardableResult
    private func present(_ path: String,
                         in feed: inout LogSourceFeed,
                         display: inout String) -> LogChunk {
        if feed.bind(path: path) {
            display = ""
        }
        let chunk = feed.read()
        if chunk.didReset {
            display = ""
        }
        display += chunk.text
        return chunk
    }

    // MARK: - the reported bug

    func testPresentingSameSourceTwiceDoesNotReplayTheFile() throws {
        try "one\ntwo\nthree\n".write(toFile: appLogPath, atomically: true, encoding: .utf8)

        var feed = LogSourceFeed()
        var display = ""
        present(appLogPath, in: &feed, display: &display)
        XCTAssertEqual(display, "one\ntwo\nthree\n")

        // Reopen the window on the same source: the old bug re-appended the file.
        present(appLogPath, in: &feed, display: &display)
        XCTAssertEqual(display, "one\ntwo\nthree\n", "同一路径重复呈现不得重放整份日志")
        XCTAssertEqual(display.components(separatedBy: "\n").filter { !$0.isEmpty }.count, 3)
    }

    func testPresentingSameSourceAppendsOnlyNewLines() throws {
        try "one\ntwo\n".write(toFile: appLogPath, atomically: true, encoding: .utf8)

        var feed = LogSourceFeed()
        var display = ""
        present(appLogPath, in: &feed, display: &display)
        XCTAssertEqual(display, "one\ntwo\n")

        try append("three\n", to: appLogPath)
        present(appLogPath, in: &feed, display: &display)
        XCTAssertEqual(display, "one\ntwo\nthree\n", "重复呈现要读到期间新追加的行，且不重复旧行")

        try append("four\n", to: appLogPath)
        present(appLogPath, in: &feed, display: &display)
        XCTAssertEqual(display, "one\ntwo\nthree\nfour\n")
    }

    func testSecondPresentRepeatedlyStaysStable() throws {
        try "a\nb\n".write(toFile: appLogPath, atomically: true, encoding: .utf8)

        var feed = LogSourceFeed()
        var display = ""
        for _ in 0..<5 { present(appLogPath, in: &feed, display: &display) }
        XCTAssertEqual(display, "a\nb\n", "多次重复呈现后内容必须仍是原始一遍")
    }

    /// The field case: a 9-line log, window reopened four times. The old bug
    /// showed 9 → 18 → 27 → 36 lines; the line count must stay at 9.
    func testNineLineLogStaysNineLinesAcrossFourOpens() throws {
        try "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9\n"
            .write(toFile: appLogPath, atomically: true, encoding: .utf8)

        var feed = LogSourceFeed()
        var display = ""
        for open in 1...4 {
            present(appLogPath, in: &feed, display: &display)
            let lines = display.components(separatedBy: "\n").filter { !$0.isEmpty }.count
            XCTAssertEqual(lines, 9, "第 \(open) 次打开后应仍是 9 行，实际 \(lines) 行")
        }
        XCTAssertEqual(display, "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9\n")
    }

    // MARK: - switching sources

    func testBindingAnotherSourceResetsTheDisplay() throws {
        try "app-1\napp-2\n".write(toFile: appLogPath, atomically: true, encoding: .utf8)
        try "tunnel-1\n".write(toFile: tunnelLogPath, atomically: true, encoding: .utf8)

        var feed = LogSourceFeed()
        var display = ""
        present(appLogPath, in: &feed, display: &display)
        XCTAssertEqual(display, "app-1\napp-2\n")

        present(tunnelLogPath, in: &feed, display: &display)
        XCTAssertEqual(display, "tunnel-1\n", "切换来源必须先清空，只显示新来源")

        present(appLogPath, in: &feed, display: &display)
        XCTAssertEqual(display, "app-1\napp-2\n", "切回旧来源同样清空后重读")
    }

    // MARK: - binding decisions

    func testFirstBindNeedsResetBecauseNoReaderExists() {
        var feed = LogSourceFeed()
        XCTAssertFalse(feed.isBound)
        XCTAssertTrue(feed.shouldResetDisplay(for: appLogPath))
        XCTAssertTrue(feed.bind(path: appLogPath))
        XCTAssertTrue(feed.isBound)
        // Still the same source: no reset any more.
        XCTAssertFalse(feed.shouldResetDisplay(for: appLogPath))
        XCTAssertFalse(feed.bind(path: appLogPath))
    }

    func testNilPathUnbindsAndClears() {
        var feed = LogSourceFeed()
        _ = feed.bind(path: appLogPath)
        XCTAssertTrue(feed.shouldResetDisplay(for: nil), "已有 reader 时清空显示")
        XCTAssertTrue(feed.bind(path: nil))
        XCTAssertFalse(feed.isBound)
        XCTAssertEqual(feed.read(), .empty)
        // Unbound → binding a real path is again a reset.
        XCTAssertTrue(feed.bind(path: appLogPath))
    }

    func testReadWithoutBindingIsEmpty() {
        let feed = LogSourceFeed()
        XCTAssertFalse(feed.isBound)
        XCTAssertEqual(feed.read(), .empty)
    }

    // MARK: - rotation must still reset

    func testRotationOnUnchangedPathStillReportsReset() throws {
        try "old-a\nold-b\n".write(toFile: appLogPath, atomically: true, encoding: .utf8)

        var feed = LogSourceFeed()
        var display = ""
        present(appLogPath, in: &feed, display: &display)
        XCTAssertEqual(display, "old-a\nold-b\n")

        // Replace the file behind the same path: rotating/truncating is not a
        // source switch, so `bind` must say "no reset" and the reader's own
        // `didReset` must carry the clearing instead.
        let rotated = workDir + "/app.log.1"
        try FileManager.default.moveItem(atPath: appLogPath, toPath: rotated)
        try "new-a\n".write(toFile: appLogPath, atomically: true, encoding: .utf8)

        let chunk = present(appLogPath, in: &feed, display: &display)
        XCTAssertTrue(chunk.didReset, "轮转必须由 reader 报告 didReset")
        XCTAssertEqual(chunk.text, "new-a\n")
        XCTAssertEqual(display, "new-a\n", "轮转后显示只保留新文件")
    }

    func testTruncationInPlaceOnUnchangedPathStillReportsReset() throws {
        try "aaaaaaaa\ntail\n".write(toFile: appLogPath, atomically: true, encoding: .utf8)

        var feed = LogSourceFeed()
        var display = ""
        present(appLogPath, in: &feed, display: &display)
        XCTAssertEqual(display, "aaaaaaaa\ntail\n")

        try "short\n".write(toFile: appLogPath, atomically: false, encoding: .utf8)

        let chunk = present(appLogPath, in: &feed, display: &display)
        XCTAssertTrue(chunk.didReset, "原地截断必须由 reader 报告 didReset")
        XCTAssertEqual(chunk.text, "short\n")
        XCTAssertEqual(display, "short\n", "截断后显示只保留新内容")
    }
}
