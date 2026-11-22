import Foundation

/// A parsed `targets.conf` that remembers every original line, so the editor can
/// rewrite targets while keeping comments, blank lines and their positions.
public struct ConfigDocument: Equatable {
    public enum Line: Equatable {
        /// Comment or blank line, preserved verbatim.
        case text(String)
        /// A valid target row, with the original text kept for round trips.
        case target(TargetConfig, raw: String)
        /// A row that failed validation. Kept so the editor can show the line
        /// number and reason, and let the user fix or remove it.
        case invalid(raw: String, reason: String, line: Int)

        /// The exact source text of this line.
        public var raw: String {
            switch self {
            case .text(let text): return text
            case .target(_, let raw): return raw
            case .invalid(let raw, _, _): return raw
            }
        }
    }

    public var lines: [Line]

    public init(lines: [Line]) {
        self.lines = lines
    }

    /// Parse the textual content of a config file. Every line is represented:
    /// valid rows become `.target`, broken rows become `.invalid` with a
    /// human-readable reason that includes the 1-based line number.
    public static func parse(_ text: String) -> ConfigDocument {
        var lines: [Line] = []
        var seenNames: Set<String> = []
        var seenPorts: [Int: String] = [:]

        for (index, raw) in TargetsParser.splitLines(text).enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                lines.append(.text(raw))
                continue
            }
            switch parseRow(raw, lineNumber: index + 1,
                            seenNames: &seenNames, seenPorts: &seenPorts) {
            case .valid(let target):
                lines.append(.target(target, raw: raw))
            case .invalid(let reason):
                lines.append(.invalid(raw: raw, reason: reason, line: index + 1))
            }
        }
        return ConfigDocument(lines: lines)
    }

    /// All valid targets, in file order.
    public var targets: [TargetConfig] {
        lines.compactMap {
            guard case .target(let target, _) = $0 else { return nil }
            return target
        }
    }

    /// `第 N 行：…` messages for every broken line.
    public var diagnostics: [String] {
        lines.compactMap {
            guard case .invalid(_, let reason, _) = $0 else { return nil }
            return reason
        }
    }

    /// Reward the document as file text (always ends with one newline).
    public func serialize() -> String {
        lines.map(\.raw).joined(separator: "\n") + "\n"
    }

    // MARK: - line parsing

    public enum RowResult: Equatable {
        case valid(TargetConfig)
        case invalid(String)
    }

    /// Shared single-line validator: field shape, name safety, ports, and the
    /// cross-line uniqueness rules. Messages keep the legacy wording.
    public static func parseRow(_ raw: String, lineNumber: Int,
                         seenNames: inout Set<String>,
                         seenPorts: inout [Int: String]) -> RowResult {
        let fields = raw.components(separatedBy: TargetsParser.separator)
        guard fields.count == 4 || fields.count == 5 else {
            return .invalid("第 \(lineNumber) 行：字段数 \(fields.count) 不合法（应为 4 或 5，用 | 分隔）")
        }

        let name = fields[0].trimmingCharacters(in: .whitespaces)
        let portText = fields[1].trimmingCharacters(in: .whitespaces)
        let ssh = fields[2].trimmingCharacters(in: .whitespaces)
        let remoteText = fields[3].trimmingCharacters(in: .whitespaces)
        let key = fields.count == 5 ? fields[4].trimmingCharacters(in: .whitespaces) : ""

        func problem(_ message: String) -> RowResult {
            .invalid("第 \(lineNumber) 行：\(message)")
        }

        guard !name.isEmpty else { return problem("名字为空") }
        guard !name.contains("/"), !name.contains("\\"), !name.hasPrefix("."), !name.contains(":") else {
            return problem("名字 “\(name)” 含不安全字符（不能包含 / \\ : ，不能以 . 开头）")
        }
        guard !ssh.isEmpty else { return problem("“\(name)” 的 ssh 目标为空") }
        guard let localPort = Int(portText), (1...65535).contains(localPort) else {
            return problem("“\(name)” 的本机端口 “\(portText)” 不合法（应为 1...65535）")
        }
        guard let remotePort = Int(remoteText), (1...65535).contains(remotePort) else {
            return problem("“\(name)” 的远端端口 “\(remoteText)” 不合法（应为 1...65535）")
        }
        if seenNames.contains(name) {
            return problem("名字 “\(name)” 重复，已忽略后续行")
        }
        if let other = seenPorts[localPort] {
            return problem("本机端口 \(localPort) 与 “\(other)” 冲突，已忽略 “\(name)”")
        }

        seenNames.insert(name)
        seenPorts[localPort] = name
        return .valid(TargetConfig(name: name, localPort: localPort, sshTarget: ssh,
                                   remotePort: remotePort, webKey: key))
    }
}
