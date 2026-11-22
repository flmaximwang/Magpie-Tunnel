import XCTest
@testable import MagpieTunnelStatus

/// Pure-logic tests for the log window's status line: the standing statistics
/// and a one-off confirmation share one label, so their composition is what
/// decides whether the ticker erases the confirmation.
final class LogWindowStatusTextTests: XCTestCase {
    // The minimum statistics line the window can produce: the line count always
    // exists, everything else is conditional.
    private let statistics = ["2 行", "没有匹配"]

    func testTransientComesFirstWhenVisible() {
        XCTAssertEqual(
            LogWindowController.statusText(statistics: statistics,
                                           transient: "已复制当前显示的日志",
                                           isTransientValid: true),
            "已复制当前显示的日志 · 2 行 · 没有匹配"
        )
    }

    func testStatisticsAloneWhenNoTransient() {
        XCTAssertEqual(
            LogWindowController.statusText(statistics: statistics,
                                           transient: nil,
                                           isTransientValid: false),
            "2 行 · 没有匹配"
        )
    }

    /// After the deadline the caller keeps the text but flips the flag; the
    /// confirmation must disappear and the statistics must be untouched.
    func testExpiredTransientLeavesStatisticsOnly() {
        XCTAssertEqual(
            LogWindowController.statusText(statistics: statistics,
                                           transient: "已复制当前显示的日志",
                                           isTransientValid: false),
            "2 行 · 没有匹配"
        )
    }

    func testEmptyOrBlankTransientIsIgnored() {
        XCTAssertEqual(
            LogWindowController.statusText(statistics: statistics,
                                           transient: "",
                                           isTransientValid: true),
            "2 行 · 没有匹配"
        )
        XCTAssertEqual(
            LogWindowController.statusText(statistics: statistics,
                                           transient: "   ",
                                           isTransientValid: true),
            "2 行 · 没有匹配"
        )
    }

    /// The standalone statistics texts the window can show, with and without a
    /// confirmation in front. The pause notice keeps all its parts.
    func testFullStatisticsStayIntactBehindTransient() {
        let full = ["7 行", "已向上滚动，暂停自动跟随；点「跳到最新」恢复", "1 处匹配"]
        XCTAssertEqual(
            LogWindowController.statusText(statistics: full, transient: nil, isTransientValid: false),
            "7 行 · 已向上滚动，暂停自动跟随；点「跳到最新」恢复 · 1 处匹配"
        )
        XCTAssertEqual(
            LogWindowController.statusText(statistics: full, transient: "已跳到最新", isTransientValid: true),
            "已跳到最新 · 7 行 · 已向上滚动，暂停自动跟随；点「跳到最新」恢复 · 1 处匹配"
        )
    }

    func testNoStatisticsAndTransientYieldsTransientOnly() {
        XCTAssertEqual(
            LogWindowController.statusText(statistics: [], transient: "已复制选中的内容", isTransientValid: true),
            "已复制选中的内容"
        )
        XCTAssertEqual(
            LogWindowController.statusText(statistics: [], transient: nil, isTransientValid: false),
            ""
        )
    }
}
