import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One parsed `status/<name>` record.
///
/// Wire format (unchanged from the legacy bash daemon, one line per file):
/// - up:   `up|<epoch>|port=<port>`
/// - down: `down|<epoch>|<reason>`
/// Unknown states from older/newer writers are preserved verbatim.
public struct StatusRecord: Equatable {
    public var state: String
    public var epoch: Int
    public var detail: String

    public init(state: String, epoch: Int, detail: String) {
        self.state = state
        self.epoch = epoch
        self.detail = detail
    }

    public var isUp: Bool { state == "up" }

    /// True while the daemon is actively establishing this tunnel and has not
    /// yet either succeeded or failed. Any other state (including an unknown
    /// string written by a foreign process) is not "connecting".
    public var isConnecting: Bool { state == "connecting" }

    /// Port from an `up` record's `port=<n>` detail, if parseable.
    public var port: Int? {
        guard isUp, detail.hasPrefix("port=") else { return nil }
        return Int(detail.dropFirst("port=".count))
    }

    /// `up` record: `up|<epoch>|port=<port>`
    public static func up(port: Int, epoch: Int? = nil) -> StatusRecord {
        StatusRecord(state: "up", epoch: epoch ?? Int(Date().timeIntervalSince1970), detail: "port=\(port)")
    }

    /// `connecting` record: `connecting|<epoch>|`
    ///
    /// Written when an ssh child has been spawned and the port is still being
    /// probed. The empty detail keeps the line shape identical to `up`/`down`.
    public static func connecting(epoch: Int? = nil) -> StatusRecord {
        StatusRecord(state: "connecting", epoch: epoch ?? Int(Date().timeIntervalSince1970), detail: "")
    }

    /// `down` record: `down|<epoch>|<reason>`
    public static func down(reason: String, epoch: Int? = nil) -> StatusRecord {
        StatusRecord(state: "down", epoch: epoch ?? Int(Date().timeIntervalSince1970), detail: reason)
    }

    /// Exact line written to disk (with trailing newline, matching legacy `printf`).
    public var serialized: String {
        "\(state)|\(epoch)|\(detail)\n"
    }

    /// Tolerant parser: `state|epoch|detail` with detail optional.
    public static func parse(_ line: String) -> StatusRecord? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.components(separatedBy: "|")
        guard parts.count >= 2, let epoch = Int(parts[1]) else { return nil }
        let detail = parts.count >= 3 ? parts[2...] .joined(separator: "|") : ""
        return StatusRecord(state: parts[0], epoch: epoch, detail: detail)
    }
}

/// Atomic read/write store for `status/<name>` files.
public final class StatusStore {
    public let directory: String
    private let queue = DispatchQueue(label: "magpie.statusstore")

    public init(directory: String) throws {
        self.directory = directory
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    public func filePath(for name: String) -> String {
        directory + "/" + name
    }

    /// Read one target's status; nil when the file is missing or unparseable.
    public func read(name: String) -> StatusRecord? {
        guard let text = try? String(contentsOfFile: filePath(for: name), encoding: .utf8) else { return nil }
        return StatusRecord.parse(text)
    }

    /// Read every `status/<name>` file in the directory.
    public func readAll() -> [String: StatusRecord] {
        var result: [String: StatusRecord] = [:]
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return result }
        for entry in entries.sorted() {
            guard !entry.hasPrefix(".") else { continue }
            if let record = read(name: entry) {
                result[entry] = record
            }
        }
        return result
    }

    /// Atomically write a status file (tmp file + `rename(2)`, exactly like the
    /// legacy daemon's `printf > tmp && mv tmp final`). `rename` atomically
    /// replaces an existing file, unlike `FileManager.moveItem`.
    public func write(name: String, record: StatusRecord) {
        queue.sync {
            let final = filePath(for: name)
            let tmp = final + ".tmp.\(getpid())"
            let data = record.serialized.data(using: .utf8)!
            if FileManager.default.createFile(atPath: tmp, contents: data) {
                _ = rename(tmp, final)
            }
        }
    }

    /// Remove a target's status file (e.g. target deleted from config).
    public func remove(name: String) {
        queue.sync {
            try? FileManager.default.removeItem(atPath: filePath(for: name))
        }
    }
}
