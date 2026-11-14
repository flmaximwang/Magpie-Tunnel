import Foundation

/// Result of parsing a `targets.conf` document.
public struct ParsedTargets: Equatable {
    /// Valid, unique targets in file order.
    public var targets: [TargetConfig]
    /// Every original line (comments and blanks included), for byte-preserving round trips.
    public var rawLines: [String]
    /// Human-readable problems for invalid lines and duplicates (also safe to log).
    public var diagnostics: [String]

    public init(targets: [TargetConfig], rawLines: [String], diagnostics: [String]) {
        self.targets = targets
        self.rawLines = rawLines
        self.diagnostics = diagnostics
    }
}

/// Parses / validates / serializes `targets.conf`.
///
/// Line format (fields separated by `|`):
/// `name|local_port|ssh_target|remote_port|web_key`
/// - `#`-prefixed lines and blank lines are comments/spacing and are preserved.
/// - `web_key` may be empty (trailing `|` or omitted entirely).
/// - Names must be unique and are used as file names under `status/`, so they
///   may not contain `/`, newlines, or a leading `.`.
/// - Local ports must be unique and in 1...65535 (remote ports just 1...65535).
public enum TargetsParser {
    public static let separator = "|"

    /// Parse the textual content of a config file.
    public static func parse(_ text: String) -> ParsedTargets {
        var targets: [TargetConfig] = []
        var diagnostics: [String] = []
        var seenNames: Set<String> = []
        var seenLocalPorts: [Int: String] = [:]

        let rawLines = splitLines(text)
        for (index, raw) in rawLines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lineNumber = index + 1

            if line.isEmpty || line.hasPrefix("#") {
                continue // comment / blank: preserved via rawLines
            }

            let fields = raw.components(separatedBy: separator)
            // 4 fields (key omitted) or 5 fields (key possibly empty) are valid.
            guard fields.count == 4 || fields.count == 5 else {
                diagnostics.append("第 \(lineNumber) 行：字段数 \(fields.count) 不合法（应为 4 或 5，用 | 分隔）")
                continue
            }

            let name = fields[0].trimmingCharacters(in: .whitespaces)
            let portText = fields[1].trimmingCharacters(in: .whitespaces)
            let ssh = fields[2].trimmingCharacters(in: .whitespaces)
            let remoteText = fields[3].trimmingCharacters(in: .whitespaces)
            let key = fields.count == 5
                ? fields[4].trimmingCharacters(in: .whitespaces)
                : ""

            func problem(_ message: String) {
                diagnostics.append("第 \(lineNumber) 行：\(message)")
            }

            guard !name.isEmpty else {
                problem("名字为空")
                continue
            }
            guard !name.contains("/"), !name.contains("\\"), !name.hasPrefix("."), !name.contains(":") else {
                problem("名字 “\(name)” 含不安全字符（不能包含 / \\ : ，不能以 . 开头）")
                continue
            }
            guard !ssh.isEmpty else {
                problem("“\(name)” 的 ssh 目标为空")
                continue
            }
            guard let localPort = Int(portText), (1...65535).contains(localPort) else {
                problem("“\(name)” 的本机端口 “\(portText)” 不合法（应为 1...65535）")
                continue
            }
            guard let remotePort = Int(remoteText), (1...65535).contains(remotePort) else {
                problem("“\(name)” 的远端端口 “\(remoteText)” 不合法（应为 1...65535）")
                continue
            }
            if seenNames.contains(name) {
                problem("名字 “\(name)” 重复，已忽略后续行")
                continue
            }
            if let other = seenLocalPorts[localPort] {
                problem("本机端口 \(localPort) 与 “\(other)” 冲突，已忽略 “\(name)”")
                continue
            }

            seenNames.insert(name)
            seenLocalPorts[localPort] = name
            targets.append(TargetConfig(
                name: name,
                localPort: localPort,
                sshTarget: ssh,
                remotePort: remotePort,
                webKey: key
            ))
        }

        return ParsedTargets(targets: targets, rawLines: rawLines, diagnostics: diagnostics)
    }

    /// Parse a config file from disk. Throws only when the file cannot be read;
    /// content problems are reported through `diagnostics`.
    public static func parseFile(at path: String) throws -> ParsedTargets {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return parse(text)
    }

    /// Serialize lines back to file content (round-trips `rawLines` byte-for-byte,
    /// modulo the trailing newline the file always ends with).
    public static func serialize(_ lines: [String]) -> String {
        lines.joined(separator: "\n") + "\n"
    }

    /// Split text into logical lines, tolerating \r\n and a missing final newline.
    static func splitLines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: .newlines)
        if let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        return lines
    }
}
