import Foundation
import MagpieTunnelCore

/// The five editable fields of one tunnel, kept as *strings*.
///
/// Strings rather than `Int` because a half-typed port is a normal editing
/// state: the form must be able to hold "34" without the row exploding into a
/// parse error on every keystroke. Validation happens when saving and while
/// displaying field-level problems.
struct TunnelForm: Equatable {
    var name: String = ""
    var localPort: String = ""
    var sshTarget: String = ""
    var remotePort: String = "443"
    var webKey: String = ""

    init() {}

    init(name: String, localPort: String, sshTarget: String, remotePort: String, webKey: String) {
        self.name = name
        self.localPort = localPort
        self.sshTarget = sshTarget
        self.remotePort = remotePort
        self.webKey = webKey
    }

    init(target: TargetConfig) {
        name = target.name
        localPort = String(target.localPort)
        sshTarget = target.sshTarget
        remotePort = String(target.remotePort)
        webKey = target.webKey
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    var trimmedSSH: String { sshTarget.trimmingCharacters(in: .whitespaces) }

    /// Non-numeric text cannot become a port; report it as a field problem
    /// instead of silently writing 0.
    var localPortValue: Int? { Int(localPort.trimmingCharacters(in: .whitespaces)) }
    var remotePortValue: Int? { Int(remotePort.trimmingCharacters(in: .whitespaces)) }

    /// Build the target this form describes. Ports fall back to 0, which the
    /// draft validator then rejects with its own message.
    func target() -> TargetConfig {
        TargetConfig(name: trimmedName,
                     localPort: localPortValue ?? 0,
                     sshTarget: trimmedSSH,
                     remotePort: remotePortValue ?? 0,
                     webKey: webKey.trimmingCharacters(in: .whitespaces))
    }

    /// Server-side message for a port that is not a number at all.
    func parseProblems() -> ConfigDraft.FieldProblems {
        var problems = ConfigDraft.FieldProblems()
        if localPortValue == nil {
            problems.localPort = "本机端口必须是数字"
        }
        if remotePortValue == nil {
            problems.remotePort = "远端端口必须是数字"
        }
        return problems
    }
}

/// One entry in the configuration window's list.
struct EditorRow: Equatable {
    let id: UUID
    let lineNumber: Int
    /// The tunnel name, or the broken line's text when it has no name.
    let title: String
    /// "127.0.0.1:3430" for a target, "第 12 行需要修正" for a broken line.
    let subtitle: String
    let isBroken: Bool
}

/// Everything the configuration window edits, with no AppKit in it: the draft,
/// the snapshot it was loaded from, the pending deletions and the save flow.
///
/// The rules it enforces are the ones the spec calls for — one save for all
/// changes, comments and blank lines preserved, external edits never
/// overwritten silently, a config with zero tunnels stays a config with zero
/// tunnels — and they are unit-testable without a window.
final class ConfigEditorModel {
    enum LoadState: Equatable {
        case loaded
        case unreadable(String)
    }

    struct SaveProblem: Equatable {
        let line: Int
        let message: String
    }

    enum SaveResult: Equatable {
        /// Draft was written; the daemon still has to confirm it applied it.
        case written(text: String)
        /// The draft cannot be written as it stands.
        case blocked([SaveProblem])
        /// The file changed underneath us: keep the draft, do not overwrite.
        case conflict
        /// Writing failed; the draft is intact.
        case failed(String)
    }

    let path: String
    private(set) var draft = ConfigDraft()
    private(set) var snapshot: ConfigFileSnapshot
    private(set) var loadState = LoadState.loaded
    /// Names deleted in this session, for the save confirmation.
    private(set) var pendingDeletionNames: [String] = []
    /// The row deleted last, where it sat, and the target name to roll back.
    /// `deletedName` is nil for a broken line, which is why undo cannot assume
    /// that every undo pops a name off `pendingDeletionNames`.
    private var undoState: (row: ConfigDraft.Row, index: Int, deletedName: String?)?
    /// True when a regular config file exists but its text cannot be decoded.
    ///
    /// Such a file cannot be represented by `snapshot`: reading it throws, the
    /// init falls back to a "missing file" snapshot, and an atomic write would
    /// replace bytes the user never saw. Saving must refuse instead.
    private(set) var isExistingButUnreadable = false
    private(set) var isDirty = false
    /// Set after a successful write until the window reloads or edits again.
    private(set) var savedText: String?

    init(path: String) {
        self.path = path
        let loaded = (try? ConfigDraft.load(path: path))
            ?? (draft: ConfigDraft(), snapshot: ConfigFileSnapshot(path: path, text: "",
                                                                   exists: false, identity: nil))
        self.draft = loaded.draft
        self.snapshot = loaded.snapshot
        if let error = Self.readError(path: path) {
            loadState = .unreadable(error)
        }
        isExistingButUnreadable = Self.isUnreadableRegularFile(path: path)
    }

    private static func readError(path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        // Readable but broken rows are fine: those are repaired in the window.
        return (try? String(contentsOfFile: path, encoding: .utf8)) == nil
            ? "文件无法读取（可能是权限或编码问题）" : nil
    }

    /// Whether `path` is a *regular file* holding bytes we cannot decode.
    ///
    /// Only a regular file can lose data: a directory or a socket cannot be a
    /// configuration and a write to it fails on its own. A regular file, on the
    /// other hand, looks exactly like a missing file to the snapshot, so without
    /// this flag a save would happily replace it.
    private static func isUnreadableRegularFile(path: String) -> Bool {
        guard readError(path: path) != nil else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        return !isDirectory.boolValue
    }

    // MARK: - list

    var rows: [EditorRow] {
        draft.rows.map { row in
            switch row.kind {
            case .target(let target):
                return EditorRow(id: row.id, lineNumber: row.sourceLine,
                                 title: target.name,
                                 subtitle: "127.0.0.1:\(target.localPort)",
                                 isBroken: false)
            case .broken(let reason):
                return EditorRow(id: row.id, lineNumber: row.sourceLine,
                                 title: "第 \(row.sourceLine) 行",
                                 subtitle: reason,
                                 isBroken: true)
            }
        }
    }

    func form(for id: UUID) -> TunnelForm? {
        guard let row = draft.row(id: id) else { return nil }
        switch row.kind {
        case .target(let target): return TunnelForm(target: target)
        case .broken: return nil
        }
    }

    /// Raw text of a broken line, so the user can repair it in place.
    func brokenText(for id: UUID) -> String? {
        guard let row = draft.row(id: id), case .broken = row.kind else { return nil }
        return row.raw
    }

    func canUndoDelete() -> Bool { undoState != nil }

    func undoDelete() {
        guard let undoState else { return }
        draft.undoRemove((row: undoState.row, index: undoState.index))
        // Only a target put a name on the list; a broken line never did, so
        // popping the last name here would drop some *other* tunnel's pending
        // deletion and hide it from the save confirmation.
        if let deletedName = undoState.deletedName,
           let pendingIndex = pendingDeletionNames.lastIndex(of: deletedName) {
            // By name, one occurrence: `removeLast()` assumed the last entry
            // belonged to this undo, which is false for a broken row. Removing
            // exactly one occurrence also keeps two same-named rows correct.
            pendingDeletionNames.remove(at: pendingIndex)
        }
        self.undoState = nil
        isDirty = true
    }

    // MARK: - edits

    /// Apply a form to an existing row (a valid target only).
    @discardableResult
    func apply(_ form: TunnelForm, to id: UUID) -> Bool {
        guard let existing = draft.row(id: id) else { return false }
        switch existing.kind {
        case .target(let old):
            var target = form.target()
            guard target != old else { return false }
            // Keep the key verbatim: trimming it would change a working URL.
            target.webKey = form.webKey
            draft.update(id: id, target: target)
        case .broken:
            return false
        }
        isDirty = true
        return true
    }

    /// Repair a broken line by replacing its raw text; a line that now parses
    /// becomes a normal target row.
    @discardableResult
    func repairBroken(id: UUID, text: String) -> Bool {
        guard let row = draft.row(id: id), case .broken = row.kind else { return false }
        guard let index = storedIndex(for: id) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return false }

        var seenNames: Set<String> = []
        var seenPorts: [Int: String] = [:]
        for other in draft.rows where other.id != id {
            if case .target(let target) = other.kind {
                seenNames.insert(target.name)
                seenPorts[target.localPort] = target.name
            }
        }
        switch ConfigDocument.parseRow(text, lineNumber: row.sourceLine,
                                       seenNames: &seenNames, seenPorts: &seenPorts) {
        case .valid(let target):
            draft.stored[index] = .row(ConfigDraft.Row(id: id, sourceLine: row.sourceLine,
                                                       kind: .target(target), raw: target.confLine))
        case .invalid(let reason):
            draft.stored[index] = .row(ConfigDraft.Row(id: id, sourceLine: row.sourceLine,
                                                       kind: .broken(reason: reason), raw: text))
        }
        // Written straight into `stored`, so renumber here too: the reason a
        // broken line carries must mention the line it will sit on after a save.
        draft.renumberSourceLines()
        isDirty = true
        return true
    }

    /// Add a new row with a free local port, and return its id.
    @discardableResult
    func addTunnel() -> UUID {
        var form = TunnelForm()
        form.localPort = String(Self.freeLocalPort(used: draft.targets.map(\.localPort)))
        let id = draft.addTarget(form.target())
        isDirty = true
        return id
    }

    /// First port at or above `start` that `used` does not contain.
    ///
    /// Bounded: an unbounded walk over a draft that already holds every port
    /// would run past 65535 into values the validator rejects. When nothing is
    /// free the caller gets `start` back, and the form's duplicate-port problem
    /// blocks the save instead of silently writing an out-of-range port.
    static func freeLocalPort(startingAt start: Int = 3430, used: [Int]) -> Int {
        let usedPorts = Set(used)
        var port = start
        while usedPorts.contains(port), port < 65535 { port += 1 }
        return usedPorts.contains(port) ? start : port
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        guard let row = draft.row(id: id) else { return false }
        var deletedName: String?
        if case .target(let target) = row.kind {
            pendingDeletionNames.append(target.name)
            deletedName = target.name
        }
        guard let removed = draft.remove(id: id) else { return false }
        undoState = (row: removed.row, index: removed.index, deletedName: deletedName)
        isDirty = true
        return true
    }

    /// Field problems for the selected row, including cross-row conflicts.
    func problems(for id: UUID, form: TunnelForm) -> ConfigDraft.FieldProblems {
        var problems = draft.problems(for: form.target(), ignoring: id)
        let parse = form.parseProblems()
        if problems.localPort == nil { problems.localPort = parse.localPort }
        if problems.remotePort == nil { problems.remotePort = parse.remotePort }
        return problems
    }

    func hasUnsavedChanges() -> Bool { isDirty }

    // MARK: - save

    /// Write the whole draft at once, or refuse to.
    ///
    /// Nothing is written when any row still has a problem: the spec asks for
    /// one validated write, not a partial one.
    func save() -> SaveResult {
        // Checked before anything else: an existing but undecodable file has a
        // "missing" snapshot, so neither the blocking-problem pass nor the
        // staleness check would notice that writing here destroys content the
        // user never got to see. Refusing the save is better than overwriting.
        guard !isExistingButUnreadable else {
            return .failed("配置文件存在但无法读取，为避免覆盖它，这次没有保存")
        }
        // Rows are renumbered on every edit; do it once more before reporting
        // problems so the line numbers in `.blocked` match the file a save
        // would produce right now, even if stored was touched directly.
        draft.renumberSourceLines()
        let problems = draft.blockingProblems()
        guard problems.isEmpty else {
            return .blocked(problems.map { SaveProblem(line: $0.row.sourceLine, message: $0.message) })
        }
        if snapshot.isStale() {
            return .conflict
        }
        let text = draft.serialize()
        do {
            let newSnapshot = try ConfigFileSnapshot.write(text, to: path)
            snapshot = newSnapshot
            savedText = text
            isDirty = false
            pendingDeletionNames = []
            undoState = nil
            return .written(text: text)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Reload from disk, discarding the draft. Used when the user accepts
    /// overwriting nothing and wants the file as it now stands.
    func reload() {
        let loaded = (try? ConfigDraft.load(path: path))
            ?? (draft: ConfigDraft(), snapshot: ConfigFileSnapshot(path: path, text: "",
                                                                   exists: false, identity: nil))
        draft = loaded.draft
        snapshot = loaded.snapshot
        pendingDeletionNames = []
        undoState = nil
        isDirty = false
        savedText = nil
        loadState = Self.readError(path: path).map { LoadState.unreadable($0) } ?? .loaded
        // The file may have been replaced (or become readable) meanwhile.
        isExistingButUnreadable = Self.isUnreadableRegularFile(path: path)
    }

    /// The digest the daemon matches against its own read of the file.
    var savedDigest: String? { savedText.map { ConfigDigest.digest($0) } }

    // MARK: - helpers

    private func storedIndex(for id: UUID) -> Int? {
        draft.stored.firstIndex { $0.row?.id == id }
    }
}
