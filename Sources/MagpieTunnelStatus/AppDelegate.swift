import AppKit
import MagpieTunnelCore

/// Menu bar wiring for the status app. All content decisions live in
/// `PanelStateBuilder`/`StatusViewModel`; this layer renders the status item,
/// owns the panel popover and the two reusable windows, and runs the app +
/// daemon lifecycle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let viewModel: StatusViewModel
    private let refreshInterval: TimeInterval
    private var refreshTimer: Timer?
    private let daemon: DaemonController
    private var lastIconState: MenuIconState?
    private var popover: NSPopover?
    private var panel: PanelViewController?

    private var configWindow: ConfigWindowController?
    private var logWindow: LogWindowController?

    init(viewModel: StatusViewModel, refreshInterval: TimeInterval, daemon: DaemonController) {
        self.viewModel = viewModel
        self.refreshInterval = refreshInterval
        self.daemon = daemon
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.image = MenuIcon.image(for: .degraded)
            button.setAccessibilityLabel(PanelState.appDisplayName)
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.sendAction(on: [.leftMouseUp])
        }

        refreshIcon()

        let timer = Timer(timeInterval: refreshInterval, target: self,
                          selector: #selector(tick(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        // The app is the sole owner of the daemon and every tunnel: opening it
        // starts the tunnels from the saved configuration.
        daemon.startIfNeeded()
    }

    /// Closing the last window must not quit the app; the menu bar stays.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quitting stops the daemon (which stops every ssh child). The confirmation
    /// happens in `terminateFromUI`; this is the path AppKit takes for a
    /// system-initiated quit (logout, `osascript quit`).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminatingAfterConfirmation else { return .terminateNow }
        // System-initiated quit still deserves the same "tunnels will disconnect"
        // confirmation, and the same chance to save a pending draft.
        confirmQuit()
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        // Belt and braces: the daemon also watches this PID, but a clean quit
        // must leave nothing behind even if that watchdog raced us.
        daemon.stopSynchronously()
    }

    // MARK: - status item + panel

    @objc private func tick(_ sender: Any?) {
        refreshIcon()
        if let popover, popover.isShown {
            panel?.refresh()
        }
    }

    private func refreshIcon() {
        let state = viewModel.refresh()
        if lastIconState != state.iconState {
            lastIconState = state.iconState
            statusItem?.button?.image = MenuIcon.image(for: state.iconState)
        }
        statusItem?.button?.setAccessibilityLabel(state.iconAccessibilityLabel)
    }

    @objc private func togglePanel(_ sender: Any?) {
        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let button = statusItem?.button else { return }
        let controller = PanelViewController(viewModel: viewModel, actions: panelActions())
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover = popover
        self.panel = controller
    }

    private func panelActions() -> PanelActions {
        PanelActions(
            openTunnel: { url in
                guard let target = URL(string: url) else { return }
                NSWorkspace.shared.open(target)
            },
            copyTunnel: { url in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            },
            openConfiguration: { [weak self] in self?.showConfigurationWindow() },
            openLogs: { [weak self] in self?.showLogWindow(tunnel: nil) },
            addTunnel: { [weak self] in self?.showConfigurationWindow(startWithNewTunnel: true) },
            fixConfiguration: { [weak self] in self?.showConfigurationWindow() },
            restartTunnels: { [weak self] in self?.confirmRestartTunnels() },
            quit: { [weak self] in self?.confirmQuit() }
        )
    }

    // MARK: - confirmation dialogs

    private func confirmRestartTunnels() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "重启全部隧道？"
        alert.informativeText = "现有连接会短暂中断，随后自动恢复。"
        alert.addButton(withTitle: "重启")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            daemon.restart()
            refreshIcon()
            panel?.refresh()
        }
    }

    private var isTerminatingAfterConfirmation = false

    /// The quit dialog. States plainly that every tunnel will disconnect, and
    /// offers to save a pending configuration draft in the same dialog.
    private func confirmQuit() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "退出 \(PanelState.appDisplayName)？"
        alert.informativeText = "退出后守护进程和所有隧道连接都会结束。"

        let hasDraft = configWindow?.hasUnsavedChanges == true
        if hasDraft {
            alert.informativeText += "隧道的配置改动还没有保存。"
            alert.addButton(withTitle: "保存并退出")
            alert.addButton(withTitle: "放弃更改并退出")
            alert.addButton(withTitle: "取消")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if let failure = configWindow?.saveForQuit() {
                    presentError("无法保存配置", failure)
                    return
                }
                configWindow?.discardDraftForQuit()
            case .alertSecondButtonReturn:
                configWindow?.discardDraftForQuit()
            default:
                return
            }
        } else {
            alert.addButton(withTitle: "退出")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        performTermination()
    }

    private func performTermination() {
        isTerminatingAfterConfirmation = true
        daemon.stopSynchronously()
        NSApp.terminate(nil)
    }

    private func presentError(_ headline: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = headline
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - windows

    private func showConfigurationWindow(startWithNewTunnel: Bool = false) {
        popover?.performClose(nil)
        let window: ConfigWindowController
        if let existing = configWindow {
            window = existing
        } else {
            window = ConfigWindowController(paths: viewModel.paths,
                                            daemon: daemon,
                                            onSaved: { [weak self] in
                self?.refreshIcon()
                self?.panel?.refresh()
            })
            configWindow = window
        }
        window.present(startWithNewTunnel: startWithNewTunnel)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showLogWindow(tunnel: String?) {
        popover?.performClose(nil)
        let window: LogWindowController
        if let existing = logWindow {
            window = existing
        } else {
            window = LogWindowController(paths: viewModel.paths)
            logWindow = window
        }
        window.present(tunnel: tunnel)
        NSApp.activate(ignoringOtherApps: true)
    }
}
