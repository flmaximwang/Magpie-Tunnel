import AppKit
import MagpieTunnelCore

/// Menu bar wiring for the status app. All content decisions live in
/// `MenuStateBuilder`/`StatusViewModel`; this layer only renders the state
/// into NSMenu and performs the global actions.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let viewModel: StatusViewModel
    private let refreshInterval: TimeInterval
    private var refreshTimer: Timer?
    private let daemon: DaemonController
    private var lastIconState: MenuIconState?

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
            button.setAccessibilityLabel("magpie 隧道")
        }
        rebuildMenu()
        let timer = Timer(timeInterval: refreshInterval, target: self,
                          selector: #selector(refreshMenu(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        // Single-app behaviour: opening the bundle also brings the tunnels up.
        daemon.startIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
    }

    // MARK: - menu building

    @objc private func refreshMenu(_ sender: Any?) {
        viewModel.refresh()
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let item = statusItem else { return }
        let state = viewModel.state
        if lastIconState != state.iconState {
            lastIconState = state.iconState
            statusItem?.button?.image = MenuIcon.image(for: state.iconState)
        }
        statusItem?.button?.setAccessibilityLabel(state.iconAccessibilityLabel)

        let menu = NSMenu()
        menu.autoenablesItems = false

        let summary = NSMenuItem(title: state.summaryTitle, action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        menu.addItem(.separator())

        for row in state.targetRows {
            let rowItem = NSMenuItem(title: row.title, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false

            let open = NSMenuItem(title: "打开 magpie", action: #selector(openMagpie(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = row.url
            open.isEnabled = row.isUp
            submenu.addItem(open)

            let copy = NSMenuItem(title: "复制链接", action: #selector(copyLink(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = row.url
            copy.isEnabled = row.isUp
            submenu.addItem(copy)

            let full = NSMenuItem(title: "完整 URL", action: nil, keyEquivalent: "")
            let urlItem = NSMenuItem(title: row.url, action: nil, keyEquivalent: "")
            urlItem.isEnabled = false
            submenu.addItem(full)
            submenu.addItem(urlItem)

            rowItem.submenu = submenu
            menu.addItem(rowItem)
        }

        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "刷新", action: #selector(refreshMenu(_:)), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)

        let edit = NSMenuItem(title: "编辑目标配置", action: #selector(editConfig(_:)), keyEquivalent: "")
        edit.target = self
        menu.addItem(edit)

        let logs = NSMenuItem(title: "打开隧道日志", action: #selector(openLog(_:)), keyEquivalent: "")
        logs.target = self
        menu.addItem(logs)

        let restart = NSMenuItem(title: "重启隧道守护", action: #selector(restartDaemon(_:)), keyEquivalent: "")
        restart.target = self
        menu.addItem(restart)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出菜单栏(隧道继续跑)", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
    }

    // MARK: - actions

    @objc private func openMagpie(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String, let target = URL(string: url) else { return }
        NSWorkspace.shared.open(target)
    }

    @objc private func copyLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc private func editConfig(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(URL(fileURLWithPath: viewModel.paths.configPath))
    }

    @objc private func openLog(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(URL(fileURLWithPath: viewModel.paths.mainLogPath))
    }

    /// Ask the bundled daemon to respawn; the menu bar app itself always stays
    /// up so the user keeps seeing status while tunnels restart.
    @objc private func restartDaemon(_ sender: NSMenuItem) {
        daemon.restart()
        refreshMenu(nil)
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}
