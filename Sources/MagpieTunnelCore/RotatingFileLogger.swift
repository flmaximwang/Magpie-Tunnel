import Foundation

/// File logger with legacy-compatible 2 MB rotation: when the file grows past
/// `maxBytes` it is moved to `<path>.1` (replacing any previous `.1`) and
/// logging continues in a fresh file. Thread-safe.
public final class RotatingFileLogger {
    public let filePath: String
    public let maxBytes: Int
    private let lock = NSLock()
    private var handle: FileHandle?

    /// Legacy threshold used by the bash daemon: 2 * 1024 * 1024 bytes.
    public static let legacyMaxBytes = 2 * 1024 * 1024

    public init(filePath: String, maxBytes: Int = RotatingFileLogger.legacyMaxBytes) throws {
        self.filePath = filePath
        self.maxBytes = maxBytes
        let parent = (filePath as NSString).deletingLastPathComponent
        if !parent.isEmpty {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }
        if !FileManager.default.createFile(atPath: filePath, contents: nil) {
            throw NSError(domain: "MagpieTunnelCore.RotatingFileLogger", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建日志文件 \(filePath)"])
        }
        self.handle = FileHandle(forWritingAtPath: filePath)
        self.handle?.seekToEndOfFile()
    }

    deinit {
        try? handle?.close()
    }

    /// Append one line with a legacy-style local timestamp: `[YYYY-MM-DD HH:MM:SS] message`.
    public func log(_ message: String) {
        write("[" + Self.timestamp() + "] " + message + "\n")
    }

    /// Append raw text without timestamp or newline.
    public func write(_ text: String) {
        guard let data = text.data(using: .utf8), !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        rotateIfNeededLocked()
        handle?.write(data)
    }

    /// Rotate now if the current file exceeds `maxBytes`.
    public func rotateIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        rotateIfNeededLocked()
    }

    private func rotateIfNeededLocked() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
              let size = attrs[.size] as? Int, size > maxBytes else { return }
        try? handle?.close()
        handle = nil
        let rotated = filePath + ".1"
        try? FileManager.default.removeItem(atPath: rotated)
        try? FileManager.default.moveItem(atPath: filePath, toPath: rotated)
        FileManager.default.createFile(atPath: filePath, contents: nil)
        handle = FileHandle(forWritingAtPath: filePath)
    }

    /// Local-time timestamp matching the legacy `date '+%Y-%m-%d %H:%M:%S'`.
    public static func timestamp(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
