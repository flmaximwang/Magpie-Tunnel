import Foundation

/// An editable view of `targets.conf` for the configuration window.
///
/// The draft keeps every original line so comments and blank lines survive a
/// save. Targets and broken lines are identified by a stable `id`, which lets
/// the UI keep the selection and undo a deletion even after other rows were
/// edited.
public struct ConfigDraft: Equatable {
    /// One line as the editor sees it.
    public struct Row: Equatable, Identifiable {
        public enum Kind: Equatable {
            /// A valid target row; editable through the form.
            case target(TargetConfig)
            /// A row that failed validation; shown with its line number and
            /// reason so the user can fix or remove it.
            case broken(reason: String)
        }
        public let id: UUID
        /// 1-based line number in the file `serialize()` would write *now*.
        /// Mutable because the draft renumbers after each edit (see
        /// `renumberSourceLines()`): after a removal every later row moves up.
        public var sourceLine: Int
        public var kind: Kind

        /// The line text as it appears on disk.
        public var raw: String

        public init(id: UUID, sourceLine: Int, kind: Kind, raw: String) {
            self.id = id
            self.sourceLine = sourceLine
            self.kind = kind
            self.raw = raw
        }
    }

    /// Every line of the file in order, including comments and blanks (which
    /// the UI does not list but always writes back verbatim).
    public enum Stored: Equatable {
        case preserved(String)
        case row(Row)

        public var row: Row? {
            if case .row(let row) = self { return row }
            return nil
        }
    }

    public var stored: [Stored]

    public init(stored: [Stored] = []) {
        self.stored = stored
    }

    // MARK: - construction

    /// Build a draft from file text. Rows that fail validation become `.broken`
    /// entries carrying `第 N 行：…` reasons.
    public static func from(text: String) -> ConfigDraft {
        var stored: [Stored] = []
        var seenNames: Set<String> = []
        var seenPorts: [Int: String] = [:]

        for (index, raw) in TargetsParser.splitLines(text).enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                stored.append(.preserved(raw))
                continue
            }
            let lineNumber = index + 1
            let reason: String
            switch ConfigDocument.parseRow(raw, lineNumber: lineNumber,
                                           seenNames: &seenNames, seenPorts: &seenPorts) {
            case .valid(let target):
                stored.append(.row(Row(id: UUID(), sourceLine: lineNumber,
                                       kind: .target(target), raw: raw)))
                continue
            case .invalid(let message):
                reason = message
            }
            stored.append(.row(Row(id: UUID(), sourceLine: lineNumber,
                                   kind: .broken(reason: reason), raw: raw)))
        }
        return ConfigDraft(stored: stored)
    }

    /// Load straight from disk. Missing file → empty draft (the UI then offers
    /// the built-in defaults as a starting suggestion, but never writes them
    /// behind the user's back).
    public static func load(path: String) throws -> (draft: ConfigDraft, snapshot: ConfigFileSnapshot) {
        let snapshot = try ConfigFileSnapshot.read(path: path)
        return (ConfigDraft.from(text: snapshot.text), snapshot)
    }

    // MARK: - queries

    /// Editable rows only (valid targets and broken lines), in order.
    public var rows: [Row] {
        stored.compactMap { if case .row(let row) = $0 { return row }; return nil }
    }

    /// Valid targets in file order.
    public var targets: [TargetConfig] {
        rows.compactMap { if case .target(let target) = $0.kind { return target }; return nil }
    }

    /// Untouched lines (comments and blanks).
    public var preservedLineCount: Int {
        stored.filter { if case .preserved = $0 { return true }; return false }.count
    }

    public func row(id: UUID) -> Row? {
        rows.first { $0.id == id }
    }

    // MARK: - edits

    /// Append a new target row at the end of the file.
    @discardableResult
    public mutating func addTarget(_ target: TargetConfig) -> UUID {
        let id = UUID()
        stored.append(.row(Row(id: id, sourceLine: stored.count + 1,
                               kind: .target(target), raw: target.confLine)))
        renumberSourceLines()
        return id
    }

    /// Replace a row's target. Broken rows become targets through this too
    /// (that is how "fix this line" is applied).
    public mutating func update(id: UUID, target: TargetConfig) {
        guard let index = stored.firstIndex(where: {
            if case .row(let row) = $0 { return row.id == id }
            return false
        }), case .row(var row) = stored[index] else { return }
        row.kind = .target(target)
        row.raw = target.confLine
        stored[index] = .row(row)
        renumberSourceLines()
    }

    /// Remove a row. Returns the removed row and its position for `undoRemove`.
    @discardableResult
    public mutating func remove(id: UUID) -> (row: Row, index: Int)? {
        guard let index = stored.firstIndex(where: {
            if case .row(let row) = $0 { return row.id == id }
            return false
        }), case .row(let row) = stored[index] else { return nil }
        stored.remove(at: index)
        renumberSourceLines()
        return (row, index)
    }

    /// Put a removed row back where it came from.
    public mutating func undoRemove(_ removed: (row: Row, index: Int)) {
        guard !stored.contains(where: {
            if case .row(let row) = $0 { return row.id == removed.row.id }
            return false
        }) else { return }
        stored.insert(.row(removed.row), at: min(removed.index, stored.count))
        renumberSourceLines()
    }

    /// Drop a broken line without converting it (explicit user decision).
    public mutating func dropBroken(id: UUID) {
        _ = remove(id: id)
    }

    /// Fill an empty draft with the built-in default targets.
    public mutating func useBuiltInDefaults() {
        for target in TargetConfig.builtInDefaults {
            addTarget(target)
        }
    }

    // MARK: - validation

    /// Field-level problems for one row's target, in the order they appear in
    /// the form. `nil` fields map to entries even when the row is broken, so a
    /// brand-new row can show every problem at once.
    public struct FieldProblems: Equatable {
        public var name: String?
        public var localPort: String?
        public var sshTarget: String?
        public var remotePort: String?

        public init(name: String? = nil, localPort: String? = nil,
                    sshTarget: String? = nil, remotePort: String? = nil) {
            self.name = name
            self.localPort = localPort
            self.sshTarget = sshTarget
            self.remotePort = remotePort
        }

        /// Any problem at all, for compact "can this row be saved" checks.
        public var isEmpty: Bool {
            name == nil && localPort == nil && sshTarget == nil && remotePort == nil
        }
    }

    /// Validate one row's fields plus cross-row uniqueness against *all other*
    /// rows in the draft. Empty strings mean "no problem".
    public func problems(for target: TargetConfig, ignoring id: UUID? = nil) -> FieldProblems {
        var result = FieldProblems()
        let others = rows.filter { $0.id != id }

        if target.name.isEmpty {
            result.name = "名字不能为空"
        } else if target.name.contains("/") || target.name.contains("\\")
            || target.name.hasPrefix(".") || target.name.contains(":") {
            result.name = "名字不能包含 / \\ : ，也不能以 . 开头"
        } else if others.contains(where: { row in
            if case .target(let other) = row.kind { return other.name == target.name }
            return false
        }) {
            result.name = "名字 “\(target.name)” 与另一条隧道重复"
        }

        if !target.sshTarget.trimmingCharacters(in: .whitespaces).isEmpty {
            if target.sshTarget.contains(" ") {
                result.sshTarget = "SSH 目标不能包含空格"
            }
        } else {
            result.sshTarget = "SSH 目标不能为空"
        }

        if target.localPort < 1 || target.localPort > 65535 {
            result.localPort = "本机端口应在 1...65535"
        } else if others.contains(where: { row in
            if case .target(let other) = row.kind { return other.localPort == target.localPort }
            return false
        }) {
            result.localPort = "本机端口 \(target.localPort) 已被另一条隧道占用"
        }

        if target.remotePort < 1 || target.remotePort > 65535 {
            result.remotePort = "远端端口应在 1...65535"
        }
        return result
    }

    /// Rows that still need attention before the draft can be saved: broken
    /// lines the user has neither fixed nor removed.
    public var unresolvedBrokenRows: [Row] {
        rows.filter { if case .broken = $0.kind { return true }; return false }
    }

    /// Every problem that blocks saving, in file order. Empty means the draft
    /// can be written.
    public func blockingProblems() -> [(row: Row, message: String)] {
        var results: [(row: Row, message: String)] = []
        for row in rows {
            switch row.kind {
            case .target(let target):
                let problems = problems(for: target, ignoring: row.id)
                for message in [problems.name, problems.localPort,
                                problems.sshTarget, problems.remotePort].compactMap({ $0 }) {
                    results.append((row, message))
                }
            case .broken(let reason):
                results.append((row, reason + "（请修正或删除这一行）"))
            }
        }
        return results
    }

    // MARK: - serialization

    /// The exact file text this draft would write.
    public func serialize() -> String {
        var lines: [String] = []
        for item in stored {
            switch item {
            case .preserved(let text): lines.append(text)
            case .row(let row):
                switch row.kind {
                case .target(let target): lines.append(target.confLine)
                case .broken: lines.append(row.raw) // unreachable: save is blocked
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Recompute every row's `sourceLine` from its current position in
    /// `stored`, so the numbers the UI shows always match the file a save
    /// would write right now.
    ///
    /// Only the numbers move: `stored` order (and therefore the serialized
    /// text, comments and blanks) is untouched. Broken rows also carry their
    /// line number inside the reason string ("第 N 行：…"), so that prefix is
    /// rewritten too; otherwise deleting an earlier row would leave the
    /// message pointing at the old line.
    public mutating func renumberSourceLines() {
        for index in stored.indices {
            guard case .row(var row) = stored[index] else { continue }
            let newLine = index + 1
            if newLine != row.sourceLine {
                row.sourceLine = newLine
                if case .broken(let reason) = row.kind {
                    row.kind = .broken(reason: Self.replacingLinePrefix(
                        in: reason, with: newLine))
                }
            }
            stored[index] = .row(row)
        }
    }

    /// Swap the leading "第 N 行：" of a broken-row reason for the given line.
    /// Reasons that do not have that prefix are returned unchanged.
    private static func replacingLinePrefix(in reason: String, with line: Int) -> String {
        guard reason.hasPrefix("第 "), let colon = reason.firstIndex(of: "：") else {
            return reason
        }
        let rest = reason[reason.index(after: colon)...]
        return "第 \(line) 行：" + rest
    }
}
