import AppKit
import XCTest
@testable import MagpieTunnelCore
@testable import MagpieTunnelStatus

final class PanelViewControllerTests: XCTestCase {
    private var workDir: String!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        workDir = NSTemporaryDirectory() + "magpie-panel-vc-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: workDir + "/status",
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: workDir)
    }

    private func makePaths() -> TunnelPaths {
        TunnelPaths(configPath: workDir + "/targets.conf",
                    statusDirectory: workDir + "/status",
                    logDirectory: workDir + "/logs",
                    lockDirectory: workDir + "/lock",
                    sshBinary: "/usr/bin/ssh")
    }

    private func makeController(
        onRestart: @escaping () -> Void = {},
        onQuit: @escaping () -> Void = {}
    ) -> PanelViewController {
        let viewModel = StatusViewModel(paths: makePaths())
        let actions = PanelActions(
            openTunnel: { _ in },
            copyTunnel: { _ in },
            openConfiguration: {},
            openLogs: {},
            addTunnel: {},
            fixConfiguration: {},
            restartTunnels: onRestart,
            quit: onQuit
        )
        let vc = PanelViewController(viewModel: viewModel, actions: actions)
        vc.loadViewIfNeeded()
        return vc
    }

    func testRestartButtonDisabledWhenNoTunnelsAndEnabledWhenConfigured() throws {
        let vc = makeController()
        vc.refresh()

        let restartButton = try XCTUnwrap(vc.restartButton)
        XCTAssertFalse(restartButton.isEnabled)
        XCTAssertEqual(restartButton.normalTintColor, .tertiaryLabelColor)
        XCTAssertEqual(restartButton.toolTip, "重启全部隧道 · 现有连接会短暂中断")
        XCTAssertEqual(restartButton.accessibilityLabel(), "重启全部隧道")
        XCTAssertNotNil(restartButton.image)

        try "alpha|3430|user@host|443|\n".write(
            toFile: workDir + "/targets.conf",
            atomically: true,
            encoding: .utf8
        )
        vc.refresh()

        XCTAssertTrue(restartButton.isEnabled)
        XCTAssertEqual(restartButton.normalTintColor, .secondaryLabelColor)
    }

    func testRestartButtonDisabledWhenConfigurationBroken() throws {
        try "broken-line\n".write(
            toFile: workDir + "/targets.conf",
            atomically: true,
            encoding: .utf8
        )
        let vc = makeController()
        vc.refresh()

        let restartButton = try XCTUnwrap(vc.restartButton)
        XCTAssertFalse(restartButton.isEnabled)
        XCTAssertEqual(restartButton.normalTintColor, .tertiaryLabelColor)
    }

    func testRestartButtonTriggersRestartAction() throws {
        try "alpha|3430|user@host|443|\n".write(
            toFile: workDir + "/targets.conf",
            atomically: true,
            encoding: .utf8
        )
        var restartCount = 0
        let vc = makeController(onRestart: { restartCount += 1 })
        vc.refresh()

        let restartButton = try XCTUnwrap(vc.restartButton)
        XCTAssertTrue(restartButton.sendAction(restartButton.action, to: restartButton.target))
        XCTAssertEqual(restartCount, 1)
    }

    func testQuitButtonReplacesMoreAndHighlightsRedOnHover() throws {
        var quitCount = 0
        let vc = makeController(onQuit: { quitCount += 1 })
        vc.refresh()

        let quitButton = try XCTUnwrap(vc.quitButton)
        XCTAssertEqual(quitButton.title, "退出")
        XCTAssertEqual(quitButton.normalTintColor, .secondaryLabelColor)
        XCTAssertEqual(quitButton.hoverTintColor, .systemRed)
        XCTAssertEqual(quitButton.contentTintColor, .secondaryLabelColor)

        quitButton.updateTrackingAreas()
        XCTAssertEqual(quitButton.trackingAreas.count, 1)

        if let enterEvent = NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        ) {
            quitButton.mouseEntered(with: enterEvent)
            XCTAssertEqual(quitButton.contentTintColor, .systemRed)
        }

        if let exitEvent = NSEvent.enterExitEvent(
            with: .mouseExited,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        ) {
            quitButton.mouseExited(with: exitEvent)
            XCTAssertEqual(quitButton.contentTintColor, .secondaryLabelColor)
        }

        XCTAssertTrue(quitButton.sendAction(quitButton.action, to: quitButton.target))
        XCTAssertEqual(quitCount, 1)
    }
}
