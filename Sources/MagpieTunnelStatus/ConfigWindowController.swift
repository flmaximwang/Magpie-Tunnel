import AppKit
import MagpieTunnelCore

/// The configuration window: a list of tunnels on the left, a form on the
/// right, one "保存并应用" button at the bottom.
///
/// Every edit stays in the draft until that button is pressed. Saving validates
/// the whole draft, writes it once, and then asks the daemon to reload — the
/// two outcomes are reported separately, because a saved file and an applied
/// configuration are not the same thing.
final class ConfigWindowController: NSWindowController, NSWindowDelegate {
    private let model: ConfigEditorModel
    private let daemon: DaemonController
    private let onSaved: () -> Void

    private let tableView = NSTableView()
    private let emptyListLabel = NSTextField(labelWithString: "尚未配置隧道")
    private let statusLabel = NSTextField(labelWithString: "")
    private let conflictBanner = NSStackView()
    private let undoDeleteButton = NSButton()

    // form fields
    private let nameField = NSTextField()
    private let localPortField = NSTextField()
    private let sshTargetField = NSTextField()
    private let remotePortField = NSTextField()
    private let webKeyField = NSSecureTextField()
    private let showKeyButton = NSButton()
    private let keyVisibleField = NSTextField()
    private var keyIsVisible = false

    private let formStack = NSStackView()
    private var problemLabels: [NSTextField] = []
    private let brokenLineStack = NSStackView()
    private let brokenLineField = NSTextField()
    private let formTitleLabel = NSTextField(labelWithString: "")
    private let deleteButton = NSButton()

    private var selectedRowID: UUID?
    private var saveButton: NSButton!
    private var pendingNewRowID: UUID?
    /// Bumped on every reconciliation. A daemon acknowledgement started under
    /// an older generation is dropped: its "已应用" describes a file the window
    /// may no longer be showing, and would otherwise land on the status line
    /// after a reopen — the exact leftover this reconciliation clears.
    private var presentationGeneration = 0

    init(paths: TunnelPaths, daemon: DaemonController, onSaved: @escaping () -> Void) {
        self.model = ConfigEditorModel(path: paths.configPath)
        self.daemon = daemon
        self.onSaved = onSaved

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "隧道配置 — \(PanelState.appDisplayName)"
        window.minSize = NSSize(width: 640, height: 420)
        super.init(window: window)
        window.delegate = self
        buildContent()
        reloadList()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - presentation

    /// What `present()` must do to the window's state, decided before anything
    /// on screen is touched.
    ///
    /// The window outlives its visibility: the controller (and its draft) stays
    /// alive after the red button closes it, while the daemon and any outside
    /// editor keep changing the file. Re-showing the window therefore has to
    /// reconcile the two, and the three possible outcomes are enumerated here
    /// so the rule is testable without AppKit.
    enum PresentationAction: Equatable {
        /// Unsaved edits, and the file changed underneath them: keep the draft
        /// and warn, never reload over it.
        case keepDraftConflict
        /// Unsaved edits, file unchanged: keep the draft, only drop the status
        /// line left over from the previous presentation.
        case keepDraftClean
        /// Nothing unsaved: adopt the file on disk.
        case reloadFromDisk
    }

    static func presentationAction(hasUnsavedChanges: Bool, isSnapshotStale: Bool) -> PresentationAction {
        guard hasUnsavedChanges else {
            // With no draft to lose, disk always wins: the window has to show
            // what the daemon is actually running, including tunnels added
            // outside while it was closed. There is no conflict to resolve when
            // the in-memory copy is not something the user typed.
            return .reloadFromDisk
        }
        // A draft is the user's work, so it survives even a changed file. The
        // conflict is only worth a banner when the file really is different
        // from the snapshot the draft was built on.
        return isSnapshotStale ? .keepDraftConflict : .keepDraftClean
    }

    /// The status line each presentation branch leaves behind.
    ///
    /// A pure mapping next to the decision, so the wording is testable without
    /// a window. What matters is that every branch replaces the line rather
    /// than keeping it: the label outlives the window, and a "已应用" left from
    /// an earlier presentation would otherwise describe an outcome that has
    /// nothing to do with the file as it stands now.
    static func presentationStatusText(for action: PresentationAction) -> String {
        switch action {
        case .keepDraftConflict:
            return "配置文件已在别处被修改，草稿保留在这里"
        case .keepDraftClean:
            return unsavedStatusText
        case .reloadFromDisk:
            return ""
        }
    }

    /// The one wording for "the draft has edits that are not on disk", shared by
    /// `updateSaveButton` and the presentation reconciliation so the two cannot
    /// drift apart.
    static let unsavedStatusText = "有未保存的改动"

    /// Whether re-presenting has to reconcile at all.
    ///
    /// A window that is already on screen is only being brought forward: the
    /// panel's entry fires again on a repeated click, and the spec asks for
    /// exactly that. Reconciling there would reload the list under the user and
    /// rewrite a status line that belongs to this live session (a broken line's
    /// repair text, for instance, reaches the model only through "应用这一行",
    /// so a reload would blank it). The reconciliation is for the case it was
    /// written for: the window was closed — or shrunk to the Dock, which is how
    /// a user parks it — while the app kept running, and the draft and the file
    /// may now disagree.
    static func needsPresentationReconciliation(isVisible: Bool, isMiniaturized: Bool) -> Bool {
        !isVisible || isMiniaturized
    }

    func present() {
        guard let window else { return }

        guard Self.needsPresentationReconciliation(isVisible: window.isVisible,
                                                   isMiniaturized: window.isMiniaturized) else {
            // Already on screen: this is a repeated click from the panel, so
            // only raise it. Reloading here would re-read the file under the
            // user's hands and could blank the form — a broken line's repair
            // text reaches the model only through "应用这一行".
            window.makeKeyAndOrderFront(nil)
            return
        }

        // Any acknowledgement still in flight belongs to the presentation that
        // started it. Bumping the counter makes its completion a no-op, so a
        // late "已应用" cannot land on a window that has moved on to a newer
        // file (and cannot overwrite the conflict status set just below).
        presentationGeneration += 1

        // Decide before anything is visible. Everything here is state-only: no
        // write, no modal dialog and no first responder, because presenting a
        // window must never apply a draft or ask the user to resolve something
        // they did not just do.
        let action = Self.presentationAction(hasUnsavedChanges: model.hasUnsavedChanges(),
                                             isSnapshotStale: model.snapshot.isStale())
        switch action {
        case .keepDraftConflict:
            // The draft is kept and the banner explains why saving will not
            // proceed; only the user's own "重新载入" throws it away.
            conflictBanner.isHidden = false
        case .keepDraftClean:
            // List and draft stay exactly as they were — there is nothing on
            // disk to adopt, and nothing here may touch the draft. The banner
            // is hidden because the snapshot still matches the file.
            conflictBanner.isHidden = true
        case .reloadFromDisk:
            // Reachable only with no draft of the user's to lose, so adopting
            // the file is safe: that is what makes a tunnel added outside the
            // app — the daemon starts it, the panel lists it — show up here.
            reloadFromDiskForPresentation()
            conflictBanner.isHidden = true
        }
        // Every branch replaces the line instead of keeping it: the label
        // outlives the window, so a "已应用" left from an earlier presentation
        // would describe an outcome that no longer says anything about the file.
        statusLabel.stringValue = Self.presentationStatusText(for: action)
        statusLabel.textColor = action == .keepDraftConflict ? .systemOrange : .secondaryLabelColor

        showWindow(nil)
        // Bringing a parked (Dock-minimized) window back is part of presenting
        // it; `makeKeyAndOrderFront` alone would leave it in the Dock.
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    /// The row to re-select after a reload, matched by tunnel name.
    ///
    /// Row ids are not reusable across a reload: `ConfigEditorModel.reload()`
    /// rebuilds the draft, so every row gets a fresh id. Names are the stable
    /// identity the user sees, so the tunnel they were editing stays selected
    /// when it still exists and the list falls back to its usual first row
    /// otherwise.
    static func rowID(named name: String?, in rows: [EditorRow]) -> UUID? {
        guard let name else { return nil }
        return rows.first { !$0.isBroken && $0.title == name }?.id
    }

    /// Re-read the file for a draft-free window, keeping the selected tunnel
    /// across the reload when it still exists.
    private func reloadFromDiskForPresentation() {
        let previousName = selectedRowID.flatMap { id in
            model.rows.first { $0.id == id && !$0.isBroken }?.title
        }
        model.reload()
        // Clear before `reloadList` so the table's selection notification cannot
        // write the old form into the freshly loaded draft.
        selectedRowID = nil
        reloadList(selecting: Self.rowID(named: previousName, in: model.rows))
    }

    /// Entry from the panel's empty state: select the new row so the user lands
    /// directly in the form.
    func present(startWithNewTunnel: Bool) {
        present()
        if startWithNewTunnel {
            addTunnel(nil)
        }
    }

    var hasUnsavedChanges: Bool { model.hasUnsavedChanges() }

    // MARK: - layout

    private func buildContent() {
        guard let window else { return }

        let listColumn = NSStackView()
        listColumn.orientation = .vertical
        listColumn.alignment = .leading
        listColumn.spacing = 6

        tableView.headerView = nil
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        // The list cell carries two lines (12pt name + 10pt detail). AppKit's
        // `.default` row size forces every row back to 24 points, which is
        // shorter than the cell, so the detail line would overlap the next
        // row — invisible only while the rows failed to draw at all. A custom
        // row size of 34 points fits both lines with the usual row padding.
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 34
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.delegate = self
        tableView.dataSource = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tunnel"))
        column.title = "隧道"
        column.width = 200
        tableView.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let listButtons = NSStackView()
        listButtons.orientation = .horizontal
        listButtons.spacing = 8
        let addButton = NSButton(title: "新增", target: self, action: #selector(addTunnel(_:)))
        addButton.bezelStyle = .rounded
        deleteButton.title = "删除"
        deleteButton.target = self
        deleteButton.action = #selector(deleteTunnel(_:))
        deleteButton.bezelStyle = .rounded
        undoDeleteButton.title = "撤销删除"
        undoDeleteButton.target = self
        undoDeleteButton.action = #selector(undoDelete(_:))
        undoDeleteButton.bezelStyle = .inline
        undoDeleteButton.isBordered = false
        undoDeleteButton.font = .systemFont(ofSize: 11)
        undoDeleteButton.isHidden = true
        listButtons.setViews([addButton, deleteButton, undoDeleteButton, NSView()], in: .leading)

        emptyListLabel.textColor = .secondaryLabelColor
        emptyListLabel.font = .systemFont(ofSize: 12)
        emptyListLabel.isHidden = true

        listColumn.setViews([scroll, emptyListLabel, listButtons], in: .leading)
        listColumn.setCustomSpacing(10, after: scroll)

        // MARK: form

        formTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        formTitleLabel.textColor = .labelColor

        nameField.placeholderString = "例如 TC2C4G2026"
        localPortField.placeholderString = "3430"
        sshTargetField.placeholderString = "user@host"
        remotePortField.placeholderString = "443"
        webKeyField.placeholderString = "可留空"
        for field in [nameField, localPortField, sshTargetField, remotePortField, webKeyField] {
            field.font = .systemFont(ofSize: 12)
            field.controlSize = .regular
        }

        showKeyButton.title = "显示密钥"
        showKeyButton.bezelStyle = .inline
        showKeyButton.isBordered = false
        showKeyButton.font = .systemFont(ofSize: 11)
        showKeyButton.target = self
        showKeyButton.action = #selector(toggleKeyVisibility(_:))
        keyVisibleField.isHidden = true
        keyVisibleField.font = .systemFont(ofSize: 12)

        var fieldStacks: [NSView] = []
        func addField(_ title: String, _ control: NSView, hint: String? = nil) {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 3
            stack.addArrangedSubview(label)
            stack.addArrangedSubview(control)
            control.translatesAutoresizingMaskIntoConstraints = false
            control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            if let hint {
                let hintLabel = NSTextField(labelWithString: hint)
                hintLabel.font = .systemFont(ofSize: 10)
                hintLabel.textColor = .tertiaryLabelColor
                stack.addArrangedSubview(hintLabel)
            }
            fieldStacks.append(stack)
        }

        addField("名称", nameField)
        let portsRow = NSStackView()
        portsRow.orientation = .horizontal
        portsRow.spacing = 10
        portsRow.distribution = .fillEqually
        let localStack = NSStackView()
        localStack.orientation = .vertical
        localStack.alignment = .leading
        localStack.spacing = 3
        let localLabel = NSTextField(labelWithString: "本机端口")
        localLabel.font = .systemFont(ofSize: 11)
        localLabel.textColor = .secondaryLabelColor
        localStack.addArrangedSubview(localLabel)
        localStack.addArrangedSubview(localPortField)
        let remoteStack = NSStackView()
        remoteStack.orientation = .vertical
        remoteStack.alignment = .leading
        remoteStack.spacing = 3
        let remoteLabel = NSTextField(labelWithString: "远端端口")
        remoteLabel.font = .systemFont(ofSize: 11)
        remoteLabel.textColor = .secondaryLabelColor
        remoteStack.addArrangedSubview(remoteLabel)
        remoteStack.addArrangedSubview(remotePortField)
        portsRow.addArrangedSubview(localStack)
        portsRow.addArrangedSubview(remoteStack)
        fieldStacks.append(portsRow)

        addField("SSH 目标", sshTargetField)
        let keyRow = NSStackView()
        keyRow.orientation = .vertical
        keyRow.alignment = .leading
        keyRow.spacing = 3
        let keyLabel = NSTextField(labelWithString: "Web 密钥")
        keyLabel.font = .systemFont(ofSize: 11)
        keyLabel.textColor = .secondaryLabelColor
        keyRow.addArrangedSubview(keyLabel)
        keyRow.addArrangedSubview(webKeyField)
        webKeyField.translatesAutoresizingMaskIntoConstraints = false
        webKeyField.widthAnchor.constraint(equalTo: keyRow.widthAnchor).isActive = true
        keyRow.addArrangedSubview(keyVisibleField)
        keyVisibleField.translatesAutoresizingMaskIntoConstraints = false
        keyVisibleField.widthAnchor.constraint(equalTo: keyRow.widthAnchor).isActive = true
        keyRow.addArrangedSubview(showKeyButton)
        fieldStacks.append(keyRow)

        let problemStack = NSStackView()
        problemStack.orientation = .vertical
        problemStack.alignment = .leading
        problemStack.spacing = 2
        for _ in 0..<4 {
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .systemRed
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 2
            label.isHidden = true
            problemStack.addArrangedSubview(label)
            problemLabels.append(label)
        }

        brokenLineStack.orientation = .vertical
        brokenLineStack.alignment = .leading
        brokenLineStack.spacing = 4
        let brokenHint = NSTextField(labelWithString: "这一行无法解析。修改原文使其符合 name|本机端口|ssh|远端端口|密钥 的格式：")
        brokenHint.font = .systemFont(ofSize: 11)
        brokenHint.textColor = .secondaryLabelColor
        brokenHint.lineBreakMode = .byWordWrapping
        brokenHint.maximumNumberOfLines = 3
        brokenLineStack.addArrangedSubview(brokenHint)
        brokenLineField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        brokenLineStack.addArrangedSubview(brokenLineField)
        brokenLineField.translatesAutoresizingMaskIntoConstraints = false
        brokenLineField.widthAnchor.constraint(equalTo: brokenLineStack.widthAnchor).isActive = true
        let applyBrokenButton = NSButton(title: "应用这一行", target: self, action: #selector(applyBrokenLine(_:)))
        applyBrokenButton.bezelStyle = .rounded
        brokenLineStack.addArrangedSubview(applyBrokenButton)
        brokenLineStack.isHidden = true

        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = 12
        let separator = NSBox()
        separator.boxType = .separator
        formStack.setViews([formTitleLabel, separator, brokenLineStack]
            + fieldStacks + [problemStack], in: .leading)
        for item in formStack.arrangedSubviews {
            item.translatesAutoresizingMaskIntoConstraints = false
            item.widthAnchor.constraint(equalTo: formStack.widthAnchor).isActive = true
        }

        // MARK: header banner + footer

        conflictBanner.orientation = .horizontal
        conflictBanner.alignment = .centerY
        conflictBanner.spacing = 8
        conflictBanner.isHidden = true
        let conflictLabel = NSTextField(labelWithString: "配置文件已在别处被修改。草稿保留在这里，不会覆盖那次修改。")
        conflictLabel.font = .systemFont(ofSize: 11)
        conflictLabel.textColor = .systemOrange
        conflictLabel.lineBreakMode = .byWordWrapping
        conflictLabel.maximumNumberOfLines = 2
        conflictBanner.addArrangedSubview(conflictLabel)
        let reloadButton = NSButton(title: "重新载入", target: self, action: #selector(reloadFromDisk(_:)))
        reloadButton.bezelStyle = .rounded
        conflictBanner.addArrangedSubview(reloadButton)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        saveButton = NSButton(title: "保存并应用", target: self, action: #selector(saveAndApply(_:)))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.setViews([statusLabel, NSView(), saveButton], in: .leading)

        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        let panes = NSStackView(views: [listColumn, formStack])
        panes.orientation = .horizontal
        panes.alignment = .top
        panes.spacing = 20
        formStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true

        contentStack.setViews([conflictBanner, panes, footer], in: .leading)
        contentStack.setCustomSpacing(16, after: panes)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: root.topAnchor),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
            conflictBanner.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -32),
            footer.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -32),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        window.contentView = root

        for field in [nameField, localPortField, sshTargetField, remotePortField, webKeyField] {
            field.target = self
            field.action = #selector(formEdited(_:))
            field.delegate = self
        }
        keyVisibleField.target = self
        keyVisibleField.action = #selector(formEdited(_:))
        brokenLineField.delegate = self
    }

    // MARK: - list

    private func reloadList(selecting desired: UUID? = nil) {
        let previous = desired ?? selectedRowID
        tableView.reloadData()
        let rows = model.rows
        if let previous, let index = rows.firstIndex(where: { $0.id == previous }) {
            tableView.selectRowIndexes([index], byExtendingSelection: false)
            selectedRowID = previous
            showFormForSelection()
        } else if let first = rows.first {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
            selectedRowID = first.id
            showFormForSelection()
        } else {
            selectedRowID = nil
            clearForm()
        }
        emptyListLabel.isHidden = !rows.isEmpty
        undoDeleteButton.isHidden = !model.canUndoDelete()
        deleteButton.isEnabled = selectedRowID != nil
        updateSaveButton()
    }

    private func showFormForSelection() {
        guard let id = selectedRowID, let row = model.rows.first(where: { $0.id == id }) else {
            clearForm()
            return
        }
        formTitleLabel.stringValue = row.isBroken
            ? "第 \(row.lineNumber) 行需要修正"
            : "编辑「\(row.title)」"

        let isBroken = row.isBroken
        brokenLineStack.isHidden = !isBroken
        for view in formStack.arrangedSubviews where view !== brokenLineStack && view !== formTitleLabel {
            // hide the target fields while repairing a broken raw line
            view.isHidden = isBroken
        }
        if isBroken {
            brokenLineField.stringValue = model.brokenText(for: id) ?? ""
            clearProblemLabels()
            return
        }

        guard let form = model.form(for: id) else { clearProblemLabels(); return }
        nameField.stringValue = form.name
        localPortField.stringValue = form.localPort
        sshTargetField.stringValue = form.sshTarget
        remotePortField.stringValue = form.remotePort
        if keyIsVisible {
            keyVisibleField.stringValue = form.webKey
        } else {
            webKeyField.stringValue = form.webKey
        }
        updateKeyFieldMode()
        showProblems(ConfigDraft.FieldProblems())
    }

    private func clearForm() {
        formTitleLabel.stringValue = "选择一条隧道"
        brokenLineStack.isHidden = true
        for field in [nameField, localPortField, sshTargetField, remotePortField, webKeyField, keyVisibleField] {
            field.stringValue = ""
        }
        for label in problemLabels { label.isHidden = true }
    }

    private func clearProblemLabels() {
        for label in problemLabels { label.isHidden = true }
    }

    private func showProblems(_ problems: ConfigDraft.FieldProblems) {
        let messages = [problems.name, problems.localPort, problems.sshTarget, problems.remotePort]
        for (index, label) in problemLabels.enumerated() {
            if index < messages.count, let message = messages[index] {
                label.stringValue = message
                label.isHidden = false
            } else {
                label.isHidden = true
            }
        }
    }

    private func updateKeyFieldMode() {
        // Keep the value in whichever field is currently visible; a key that is
        // being edited is never thrown away by toggling the visibility.
        webKeyField.isHidden = keyIsVisible
        keyVisibleField.isHidden = !keyIsVisible
        showKeyButton.title = keyIsVisible ? "隐藏密钥" : "显示密钥"
    }

    /// Write the visible fields back into the draft. Called on every keystroke,
    /// so switching rows or closing the window never loses typed text.
    private func commitFormToDraft() {
        guard let id = selectedRowID else { return }
        if model.rows.first(where: { $0.id == id })?.isBroken == true { return }
        // The form always reads from the field that is currently visible, so a
        // hidden secure field never overwrites what the user just typed.
        model.apply(currentForm(), to: id)
        updateSaveButton()
    }

    private func currentForm() -> TunnelForm {
        TunnelForm(name: nameField.stringValue,
                   localPort: localPortField.stringValue,
                   sshTarget: sshTargetField.stringValue,
                   remotePort: remotePortField.stringValue,
                   webKey: keyIsVisible ? keyVisibleField.stringValue : webKeyField.stringValue)
    }

    private func updateSaveButton() {
        saveButton.isEnabled = !model.rows.isEmpty || model.hasUnsavedChanges()
        if model.hasUnsavedChanges() {
            statusLabel.stringValue = Self.unsavedStatusText
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    // MARK: - actions

    @objc private func addTunnel(_ sender: Any?) {
        commitFormToDraft()
        let id = model.addTunnel()
        pendingNewRowID = id
        reloadList(selecting: id)
        window?.makeFirstResponder(nameField)
        updateSaveButton()
    }

    @objc private func deleteTunnel(_ sender: Any?) {
        guard let id = selectedRowID else { return }
        commitFormToDraft()
        _ = model.delete(id: id)
        selectedRowID = nil
        reloadList()
        updateSaveButton()
    }

    @objc private func undoDelete(_ sender: Any?) {
        model.undoDelete()
        reloadList(selecting: selectedRowID)
        updateSaveButton()
    }

    @objc private func formEdited(_ sender: Any?) {
        commitFormToDraft()
        if let id = selectedRowID, model.rows.first(where: { $0.id == id })?.isBroken == false {
            showProblems(model.problems(for: id, form: currentForm()))
        }
    }

    @objc private func toggleKeyVisibility(_ sender: Any?) {
        let current = keyIsVisible ? keyVisibleField.stringValue : webKeyField.stringValue
        keyIsVisible.toggle()
        if keyIsVisible {
            keyVisibleField.stringValue = current
        } else {
            webKeyField.stringValue = current
        }
        updateKeyFieldMode()
    }

    @objc private func applyBrokenLine(_ sender: Any?) {
        guard let id = selectedRowID else { return }
        _ = model.repairBroken(id: id, text: brokenLineField.stringValue)
        if let row = model.rows.first(where: { $0.id == id }), row.isBroken {
            statusLabel.stringValue = "这一行仍无法解析：\(row.subtitle)"
            statusLabel.textColor = .systemRed
        }
        reloadList(selecting: id)
        updateSaveButton()
    }

    @objc private func reloadFromDisk(_ sender: Any?) {
        model.reload()
        conflictBanner.isHidden = true
        selectedRowID = nil
        reloadList()
        statusLabel.stringValue = "已重新载入磁盘上的配置"
        statusLabel.textColor = .secondaryLabelColor
    }

    @objc private func saveAndApply(_ sender: Any?) {
        commitFormToDraft()
        guard let id = selectedRowID, model.rows.first(where: { $0.id == id })?.isBroken == false else {
            performSave()
            return
        }
        let problems = model.problems(for: id, form: currentForm())
        guard problems.isEmpty else {
            showProblems(problems)
            statusLabel.stringValue = "请先修正标出的字段"
            statusLabel.textColor = .systemRed
            return
        }
        performSave()
    }

    private func performSave() {
        // Deletions are one click away from being undone, but saving a draft
        // that removes tunnels deserves an explicit confirmation.
        if !model.pendingDeletionNames.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "保存后这些隧道会被删除"
            alert.informativeText = model.pendingDeletionNames.joined(separator: "、")
            alert.addButton(withTitle: "保存并应用")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        switch model.save() {
        case .blocked(let problems):
            let lines = problems.map { "第 \($0.line) 行：\($0.message)" }.joined(separator: "\n")
            statusLabel.stringValue = "配置未通过校验，未写入"
            statusLabel.textColor = .systemRed
            presentMessage("无法保存配置", lines)
            commitFormToDraft()
            reloadList(selecting: selectedRowID)
            return
        case .conflict:
            conflictBanner.isHidden = false
            statusLabel.stringValue = "配置文件已被别处修改，未覆盖"
            statusLabel.textColor = .systemOrange
            return
        case .failed(let message):
            statusLabel.stringValue = "写入失败：\(message)"
            statusLabel.textColor = .systemRed
            return
        case .written:
            break
        }

        onSaved()
        let digest = model.savedDigest ?? ""
        statusLabel.stringValue = "配置已保存，正在请求守护进程应用…"
        statusLabel.textColor = .secondaryLabelColor
        conflictBanner.isHidden = true

        // The acknowledgement is only meaningful for the window state it was
        // requested from: if the window is reconciled again while the daemon is
        // still answering, that answer belongs to an older presentation and
        // must not repaint the status line over a newer one.
        let generation = presentationGeneration

        daemon.applyConfiguration(digest: digest) { [weak self] outcome in
            guard let self, self.presentationGeneration == generation else { return }
            self.statusLabel.stringValue = outcome.statusText
            self.statusLabel.textColor = outcome.isApplied ? .secondaryLabelColor : .systemOrange
            self.updateSaveButton()
        }
        reloadList(selecting: selectedRowID)
        updateSaveButton()
    }

    private func presentMessage(_ headline: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = headline
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - quit support

    func saveForQuit() -> String? {
        commitFormToDraft()
        switch model.save() {
        case .written(let text):
            let digest = ConfigDigest.digest(text)
            _ = daemon.applyConfiguration(digest: digest, timeout: 5)
            return nil
        case .blocked(let problems):
            return problems.map { "第 \($0.line) 行：\($0.message)" }.joined(separator: "\n")
        case .conflict:
            return "配置文件已在别处被修改。保存前请先在配置窗口重新载入。"
        case .failed(let message):
            return message
        }
    }

    func discardDraftForQuit() {
        model.reload()
    }

    // MARK: - window delegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.hasUnsavedChanges() else {
            // Nothing to lose: let AppKit close it. (Calling performClose from
            // here would re-enter this delegate and loop.)
            return true
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "保存对隧道配置的改动？"
        alert.informativeText = "关闭窗口前可以保存、放弃，或者继续编辑。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "放弃更改")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            commitFormToDraft()
            switch model.save() {
            case .written:
                performApplyAndForget()
                return true
            case .blocked(let problems):
                statusLabel.stringValue = "配置未通过校验，窗口没有关闭"
                statusLabel.textColor = .systemRed
                presentMessage("无法保存配置",
                               problems.map { "第 \($0.line) 行：\($0.message)" }.joined(separator: "\n"))
                return false
            case .conflict:
                conflictBanner.isHidden = false
                statusLabel.stringValue = "配置文件已被别处修改，窗口没有关闭"
                statusLabel.textColor = .systemOrange
                return false
            case .failed(let message):
                statusLabel.stringValue = "写入失败：\(message)"
                statusLabel.textColor = .systemRed
                return false
            }
        case .alertSecondButtonReturn:
            model.reload()
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the window must never lose the draft silently: the model is
        // owned by the controller and the window is re-presented with it.
        NotificationCenter.default.post(name: .configWindowClosed, object: self)
    }

    private func performApplyAndForget() {
        guard let digest = model.savedDigest else { return }
        // This runs while the window is closing, so the acknowledgement lands
        // with the window gone. The generation it captured makes it a no-op
        // once the window is presented again — otherwise the reopened window
        // would show "已应用" for a save the user cannot see any more.
        let generation = presentationGeneration
        daemon.applyConfiguration(digest: digest) { [weak self] outcome in
            guard let self, self.presentationGeneration == generation else { return }
            self.statusLabel.stringValue = outcome.statusText
            self.statusLabel.textColor = outcome.isApplied ? .secondaryLabelColor : .systemOrange
        }
    }

}

// MARK: - table

/// A two-line list cell: the tunnel name on the first line, `127.0.0.1:port`
/// (or the broken-line reason) on the second.
///
/// Both labels are stored properties. The cell deliberately exposes no KVC
/// keys beyond `NSTableCellView`'s own: `NSTableCellView` has no `titleLabel`
/// property, so `setValue(_:forKey:)` on it raises `NSUnknownKeyException`,
/// and that exception is thrown from inside `NSTableView`'s layout pass —
/// every row then stays unrendered and the window shows as a blank white
/// rectangle. Reading the labels off the view tree (`.subviews.first?…`) is
/// equally fragile, so callers write to the fields directly.
final class TunnelCellView: NSTableCellView {
    let titleField: NSTextField
    let subtitleField: NSTextField

    init(identifier: NSUserInterfaceItemIdentifier) {
        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 12, weight: .medium)
        let subtitle = NSTextField(labelWithString: "")
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        self.titleField = title
        self.subtitleField = subtitle
        super.init(frame: .zero)
        self.identifier = identifier

        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // NSTableCellView's established convention: `textField` is the primary
        // label, which AppKit uses for editing and accessibility.
        textField = title
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

extension ConfigWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { model.rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = model.rows[row]
        let identifier = NSUserInterfaceItemIdentifier("tunnelCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? TunnelCellView)
            ?? TunnelCellView(identifier: identifier)
        cell.titleField.stringValue = entry.title
        cell.titleField.textColor = entry.isBroken ? .systemRed : .labelColor
        cell.subtitleField.stringValue = entry.subtitle
        cell.subtitleField.textColor = entry.isBroken ? .systemOrange : .secondaryLabelColor
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < model.rows.count else { return }
        if selectedRowID != model.rows[row].id {
            commitFormToDraft()
        }
        selectedRowID = model.rows[row].id
        showFormForSelection()
        deleteButton.isEnabled = true
    }
}

extension ConfigWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        commitFormToDraft()
    }
}

extension Notification.Name {
    static let configWindowClosed = Notification.Name("magpie.configWindowClosed")
}
