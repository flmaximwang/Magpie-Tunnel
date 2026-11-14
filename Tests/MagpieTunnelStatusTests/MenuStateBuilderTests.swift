import XCTest
@testable import MagpieTunnelCore
@testable import MagpieTunnelStatus

/// Pure-logic tests for MenuStateBuilder: all-up / partial / all-down /
/// empty config, icons, summary text, per-target rows, key vs keyless URLs.
final class MenuStateBuilderTests: XCTestCase {
    private func target(_ name: String, port: Int, key: String = "") -> TargetConfig {
        TargetConfig(name: name, localPort: port, sshTarget: "user@host", remotePort: 443, webKey: key)
    }

    private func statuses(up: [String]) -> [String: StatusRecord] {
        var result: [String: StatusRecord] = [:]
        for name in up {
            result[name] = .up(port: 12345)
        }
        return result
    }

    func testAllUp() {
        let targets = [target("alpha", port: 3430, key: "a1b2c3"), target("beta", port: 3431)]
        let state = MenuStateBuilder.build(targets: targets, statuses: statuses(up: ["alpha", "beta"]))
        XCTAssertTrue(state.allUp)
        XCTAssertEqual(state.iconEmoji, "🔗")
        XCTAssertEqual(state.summaryTitle, "magpie 隧道 2/2")
        XCTAssertEqual(state.targetRows.map(\.title),
                       ["✓ alpha localhost:3430", "✓ beta localhost:3431"])
    }

    func testPartialDegraded() {
        let targets = [target("alpha", port: 3430), target("beta", port: 3431)]
        let state = MenuStateBuilder.build(targets: targets, statuses: statuses(up: ["alpha"]))
        XCTAssertFalse(state.allUp)
        XCTAssertEqual(state.iconEmoji, "🔗⃠")
        XCTAssertEqual(state.summaryTitle, "magpie 隧道 1/2")
        XCTAssertEqual(state.targetRows[1].title, "✗ beta localhost:3431")
    }

    func testAllDown() {
        let targets = [target("alpha", port: 3430), target("beta", port: 3431)]
        let state = MenuStateBuilder.build(targets: targets, statuses: statuses(up: []))
        XCTAssertFalse(state.allUp)
        XCTAssertEqual(state.iconEmoji, "🔗⃠")
        XCTAssertEqual(state.summaryTitle, "magpie 隧道 0/2")
        XCTAssertEqual(state.targetRows.map(\.isUp), [false, false])
    }

    func testEmptyConfigIsDegradedNotAllUp() {
        let state = MenuStateBuilder.build(targets: [], statuses: [:])
        XCTAssertFalse(state.allUp)
        XCTAssertEqual(state.iconEmoji, "🔗⃠")
        XCTAssertEqual(state.summaryTitle, "magpie 隧道 0/0")
        XCTAssertTrue(state.targetRows.isEmpty)
    }

    func testMissingStatusFileCountsAsDown() {
        // No entry at all for "beta" — must render as ✗, not crash.
        let targets = [target("alpha", port: 3430), target("beta", port: 3431)]
        let state = MenuStateBuilder.build(targets: targets, statuses: statuses(up: ["alpha"]))
        XCTAssertEqual(state.summaryTitle, "magpie 隧道 1/2")
        XCTAssertFalse(state.targetRows[1].isUp)
    }

    func testKeyedRowUsesKParameterURL() {
        let state = MenuStateBuilder.build(targets: [target("alpha", port: 3430, key: "cafe01")],
                                           statuses: statuses(up: ["alpha"]))
        XCTAssertEqual(state.targetRows[0].url, "http://127.0.0.1:3430/?k=cafe01")
        XCTAssertFalse(state.targetRows[0].url.contains("?key="))
    }

    func testKeylessRowHasNoQuery() {
        let state = MenuStateBuilder.build(targets: [target("alpha", port: 3431)],
                                           statuses: statuses(up: []))
        XCTAssertEqual(state.targetRows[0].url, "http://127.0.0.1:3431/")
    }

    func testConfigOrderIsPreserved() {
        let targets = [target("zeta", port: 3500), target("alpha", port: 3501), target("mid", port: 3502)]
        let state = MenuStateBuilder.build(targets: targets, statuses: statuses(up: ["mid"]))
        XCTAssertEqual(state.targetRows.map(\.name), ["zeta", "alpha", "mid"])
        XCTAssertEqual(state.targetRows.map(\.isUp), [false, false, true])
    }
}
