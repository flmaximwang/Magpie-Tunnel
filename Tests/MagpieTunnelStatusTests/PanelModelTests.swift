import XCTest
@testable import MagpieTunnelCore
@testable import MagpieTunnelStatus

/// Pure-logic tests for the panel model: state mapping, row titles, empty
/// states, the subtitle line, the icon state and the key-vs-keyless URL.
final class PanelModelTests: XCTestCase {
    private func target(_ name: String, port: Int, key: String = "") -> TargetConfig {
        TargetConfig(name: name, localPort: port, sshTarget: "user@host", remotePort: 443, webKey: key)
    }

    private func statuses(up: [String]) -> [String: StatusRecord] {
        var result: [String: StatusRecord] = [:]
        for name in up {
            result[name] = .up(port: 3430)
        }
        return result
    }

    // MARK: - state mapping

    func testStateMapping() {
        XCTAssertEqual(TunnelConnectionState.from(.up(port: 3430)), .connected)
        XCTAssertEqual(TunnelConnectionState.from(.connecting()), .connecting)
        XCTAssertEqual(TunnelConnectionState.from(.down(reason: "ssh 断开 rc=1")),
                       .disconnected(reason: "ssh 断开 rc=1"))
        XCTAssertEqual(TunnelConnectionState.from(.down(reason: "")), .disconnected(reason: nil))
        XCTAssertEqual(TunnelConnectionState.from(nil), .unknown)
    }

    func testUnknownStateFromForeignRecord() {
        XCTAssertEqual(TunnelConnectionState.from(StatusRecord(state: "bogus", epoch: 1, detail: "")),
                       .unknown)
    }

    func testLabelsAreShortAndChinese() {
        XCTAssertEqual(TunnelConnectionState.connected.label, "已连接")
        XCTAssertEqual(TunnelConnectionState.connecting.label, "连接中")
        XCTAssertEqual(TunnelConnectionState.disconnected(reason: nil).label, "未连接")
        XCTAssertEqual(TunnelConnectionState.unknown.label, "状态未知")
    }

    func testDetailOnlyForDisconnected() {
        XCTAssertNil(TunnelConnectionState.connected.detail)
        XCTAssertNil(TunnelConnectionState.connecting.detail)
        XCTAssertNil(TunnelConnectionState.unknown.detail)
        XCTAssertEqual(TunnelConnectionState.disconnected(reason: "端口被占用").detail, "端口被占用")
    }

    // MARK: - rows

    func testAllUp() {
        let targets = [target("alpha", port: 3430, key: "a1b2c3"), target("beta", port: 3431)]
        let state = PanelStateBuilder.build(targets: targets,
                                            statuses: statuses(up: ["alpha", "beta"]))
        XCTAssertTrue(state.allUp)
        XCTAssertEqual(state.iconState, .healthy)
        XCTAssertEqual(state.subtitle, "2 条隧道，全部已连接")
        XCTAssertEqual(state.rows.map(\.title),
                       ["alpha  127.0.0.1:3430  已连接", "beta  127.0.0.1:3431  已连接"])
    }

    func testSingleConnectedTunnelReadsNaturally() {
        let state = PanelStateBuilder.build(targets: [target("alpha", port: 3430)],
                                            statuses: statuses(up: ["alpha"]))
        XCTAssertEqual(state.subtitle, "1 条隧道，已连接")
        XCTAssertEqual(state.iconState, .healthy)
    }

    func testPartialConnection() {
        let targets = [target("alpha", port: 3430), target("beta", port: 3431)]
        let state = PanelStateBuilder.build(targets: targets,
                                            statuses: statuses(up: ["alpha"]))
        XCTAssertFalse(state.allUp)
        XCTAssertEqual(state.iconState, .degraded)
        XCTAssertEqual(state.subtitle, "2 条隧道，1 条已连接")
        // "beta" has a status record but it is `down`; missing file would be unknown.
        XCTAssertEqual(state.rows[1].state, .unknown)
        XCTAssertEqual(state.rows[1].title, "beta  127.0.0.1:3431  状态未知")
    }

    func testMissingStatusFileIsUnknownNotDisconnected() {
        // No record at all — the daemon may simply not have written it yet, so
        // "未连接" would be a claim the app cannot make.
        let state = PanelStateBuilder.build(targets: [target("alpha", port: 3430), target("beta", port: 3431)],
                                            statuses: [:])
        XCTAssertEqual(state.rows.map(\.state.label), ["状态未知", "状态未知"])
        XCTAssertEqual(state.subtitle, "2 条隧道，状态未知")
        XCTAssertFalse(state.allUp)
    }

    func testDisconnectedRowShowsReason() {
        var records = statuses(up: ["alpha"])
        records["beta"] = .down(reason: "ssh 断开 rc=255")
        let state = PanelStateBuilder.build(targets: [target("beta", port: 3431)], statuses: records)
        XCTAssertEqual(state.rows[0].state, .disconnected(reason: "ssh 断开 rc=255"))
        XCTAssertEqual(state.rows[0].title, "beta  127.0.0.1:3431  未连接：ssh 断开 rc=255")
    }

    func testConnectingIsNotConnectable() {
        var records: [String: StatusRecord] = [:]
        records["alpha"] = .connecting()
        let state = PanelStateBuilder.build(targets: [target("alpha", port: 3430)], statuses: records)
        XCTAssertEqual(state.rows[0].state, .connecting)
        XCTAssertFalse(state.rows[0].isConnectable, "连接中的隧道不能打开")
        XCTAssertEqual(state.subtitle, "1 条隧道，0 条已连接")
    }

    func testConfigOrderIsPreserved() {
        let targets = [target("zeta", port: 3500), target("alpha", port: 3501), target("mid", port: 3502)]
        let state = PanelStateBuilder.build(targets: targets,
                                            statuses: statuses(up: ["mid"]))
        XCTAssertEqual(state.rows.map(\.name), ["zeta", "alpha", "mid"])
    }

    // MARK: - URLs

    func testKeyedRowUsesKParameterURL() {
        let state = PanelStateBuilder.build(targets: [target("alpha", port: 3430, key: "cafe01")],
                                            statuses: statuses(up: ["alpha"]))
        XCTAssertEqual(state.rows[0].url, "http://127.0.0.1:3430/?k=cafe01")
        XCTAssertFalse(state.rows[0].url.contains("?key="))
    }

    func testKeylessRowHasNoQuery() {
        let state = PanelStateBuilder.build(targets: [target("alpha", port: 3431)], statuses: [:])
        XCTAssertEqual(state.rows[0].url, "http://127.0.0.1:3431/")
    }

    // MARK: - empty states

    func testNoTunnelsOffersAdd() {
        let state = PanelStateBuilder.build(targets: [], statuses: [:])
        XCTAssertEqual(state.emptyState, .noTunnels)
        XCTAssertEqual(state.emptyState.message, "尚未配置隧道")
        XCTAssertEqual(state.emptyState.actionTitle, "添加隧道")
        XCTAssertEqual(state.subtitle, "尚未配置隧道")
    }

    func testBrokenConfigurationOffersFix() {
        let state = PanelStateBuilder.build(targets: [],
                                            statuses: [:],
                                            diagnostics: ["第 3 行：端口必须是 1...65535"])
        XCTAssertEqual(state.emptyState, .brokenConfiguration(count: 1))
        XCTAssertEqual(state.emptyState.message, "配置有 1 行错误，没有可用的隧道")
        XCTAssertEqual(state.emptyState.actionTitle, "修正配置")
    }

    func testUnreadableConfigurationWinsOverEmptyState() {
        let state = PanelStateBuilder.build(targets: [], statuses: [:], configError: "文件无法读取")
        XCTAssertEqual(state.emptyState, .unreadableConfiguration)
        XCTAssertTrue(state.subtitle.hasPrefix("配置无法读取"))
        XCTAssertEqual(state.iconState, .degraded)
    }

    func testBrokenLinesAlongsideWorkingTunnels() {
        let state = PanelStateBuilder.build(targets: [target("alpha", port: 3430)],
                                            statuses: statuses(up: ["alpha"]),
                                            diagnostics: ["第 9 行：SSH 目标不能为空"])
        XCTAssertEqual(state.emptyState, PanelEmptyState.none)
        XCTAssertEqual(state.subtitle, "1 条隧道，另有 1 行配置错误")
        XCTAssertEqual(state.iconState, .degraded, "有坏行时图标必须是 degraded")
    }

    func testEmptyConfigIsDegraded() {
        XCTAssertEqual(PanelState.empty.iconState, .degraded)
        XCTAssertFalse(PanelState.empty.allUp)
    }

    func testIconAccessibilityLabels() {
        let allUp = PanelStateBuilder.build(targets: [target("alpha", port: 3430)],
                                            statuses: statuses(up: ["alpha"]))
        XCTAssertEqual(allUp.iconAccessibilityLabel, "Magpie-WebUI-Tunnel：全部隧道已连接")
        let unknown = PanelStateBuilder.build(targets: [target("alpha", port: 3430)], statuses: [:])
        XCTAssertEqual(unknown.iconAccessibilityLabel, "Magpie-WebUI-Tunnel：隧道状态未知")
        XCTAssertEqual(PanelState.empty.iconAccessibilityLabel, "Magpie-WebUI-Tunnel：尚未配置隧道")
    }

    func testCanRestartTunnelsMatchesEmptyState() {
        XCTAssertFalse(PanelState.empty.canRestartTunnels)

        let brokenOnly = PanelStateBuilder.build(targets: [], statuses: [:], diagnostics: ["第 1 行：错误"])
        XCTAssertFalse(brokenOnly.canRestartTunnels)

        let unreadable = PanelStateBuilder.build(targets: [], statuses: [:], configError: "无法读取")
        XCTAssertFalse(unreadable.canRestartTunnels)

        let withTunnel = PanelStateBuilder.build(targets: [target("alpha", port: 3430)], statuses: [:])
        XCTAssertTrue(withTunnel.canRestartTunnels)

        let partialBroken = PanelStateBuilder.build(targets: [target("alpha", port: 3430)],
                                                    statuses: [:],
                                                    diagnostics: ["第 2 行：错误"])
        XCTAssertTrue(partialBroken.canRestartTunnels)
    }
}
