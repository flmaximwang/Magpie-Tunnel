import AppKit
import MagpieTunnelCore

/// What the panel is allowed to do. Kept as closures so the view has no
/// knowledge of the app delegate, windows or the daemon.
struct PanelActions {
    let openTunnel: (String) -> Void
    let copyTunnel: (String) -> Void
    let openConfiguration: () -> Void
    let openLogs: () -> Void
    /// "添加隧道" from the empty state; enters the new-tunnel form.
    let addTunnel: () -> Void
    /// "修正配置" from the broken-configuration state.
    let fixConfiguration: () -> Void
    let restartTunnels: () -> Void
    let quit: () -> Void
}

/// A button that runs a closure, so the panel code has no selector plumbing and
/// rebuilt rows always capture the URL they were built with. Supports optional
/// normal and hover tint colors using an `NSTrackingArea`.
final class ClosureButton: NSButton {
    private let handler: () -> Void
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false

    var normalTintColor: NSColor? {
        didSet { updateTintColor() }
    }

    var hoverTintColor: NSColor? {
        didSet {
            if hoverTintColor == nil {
                isHovered = false
            }
            updateTintColor()
            updateTrackingAreas()
        }
    }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled {
                isHovered = false
            }
            updateTintColor()
        }
    }

    init(title: String,
         font: NSFont,
         enabled: Bool = true,
         normalTintColor: NSColor? = nil,
         hoverTintColor: NSColor? = nil,
         handler: @escaping () -> Void) {
        self.handler = handler
        self.normalTintColor = normalTintColor
        self.hoverTintColor = hoverTintColor
        super.init(frame: .zero)
        self.title = title
        self.font = font
        configureCommon(enabled: enabled)
    }

    init(image: NSImage?,
         enabled: Bool = true,
         normalTintColor: NSColor? = nil,
         hoverTintColor: NSColor? = nil,
         handler: @escaping () -> Void) {
        self.handler = handler
        self.normalTintColor = normalTintColor
        self.hoverTintColor = hoverTintColor
        super.init(frame: .zero)
        self.image = image
        self.imagePosition = .imageOnly
        self.imageScaling = .scaleProportionallyDown
        configureCommon(enabled: enabled)
    }

    private func configureCommon(enabled: Bool) {
        self.bezelStyle = .inline
        self.isBordered = false
        self.target = self
        self.action = #selector(run)
        self.isEnabled = enabled
        self.setContentHuggingPriority(.required, for: .horizontal)
        self.setContentCompressionResistancePriority(.required, for: .horizontal)
        updateTintColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTrackingArea {
            removeTrackingArea(existing)
            hoverTrackingArea = nil
        }
        guard hoverTintColor != nil else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, isHovered {
            isHovered = false
            updateTintColor()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard isEnabled, hoverTintColor != nil else { return }
        isHovered = true
        updateTintColor()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard isHovered else { return }
        isHovered = false
        updateTintColor()
    }

    private func updateTintColor() {
        if isHovered, isEnabled, let hoverTintColor {
            contentTintColor = hoverTintColor
        } else if let normalTintColor {
            contentTintColor = normalTintColor
        }
    }

    @objc private func run() { handler() }
}

/// The compact panel shown from the menu-bar item.
///
/// One header line with the overview and a restart button, one row per tunnel
/// in configuration order, and a footer with the two window entries plus a
/// "退出" button. Actions that only make sense for a live tunnel are disabled
/// unless it is connected.
final class PanelViewController: NSViewController {
    private let viewModel: StatusViewModel
    private let actions: PanelActions

    private let headerTitleLabel = NSTextField(labelWithString: "")
    private let headerSubtitleLabel = NSTextField(labelWithString: "")
    private let headerIconView = NSImageView()
    private(set) var restartButton: ClosureButton?
    private let rowsStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let emptyButtonHost = NSStackView()
    private let footerStack = NSStackView()
    private(set) var quitButton: ClosureButton?

    static let panelWidth: CGFloat = 360

    /// The state the body was last built from. `nil` until the first refresh,
    /// so the first call always builds.
    private var lastRenderedState: PanelState?
    /// Collapses a burst of refreshes into a single deferred measurement.
    private var isResizeScheduled = false

    init(viewModel: StatusViewModel, actions: PanelActions) {
        self.viewModel = viewModel
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: PanelViewController.panelWidth, height: 120))

        headerIconView.image = MenuIcon.image(for: .degraded)
        headerIconView.imageScaling = .scaleProportionallyDown
        headerIconView.setContentHuggingPriority(.required, for: .horizontal)
        headerIconView.translatesAutoresizingMaskIntoConstraints = false

        headerTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        headerTitleLabel.textColor = .labelColor
        headerTitleLabel.lineBreakMode = .byTruncatingTail
        headerTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        headerSubtitleLabel.font = .systemFont(ofSize: 11)
        headerSubtitleLabel.textColor = .secondaryLabelColor
        headerSubtitleLabel.lineBreakMode = .byTruncatingTail
        headerSubtitleLabel.maximumNumberOfLines = 2
        headerSubtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let headerText = NSStackView(views: [headerTitleLabel, headerSubtitleLabel])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 1
        headerText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let restartSymbol = NSImage(systemSymbolName: "arrow.clockwise",
                                    accessibilityDescription: "重启全部隧道")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        let restart = ClosureButton(image: restartSymbol,
                                    normalTintColor: .secondaryLabelColor) { [unowned self] in
            self.actions.restartTunnels()
        }
        restart.toolTip = "重启全部隧道 · 现有连接会短暂中断"
        restart.setAccessibilityLabel("重启全部隧道")
        restart.translatesAutoresizingMaskIntoConstraints = false
        self.restartButton = restart

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [headerIconView, headerText, headerSpacer, restart])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.setHuggingPriority(.defaultLow, for: .horizontal)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 3
        emptyLabel.isHidden = true

        emptyButtonHost.orientation = .horizontal
        emptyButtonHost.alignment = .leading
        emptyButtonHost.spacing = 0
        emptyButtonHost.isHidden = true

        let body = NSStackView(views: [rowsStack, emptyLabel, emptyButtonHost])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 6

        let configButton = ClosureButton(title: "隧道配置", font: .systemFont(ofSize: 12)) { [unowned self] in
            self.actions.openConfiguration()
        }
        let logButton = ClosureButton(title: "隧道日志", font: .systemFont(ofSize: 12)) { [unowned self] in
            self.actions.openLogs()
        }
        let quit = ClosureButton(title: "退出",
                                 font: .systemFont(ofSize: 12),
                                 normalTintColor: .secondaryLabelColor,
                                 hoverTintColor: .systemRed) { [unowned self] in
            self.actions.quit()
        }
        self.quitButton = quit

        footerStack.setViews([configButton, logButton, NSView(), quit], in: .leading)
        footerStack.orientation = .horizontal
        footerStack.alignment = .centerY
        footerStack.spacing = 14

        let separatorTop = NSBox()
        separatorTop.boxType = .separator
        let separatorBottom = NSBox()
        separatorBottom.boxType = .separator

        let content = NSStackView(views: [header, separatorTop, body, separatorBottom, footerStack])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 8, right: 14)
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            headerIconView.widthAnchor.constraint(equalToConstant: 16),
            headerIconView.heightAnchor.constraint(equalToConstant: 16),
            restart.widthAnchor.constraint(equalToConstant: 22),
            restart.heightAnchor.constraint(equalToConstant: 22),
            root.widthAnchor.constraint(equalToConstant: PanelViewController.panelWidth),
            header.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
            body.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
            footerStack.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
        ])

        view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    /// Rebuild from the current view model. Called when the panel opens and by
    /// the app's refresh timer while it is open.
    ///
    /// The body is only rebuilt when the state actually changed. `PanelState`
    /// is `Equatable`, so the usual 2-second tick — same tunnels, same
    /// statuses — costs two label assignments and no view churn at all. That
    /// matters here: every rebuild invalidates the whole popover's layout, and
    /// the panel used to do it on every tick.
    func refresh() {
        guard isViewLoaded else { return }
        let state = viewModel.refresh()
        headerTitleLabel.stringValue = PanelState.appDisplayName
        headerSubtitleLabel.stringValue = state.subtitle
        headerIconView.image = MenuIcon.image(for: state.iconState)
        headerIconView.toolTip = state.iconAccessibilityLabel

        let canRestart = state.canRestartTunnels
        restartButton?.isEnabled = canRestart
        restartButton?.normalTintColor = canRestart ? .secondaryLabelColor : .tertiaryLabelColor

        guard state != lastRenderedState else { return }
        lastRenderedState = state
        rebuildBody(for: state)
        scheduleResizeToFit()
    }

    private func rebuildBody(for state: PanelState) {
        for child in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        for child in emptyButtonHost.arrangedSubviews {
            emptyButtonHost.removeArrangedSubview(child)
            child.removeFromSuperview()
        }

        if let message = state.emptyState.message {
            emptyLabel.stringValue = message
            emptyLabel.isHidden = false
            if let actionTitle = state.emptyState.actionTitle {
                let emptyKind = state.emptyState
                let button = ClosureButton(title: actionTitle,
                                           font: .systemFont(ofSize: 12, weight: .medium)) { [unowned self] in
                    switch emptyKind {
                    case .noTunnels: self.actions.addTunnel()
                    case .brokenConfiguration, .unreadableConfiguration: self.actions.fixConfiguration()
                    case .none: break
                    }
                }
                emptyButtonHost.addArrangedSubview(button)
                emptyButtonHost.isHidden = false
            } else {
                emptyButtonHost.isHidden = true
            }
        } else {
            emptyLabel.isHidden = true
            emptyButtonHost.isHidden = true
        }

        for row in state.rows {
            rowsStack.addArrangedSubview(TunnelRowView(row: row, actions: actions))
        }
    }

    /// Ask for the panel height on the next turn of the run loop instead of
    /// reading `fittingSize` right here.
    ///
    /// `refresh()` runs from `viewWillAppear` and from the app's timer, and
    /// AppKit may call it while a layout pass on this view hierarchy is still
    /// in progress. Calling `layoutSubtreeIfNeeded()` at that point re-enters
    /// AppKit's layout and logs "It's not legal to call
    /// -layoutSubtreeIfNeeded on a view which is already being laid out"
    /// (reproduced with that exact call inside a `layout()` override).
    /// Measuring on the next main-queue turn instead means no layout pass is
    /// in flight, and the freshly rebuilt body is already in place, so the
    /// height is both safe and correct. The deferred block is idempotent, so a
    /// burst of changes collapses into one measurement.
    private func scheduleResizeToFit() {
        guard !isResizeScheduled else { return }
        isResizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isResizeScheduled = false
            self.resizeToFit()
        }
    }

    /// Measure the content and publish it as `preferredContentSize`. Called
    /// only from the deferred block above, never during a layout pass.
    private func resizeToFit() {
        let fitting = view.fittingSize
        preferredContentSize = NSSize(width: PanelViewController.panelWidth,
                                      height: max(80, fitting.height))
    }
}

/// One tunnel row: name and actions on the first line, state and port on the
/// second. Two lines instead of one keeps the labels readable at panel width
/// without shortening them into ambiguity.
final class TunnelRowView: NSView {
    private static let dotSize: CGFloat = 7

    init(row: TunnelRow, actions: PanelActions) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let dot = NSView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = TunnelRowView.dotSize / 2
        dot.layer?.backgroundColor = TunnelRowView.color(for: row.state).cgColor
        dot.widthAnchor.constraint(equalToConstant: TunnelRowView.dotSize).isActive = true
        dot.heightAnchor.constraint(equalToConstant: TunnelRowView.dotSize).isActive = true

        let nameLabel = NSTextField(labelWithString: row.name)
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let url = row.url
        let openButton = ClosureButton(title: "打开 Magpie",
                                       font: .systemFont(ofSize: 11),
                                       enabled: row.isConnectable) { actions.openTunnel(url) }
        let copyButton = ClosureButton(title: "复制链接",
                                       font: .systemFont(ofSize: 11),
                                       enabled: row.isConnectable) { actions.copyTunnel(url) }
        for button in [openButton, copyButton] {
            button.contentTintColor = row.isConnectable ? .controlAccentColor : .tertiaryLabelColor
        }

        let topLine = NSStackView(views: [dot, nameLabel, NSView(), openButton, copyButton])
        topLine.orientation = .horizontal
        topLine.alignment = .centerY
        topLine.spacing = 6
        topLine.setCustomSpacing(10, after: nameLabel)

        let stateLabel = NSTextField(labelWithString: row.state.label)
        stateLabel.font = .systemFont(ofSize: 11)
        stateLabel.textColor = TunnelRowView.color(for: row.state)
        stateLabel.setContentHuggingPriority(.required, for: .horizontal)

        let detailLabel = NSTextField(labelWithString: row.state.detail.map { "· \($0)" } ?? "")
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let portLabel = NSTextField(labelWithString: row.portText)
        portLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        portLabel.textColor = .secondaryLabelColor
        portLabel.setContentHuggingPriority(.required, for: .horizontal)

        let bottomLine = NSStackView(views: [stateLabel, detailLabel, NSView(), portLabel])
        bottomLine.orientation = .horizontal
        bottomLine.alignment = .centerY
        bottomLine.spacing = 6

        let lines = NSStackView(views: [topLine, bottomLine])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 2
        lines.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        lines.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lines)

        NSLayoutConstraint.activate([
            lines.leadingAnchor.constraint(equalTo: leadingAnchor),
            lines.trailingAnchor.constraint(equalTo: trailingAnchor),
            lines.topAnchor.constraint(equalTo: topAnchor),
            lines.bottomAnchor.constraint(equalTo: bottomAnchor),
            topLine.widthAnchor.constraint(equalTo: lines.widthAnchor, constant: -0),
            bottomLine.widthAnchor.constraint(equalTo: lines.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func color(for state: TunnelConnectionState) -> NSColor {
        switch state {
        case .connected: return .systemGreen
        case .connecting: return .systemOrange
        case .disconnected: return .systemRed
        case .unknown: return .systemGray
        }
    }
}
