import Foundation

/// Stable, dependency-free content digest used to tie a reload request to the
/// exact file text the app just wrote. FNV-1a/64 over UTF-8 bytes: fast, stable
/// across processes and platforms, and never used for anything security-related.
public enum ConfigDigest {
    public static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}

/// Reload request/acknowledgement files exchanged between the menu-bar app and
/// its daemon, used to make "save and apply" immediate and provable.
///
/// The app writes `<lockDir>/reload.request` after saving, then waits for
/// `<lockDir>/reload.ack` carrying the same request id and digest. A daemon that
/// dies before acknowledging simply leaves the app with "saved, not confirmed".
public struct ReloadRequest: Equatable {
    public let requestID: String
    public let digest: String

    public init(requestID: String, digest: String) {
        self.requestID = requestID
        self.digest = digest
    }

    public var serialized: String { requestID + "|" + digest + "\n" }

    public static func parse(_ text: String?) -> ReloadRequest? {
        guard let line = text?.split(separator: "\n").first else { return nil }
        let parts = line.components(separatedBy: "|")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return ReloadRequest(requestID: parts[0], digest: parts[1])
    }
}

/// The daemon's answer to one `ReloadRequest`.
public struct ReloadAck: Equatable {
    public enum Outcome: String {
        /// The daemon read the exact text the app wrote and reconciled targets.
        case applied
        /// The daemon read the config but could not use it (unreadable file).
        case failed
    }

    public let requestID: String
    public let digest: String
    public let outcome: Outcome
    public let targetCount: Int
    public let epoch: Int
    public let detail: String

    public init(requestID: String, digest: String, outcome: Outcome,
                targetCount: Int, epoch: Int = Int(Date().timeIntervalSince1970),
                detail: String = "") {
        self.requestID = requestID
        self.digest = digest
        self.outcome = outcome
        self.targetCount = targetCount
        self.epoch = epoch
        self.detail = detail
    }

    public var serialized: String {
        "\(requestID)|\(digest)|\(outcome.rawValue)|\(targetCount)|\(epoch)|\(detail)\n"
    }

    public static func parse(_ text: String?) -> ReloadAck? {
        guard let line = text?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else { return nil }
        let parts = line.components(separatedBy: "|")
        guard parts.count >= 4,
              let outcome = Outcome(rawValue: parts[2]),
              let count = Int(parts[3]),
              let epoch = parts.count > 4 ? Int(parts[4]) : 0 else { return nil }
        let detail = parts.count > 5 ? parts[5...].joined(separator: "|") : ""
        return ReloadAck(requestID: parts[0], digest: parts[1], outcome: outcome,
                         targetCount: count, epoch: epoch, detail: detail)
    }
}

/// Filesystem rendezvous for reload requests and acks.
public final class ReloadCoordinator {
    public let requestPath: String
    public let ackPath: String

    public init(lockDirectory: String) {
        requestPath = lockDirectory + "/reload.request"
        ackPath = lockDirectory + "/reload.ack"
    }

    public func writeRequest(_ request: ReloadRequest) throws {
        try writeAtomically(request.serialized, to: requestPath)
    }

    public func readRequest() -> ReloadRequest? {
        ReloadRequest.parse(try? String(contentsOfFile: requestPath, encoding: .utf8))
    }

    public func writeAck(_ ack: ReloadAck) throws {
        try writeAtomically(ack.serialized, to: ackPath)
    }

    public func readAck() -> ReloadAck? {
        ReloadAck.parse(try? String(contentsOfFile: ackPath, encoding: .utf8))
    }

    /// Remove the rendezvous files (called when the app gives up waiting, so the
    /// daemon does not answer a request nobody is listening for).
    public func clear() {
        try? FileManager.default.removeItem(atPath: requestPath)
        try? FileManager.default.removeItem(atPath: ackPath)
    }

    private func writeAtomically(_ text: String, to path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }
        let tmp = path + ".tmp.\(getpid())"
        try text.write(toFile: tmp, atomically: false, encoding: .utf8)
        guard rename(tmp, path) == 0 else {
            try? FileManager.default.removeItem(atPath: tmp)
            throw NSError(domain: "MagpieTunnelCore.ReloadCoordinator", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法写入 \(path)"])
        }
    }
}
