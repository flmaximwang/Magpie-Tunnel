import AppKit
import MagpieTunnelCore

/// The log window: one text view fed by an incremental file reader, a source
/// picker for the application log or a single tunnel's log, and follow / pause /
/// search / copy controls.
///
/// Reading is incremental (`LogTailReader`), so the window keeps up with a log
/// that grows quickly, and it survives rotation: when the file is replaced the
/// reader starts over and the view is reset rather than showing the old mirror.
final class LogWindowController: NSWindowController, NSWindowDelegate {
    private let paths: TunnelPaths

    private let textView = NSTextView()
    private let sourcePopUp = NSPopUpButton()
    private let jumpToLatestButton = NSButton()
    private let copyButton = NSButton()
    private let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")
    private var scrollObserver: NSObjectProtocol?

    /// Tunnel names currently offered in the source picker, in the order the
    /// popup lists them (index 0 is the application log).
    private var sources: [String?] = [nil]
    /// The reader for the source on screen, plus the "must the display be
    /// cleared?" decision. Keeping the reader across `present` calls is what
    /// stops a reopened window from replaying the whole file (see
    /// `LogSourceFeed`).
    private var feed = LogSourceFeed()
    private var timer: Timer?
    /// Auto-scroll follows the newest output until the user scrolls up; the
    /// "跳到最新" button is the only way back.
    private var isFollowing = true
    /// Set while this class itself changes the text or scroll position, so a
    /// bounds notification caused by our own edit is not mistaken for a
    /// deliberate scroll by the user.
    private var isUpdatingContent = false
    private var searchQuery = ""
    /// A one-off confirmation ("已复制…", "已跳到最新") that must outlive the
    /// next tick. The label is rewritten from the statistics every 0.5 s, so a
    /// confirmation written straight into it would be erased before the user
    /// could read it; keeping it here lets `updateStatus` join the two instead.
    private var transientStatus: String?
    /// When the confirmation stops being part of the label. Past this date the
    /// label goes back to plain statistics without a separate dismissal timer:
    /// the tick that repaints the line is also the one that checks the date.
    private var transientDeadline: Date?
    /// How long a confirmation stays up. Long enough to be read across a few
    /// ticks, short enough not to become part of the permanent status.
    private let transientStatusDuration: TimeInterval = 3

    /// Hard cap on what the text view keeps, so a very chatty log cannot grow
    /// the window's memory without bound.
    private let maxDisplayedCharacters = 400_000

    init(paths: TunnelPaths) {
        self.paths = paths
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "隧道日志 — \(PanelState.appDisplayName)"
        window.minSize = NSSize(width: 560, height: 360)
        super.init(window: window)
        window.delegate = self
        buildContent()
        reloadSources()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - presentation

    /// Show the window. `tunnel` selects that tunnel's log when a tunnel with
    /// that name exists; nil means the application log.
    ///
    /// Behaviour this must keep (regression guard for the doubled-text bug):
    /// - presenting the same source twice appends only what arrived in between,
    ///   it never replays the whole file (the reader is kept, not rebuilt);
    /// - switching sources clears the view first, so only the new source shows;
    /// - an unchanged path whose file was rotated/truncated still clears, via
    ///   the `didReset` chunk from `tick()`.
    func present(tunnel: String?) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        reloadSources(selecting: tunnel)
        startTicking()
        // `reloadSources` → `switchSource` already read this source up to its
        // end; a second `tick()` here would only read an empty increment.
    }

    // MARK: - layout

    private func buildContent() {
        guard let window else { return }

        sourcePopUp.target = self
        sourcePopUp.action = #selector(sourceChanged(_:))
        sourcePopUp.translatesAutoresizingMaskIntoConstraints = false
        sourcePopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        jumpToLatestButton.title = "跳到最新"
        jumpToLatestButton.bezelStyle = .rounded
        jumpToLatestButton.target = self
        jumpToLatestButton.action = #selector(jumpToLatest(_:))
        jumpToLatestButton.toolTip = "恢复跟随，滚动到最新的一行。"
        jumpToLatestButton.isEnabled = false

        copyButton.title = "复制"
        copyButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copyContents(_:))
        copyButton.toolTip = "复制选中的内容；没有选中时复制当前显示的全部日志。"

        searchField.placeholderString = "搜索日志"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let sourceLabel = NSTextField(labelWithString: "日志来源")
        sourceLabel.font = .systemFont(ofSize: 11)
        sourceLabel.textColor = .secondaryLabelColor

        let topBar = NSStackView()
        topBar.orientation = .horizontal
        topBar.alignment = .centerY
        topBar.spacing = 8
        topBar.setViews([sourceLabel, sourcePopUp, jumpToLatestButton,
                         searchField, copyButton, NSView()], in: .leading)

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.visibleAreaMoved()
        }

        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 8
        contentStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        contentStack.setViews([topBar, scroll, statusLabel], in: .leading)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -24).isActive = true

        let root = NSView()
        root.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: root.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -24),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
        window.contentView = root
    }

    // MARK: - sources

    /// Re-read the configuration so a tunnel added in the config window appears
    /// in the picker without restarting the app.
    private func reloadSources(selecting tunnel: String? = nil) {
        var names: [String] = []
        if let text = try? String(contentsOfFile: paths.configPath, encoding: .utf8) {
            names = ConfigDocument.parse(text).targets.map(\.name)
        }
        let previous = selectedSource()
        sources = [nil] + names.map { Optional($0) }

        sourcePopUp.removeAllItems()
        sourcePopUp.addItem(withTitle: "应用日志")
        for name in names {
            sourcePopUp.addItem(withTitle: "隧道「\(name)」")
        }

        let wanted: String?
        if let tunnel, names.contains(tunnel) {
            wanted = tunnel
        } else if let previous, let index = sources.firstIndex(where: { $0 == previous }), index < sourcePopUp.numberOfItems {
            wanted = previous
        } else {
            wanted = nil
        }
        let index = sources.firstIndex(where: { $0 == wanted }) ?? 0
        sourcePopUp.selectItem(at: index)
        switchSource(to: sources[index])
    }

    private func selectedSource() -> String? {
        guard sourcePopUp.numberOfItems > 0, sourcePopUp.indexOfSelectedItem >= 0,
              sourcePopUp.indexOfSelectedItem < sources.count else { return nil }
        return sources[sourcePopUp.indexOfSelectedItem]
    }

    private func logPath(for tunnel: String?) -> String {
        guard let tunnel else { return paths.mainLogPath }
        return paths.targetLogPath(name: tunnel)
    }

    private func switchSource(to tunnel: String?) {
        let path = logPath(for: tunnel)
        // Only a genuinely different source gets a fresh reader and an empty
        // view. Presenting the same source again (window reopened, same tunnel
        // from the panel) keeps both, so the view is not refilled from offset 0.
        let didChangeSource = feed.bind(path: path)
        isUpdatingContent = true
        defer { isUpdatingContent = false }
        if didChangeSource {
            textView.string = ""
            clearHighlights()
            // A confirmation describes the previous source's contents; leaving
            // it in front of the new source's statistics would misattribute it.
            transientStatus = nil
            transientDeadline = nil
        }
        statusLabel.stringValue = tunnel.map { "正在读取隧道「\($0)」的日志" } ?? "正在读取应用日志"
        // A newly selected source opens on its newest output; for an unchanged
        // source this only appends what was written since the last read.
        tick()
        scrollToBottom()
    }

    // MARK: - ticking

    private func startTicking() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, target: self, selector: #selector(tickTimer(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func tickTimer(_ sender: Any?) { tick() }

    /// Read what appeared since the last read and append it.
    private func tick() {
        guard feed.isBound else { return }
        let chunk = feed.read()
        if chunk.didReset {
            // The file was replaced or truncated: the old mirror is not this
            // log any more, so clear it and show the new file from the top.
            textView.string = ""
            clearHighlights()
        }
        if !chunk.text.isEmpty {
            append(chunk.text)
        }
        updateStatus(for: chunk)
    }

    private func append(_ text: String) {
        isUpdatingContent = true
        defer { isUpdatingContent = false }
        let combined = textView.string + text
        if combined.count > maxDisplayedCharacters {
            let overflow = combined.count - maxDisplayedCharacters
            let trimmed = String(combined.dropFirst(overflow))
            textView.string = String(trimmed.drop(while: { $0 != "\n" }))
        } else {
            textView.string = combined
        }
        if isFollowing {
            scrollToBottom()
        }
        jumpToLatestButton.isEnabled = !isFollowing
        if !searchQuery.isEmpty {
            applySearch(preservingSelection: false)
        }
    }

    /// Scrolling is the only thing that stops auto-follow: once the visible
    /// area leaves the tail the view stays where the user put it, and the
    /// "跳到最新" button offers the way back.
    private func visibleAreaMoved() {
        guard isFollowing, !isUpdatingContent else { return }
        guard !isScrolledToBottom() else { return }
        isFollowing = false
        jumpToLatestButton.isEnabled = true
        updateStatus(for: .empty)
    }

    private func isScrolledToBottom() -> Bool {
        guard let scroll = textView.enclosingScrollView else { return true }
        let visible = scroll.contentView.bounds
        let contentHeight = textView.bounds.height
        return visible.maxY >= contentHeight - 24
    }

    private func scrollToBottom() {
        isUpdatingContent = true
        textView.scrollRangeToVisible(NSRange(location: (textView.string as NSString).length, length: 0))
        isUpdatingContent = false
    }

    // MARK: - status line

    /// Join a one-off confirmation and the standing statistics into the single
    /// label text.
    ///
    /// They have to coexist: the confirmation must sit in front so it is read
    /// first, and the statistics must stay behind it, because the ticker
    /// rewrites this line every half second and either piece of information
    /// would otherwise erase the other. Kept static and pure so the ordering
    /// rules can be tested without opening a window.
    static func statusText(statistics: [String], transient: String?, isTransientValid: Bool) -> String {
        var parts: [String] = []
        if isTransientValid,
           let transient,
           !transient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(transient)
        }
        parts.append(contentsOf: statistics)
        return parts.joined(separator: " · ")
    }

    /// True while the current confirmation has not reached its deadline.
    private func isTransientVisible(at date: Date) -> Bool {
        guard transientStatus != nil, let transientDeadline else { return false }
        return date < transientDeadline
    }

    /// Show a confirmation in front of the statistics for a few seconds, then
    /// let the statistics take the line back on their own. Used instead of
    /// writing the label directly: a direct write is undone by the next tick.
    private func showTransientStatus(_ text: String) {
        guard !text.isEmpty else { return }
        transientStatus = text
        transientDeadline = Date().addingTimeInterval(transientStatusDuration)
        updateStatus(for: .empty)
    }

    private func updateStatus(for chunk: LogChunk) {
        // The tick that repaints the line is also what retires an expired
        // confirmation, so no dismissal timer is needed — and a repaint can
        // never resurrect a stale "已复制" after its deadline.
        let now = Date()
        let showsTransient = isTransientVisible(at: now)
        if !showsTransient {
            transientStatus = nil
            transientDeadline = nil
        }

        var statistics: [String] = []
        let lines = textView.string.isEmpty ? 0 : textView.string.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        }
        statistics.append("\(lines) 行")
        if !isFollowing {
            statistics.append("已向上滚动，暂停自动跟随；点「跳到最新」恢复")
        }
        if chunk.didSkipHead {
            statistics.append("日志较长，只载入了最近的部分")
        }
        if chunk.didReset {
            statistics.append("日志已轮转，从头继续")
        }
        if !searchQuery.isEmpty {
            let matches = LogSearch.ranges(of: searchQuery, in: textView.string, limit: 500).count
            statistics.append(matches == 0 ? "没有匹配" : "\(matches) 处匹配")
        }
        statusLabel.stringValue = Self.statusText(statistics: statistics,
                                                  transient: transientStatus,
                                                  isTransientValid: showsTransient)
        // One colour for both kinds of text: the line must not repaint in a
        // different style when the confirmation expires.
        statusLabel.textColor = .secondaryLabelColor
    }

    // MARK: - actions

    @objc private func sourceChanged(_ sender: Any?) {
        switchSource(to: selectedSource())
    }

    /// Resume following after the user scrolled away from the newest line.
    @objc private func jumpToLatest(_ sender: Any?) {
        isUpdatingContent = true
        isFollowing = true
        scrollToBottom()
        isUpdatingContent = false
        jumpToLatestButton.isEnabled = false
        // Confirm through the transient slot: written straight into the label,
        // this would vanish on the next tick and the button would look inert.
        showTransientStatus("已跳到最新")
    }

    @objc private func copyContents(_ sender: Any?) {
        let selected = textView.selectedRange()
        let text = selected.length > 0
            ? (textView.string as NSString).substring(with: selected)
            : textView.string
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showTransientStatus(selected.length > 0 ? "已复制选中的内容" : "已复制当前显示的日志")
    }

    @objc private func searchChanged(_ sender: Any?) {
        searchQuery = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        applySearch(preservingSelection: true)
        updateStatus(for: .empty)
        if !searchQuery.isEmpty,
           let first = LogSearch.ranges(of: searchQuery, in: textView.string, limit: 1).first {
            // Jumping to a match is a deliberate move away from the tail: stop
            // following so the next append does not pull the view back down.
            isFollowing = false
            jumpToLatestButton.isEnabled = true
            textView.scrollRangeToVisible(first)
        }
    }

    // MARK: - search

    private func clearHighlights() {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
    }

    private func applySearch(preservingSelection: Bool) {
        clearHighlights()
        guard !searchQuery.isEmpty, let storage = textView.textStorage else { return }
        let ranges = LogSearch.ranges(of: searchQuery, in: textView.string)
        let selection = textView.selectedRange()
        for range in ranges {
            storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), range: range)
        }
        for range in ranges {
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
        }
        if preservingSelection, selection.length > 0 {
            textView.setSelectedRange(selection)
        }
    }

    // MARK: - window delegate

    func windowWillClose(_ notification: Notification) {
        // Closing the log window must not keep a polling timer alive.
        stopTicking()
        if let observer = scrollObserver {
            NotificationCenter.default.removeObserver(observer)
            scrollObserver = nil
        }
    }
}
