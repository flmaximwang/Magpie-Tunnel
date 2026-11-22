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

    /// Parse the textual content of a config file. Validation lives in
    /// `ConfigDocument` so the daemon's parser and the config editor's draft
    /// model can never disagree about what a valid row is.
    public static func parse(_ text: String) -> ParsedTargets {
        let document = ConfigDocument.parse(text)
        return ParsedTargets(targets: document.targets,
                             rawLines: splitLines(text),
                             diagnostics: document.diagnostics)
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
    ///
    /// Splitting on `\n` and stripping one trailing `\r` per line, rather than
    /// `components(separatedBy: .newlines)`: Foundation's `.newlines` matches
    /// `\r` *and* `\n`, so every `\r\n` used to yield an extra empty line and
    /// the editor would copy those blanks back on the next save. `split(separator:)`
    /// cannot be used either: Swift treats `\r\n` as a single `Character`, so a
    /// CRLF file would come back as one giant line.
    static func splitLines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n").map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
        if let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        return lines
    }
}
