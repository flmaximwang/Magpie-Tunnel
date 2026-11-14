import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Prevents two daemon instances from running at once.
///
/// Primary mechanism: an `flock(2)`-protected PID file. A second `tryAcquire`
/// fails fast while the first holder lives — even across crashes, because the
/// kernel drops the advisory lock when the process dies.
///
/// Backwards compatibility: the legacy bash daemon used a *directory* lock at
/// `<support>/tunnel.lock` containing a `pid` file. When `legacyLockDirectory`
/// is set, acquisition first checks that location: a live legacy PID blocks us
/// (so old and new daemons never overlap), a stale one is cleaned up.
public final class SingleInstanceLock {
    public let lockFilePath: String
    public let legacyLockDirectory: String?
    /// PID of the other live instance discovered by the last failed `tryAcquire`.
    public private(set) var otherPID: Int32?

    private var fd: Int32 = -1

    public init(lockFilePath: String, legacyLockDirectory: String? = nil) {
        self.lockFilePath = lockFilePath
        self.legacyLockDirectory = legacyLockDirectory
    }

    deinit {
        release()
    }

    /// Try to become the single instance. `false` means another live daemon
    /// holds the lock (ours or the legacy one).
    public func tryAcquire() -> Bool {
        otherPID = nil

        // 1. Legacy mkdir-lock interop: a live legacy daemon must block us.
        if let legacy = legacyLockDirectory {
            let pidFile = legacy + "/pid"
            if FileManager.default.fileExists(atPath: legacy) {
                if let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
                   let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                   Self.isAlive(pid) {
                    otherPID = pid
                    return false
                }
                // Stale legacy lock: remove just that directory.
                try? FileManager.default.removeItem(atPath: legacy)
            }
        }

        // 2. flock-based PID file.
        let parent = (lockFilePath as NSString).deletingLastPathComponent
        if !parent.isEmpty {
            try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }
        let newFD = open(lockFilePath, O_RDWR | O_CREAT, 0o644)
        guard newFD >= 0 else { return false }
        let result = flock(newFD, LOCK_EX | LOCK_NB)
        if result != 0 {
            otherPID = readPID(from: newFD)
            close(newFD)
            return false
        }

        // We hold it — record our PID (truncate + write at offset 0).
        ftruncate(newFD, 0)
        lseek(newFD, 0, SEEK_SET)
        let pidText = "\(getpid())\n"
        pidText.withCString { ptr in
            _ = write(newFD, ptr, strlen(ptr))
        }
        fd = newFD
        return true
    }

    /// Release the lock (idempotent; also safe from deinit).
    public func release() {
        guard fd >= 0 else { return }
        unlink(lockFilePath)
        close(fd)
        fd = -1
    }

    /// PID currently recorded in the lock file on disk, if any.
    public func recordedPID() -> Int32? {
        guard let text = try? String(contentsOfFile: lockFilePath, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func readPID(from fd: Int32) -> Int32? {
        var buffer = [UInt8](repeating: 0, count: 64)
        lseek(fd, 0, SEEK_SET)
        let n = read(fd, &buffer, buffer.count - 1)
        guard n > 0 else { return nil }
        buffer[n] = 0
        let text = String(decoding: buffer[0..<n], as: UTF8.self)
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `kill(pid, 0)` liveness check; EPERM (other user) still counts as alive.
    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }
}
