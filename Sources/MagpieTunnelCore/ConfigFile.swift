import Foundation

/// A point-in-time view of `targets.conf` on disk.
///
/// The editor keeps one of these from the last read/write and compares it with
/// the file before saving: any external change (a different inode, size or
/// modification date) means the draft must not silently overwrite someone
/// else's edit.
public struct ConfigFileSnapshot: Equatable {
    public let path: String
    /// File content, or empty when the file does not exist.
    public let text: String
    public let exists: Bool
    /// `(device, inode, size, mtime)` of the file when it was read; nil when absent.
    public let identity: FileIdentity?

    public struct FileIdentity: Equatable {
        public let device: Int64
        public let inode: UInt64
        public let size: UInt64
        public let modifiedNanoseconds: Int64
    }

    public init(path: String, text: String, exists: Bool, identity: FileIdentity?) {
        self.path = path
        self.text = text
        self.exists = exists
        self.identity = identity
    }

    /// Read a snapshot. Throws only when a file exists but cannot be read.
    public static func read(path: String) throws -> ConfigFileSnapshot {
        var info = stat()
        guard stat(path, &info) == 0 else {
            return ConfigFileSnapshot(path: path, text: "", exists: false, identity: nil)
        }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw NSError(domain: "MagpieTunnelCore.ConfigFile", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "配置文件 \(path) 无法读取"])
        }
        let modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return ConfigFileSnapshot(
            path: path,
            text: text,
            exists: true,
            identity: FileIdentity(device: Int64(info.st_dev),
                                   inode: UInt64(info.st_ino),
                                   size: UInt64(info.st_size),
                                   modifiedNanoseconds: modified))
    }

    /// Whether the file on disk changed since this snapshot was taken.
    public func isStale() -> Bool {
        let current = (try? ConfigFileSnapshot.read(path: path))
            ?? ConfigFileSnapshot(path: path, text: "", exists: false, identity: nil)
        return current.exists != exists || current.identity != identity
    }

    /// Write draft text atomically (tmp file in the same directory + rename),
    /// so the daemon never reads a half-written configuration.
    @discardableResult
    public static func write(_ text: String, to path: String) throws -> ConfigFileSnapshot {
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }
        let tmp = path + ".tmp.\(getpid())"
        try text.write(toFile: tmp, atomically: false, encoding: .utf8)
        guard rename(tmp, path) == 0 else {
            try? FileManager.default.removeItem(atPath: tmp)
            throw NSError(domain: "MagpieTunnelCore.ConfigFile", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "无法写入配置文件 \(path)"])
        }
        return try read(path: path)
    }
}
