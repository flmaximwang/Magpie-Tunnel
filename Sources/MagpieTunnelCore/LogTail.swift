import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Text produced by one incremental read of a log file.
public struct LogChunk: Equatable {
    /// Newly appended text (may be empty).
    public let text: String
    /// True when the file was rotated or truncated since the previous read, so
    /// the text that follows is from a new file and the reader started over.
    public let didReset: Bool
    /// True on the very first read when the file was too large and the reader
    /// started partway through, dropping the leading partial line.
    public let didSkipHead: Bool

    public init(text: String, didReset: Bool = false, didSkipHead: Bool = false) {
        self.text = text
        self.didReset = didReset
        self.didSkipHead = didSkipHead
    }

    public static let empty = LogChunk(text: "")
}

/// Incremental reader for a log file that keeps up with rotation.
///
/// The log window shows the loaded text and appends everything that appeared
/// since the last read. Rotation is detected through the inode and a shrinking
/// size, at which point the reader restarts at the beginning of the new file.
public final class LogTailReader {
    public let path: String
    /// On the first read, only this many trailing bytes are loaded so a huge
    /// historical log does not stall the window.
    public let maxInitialBytes: Int

    private var offset: UInt64 = 0
    private var inode: UInt64 = 0
    private var primed = false

    public init(path: String, maxInitialBytes: Int = 256 * 1024) {
        self.path = path
        self.maxInitialBytes = max(1, maxInitialBytes)
    }

    public func reset() {
        offset = 0
        inode = 0
        primed = false
    }

    /// Read everything appended since the previous call.
    public func read() -> LogChunk {
        var info = stat()
        guard stat(path, &info) == 0 else {
            return .empty
        }
        let size = UInt64(info.st_size)
        let fileInode = UInt64(info.st_ino)

        var start = offset
        var didReset = false
        var didSkipHead = false

        if !primed {
            if size > UInt64(maxInitialBytes) {
                start = size - UInt64(maxInitialBytes)
                didSkipHead = true
            } else {
                start = 0
            }
        } else if fileInode != inode || size < offset {
            // Rotated (new inode) or truncated in place: start over.
            didReset = true
            primed = true
            if size > UInt64(maxInitialBytes) {
                start = size - UInt64(maxInitialBytes)
                didSkipHead = true
            } else {
                start = 0
            }
        }

        let hadPrevious = primed
        inode = fileInode
        primed = true
        if size < start { start = 0 }
        guard size > start else {
            offset = size
            return LogChunk(text: "", didReset: didReset && hadPrevious)
        }

        guard let handle = FileHandle(forReadingAtPath: path) else { return .empty }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: start)
        } catch {
            return .empty
        }
        let data = handle.readDataToEndOfFile()
        offset = start + UInt64(data.count)

        guard var text = String(data: data, encoding: .utf8) else { return .empty }
        if didSkipHead, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return LogChunk(text: text, didReset: didReset && hadPrevious, didSkipHead: didSkipHead)
    }
}

/// Owns the reader for the log source currently on screen and decides whether
/// switching to a source means the display has to be cleared.
///
/// Acceptance rules encoded here (the log window used to re-append the whole
/// file every time it was reopened, because `switchSource` always built a fresh
/// reader at offset 0 while the text view kept its old content):
/// - binding the same path again (reopening the window, or presenting it for
///   the same tunnel) keeps the existing reader and asks for no reset: nothing
///   is replayed, only lines appended since the previous read are returned;
/// - binding a different path — or the very first binding, when no reader
///   exists yet — creates a reader at offset zero and asks for a reset, so the
///   display shows only the new source;
/// - a rotated or truncated file is not a rebinding: the path stays the same,
///   `LogTailReader` reports `didReset`, and the window clears the display then.
public struct LogSourceFeed {
    /// Path of the source currently bound, nil before the first binding.
    public private(set) var path: String?
    private var storage: LogTailReader?

    public init() {}

    /// True once a reader exists, so `read()` has something to read from.
    public var isBound: Bool { storage != nil }

    /// True when binding to `path` would require clearing the displayed text,
    /// i.e. when `path` is not the source that is currently bound. A nil path
    /// (nothing to show) clears only when a reader is still held.
    public func shouldResetDisplay(for path: String?) -> Bool {
        guard let path else { return storage != nil }
        return self.path != path || storage == nil
    }

    /// Point the feed at `path`. Returns true when the caller must clear the
    /// displayed text (and its highlights) because a different source is now
    /// being shown; false when the same source is presented again. A nil path
    /// unbinds the feed, so the display is cleared too.
    @discardableResult
    public mutating func bind(path: String?) -> Bool {
        let reset = shouldResetDisplay(for: path)
        self.path = path
        if reset {
            storage = path.map { LogTailReader(path: $0) }
        }
        return reset
    }

    /// Everything appended since the previous read; `.empty` when unbound.
    public func read() -> LogChunk {
        storage?.read() ?? .empty
    }
}

/// Case-insensitive search over already loaded log text.
public enum LogSearch {
    /// Ranges of `query` inside `text`, capped at `limit` matches.
    public static func ranges(of query: String, in text: String, limit: Int = 500) -> [NSRange] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !text.isEmpty else { return [] }
        let haystack = text as NSString
        var results: [NSRange] = []
        var position = 0
        let length = haystack.length
        while position < length, results.count < limit {
            let found = haystack.range(of: needle,
                                       options: [.caseInsensitive, .diacriticInsensitive],
                                       range: NSRange(location: position, length: length - position))
            guard found.location != NSNotFound, found.length > 0 else { break }
            results.append(found)
            position = found.location + max(1, found.length)
        }
        return results
    }
}
