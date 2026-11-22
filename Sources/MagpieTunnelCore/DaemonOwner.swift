import Foundation

/// Which app process owns the running daemon.
///
/// The menu-bar app is the sole owner of the daemon and every tunnel. The daemon
/// records `<lockDir>/daemon.owner` at startup (`daemonPID|appPID|epoch`), so a
/// relaunched app can tell "my daemon, adopted" from "a daemon left over from a
/// previous run, which must be replaced". The daemon also watches the recorded app
/// PID and shuts itself down when the app dies — including a crash or a force quit.
public struct DaemonOwner: Equatable {
    public let daemonPID: Int32
    public let appPID: Int32
    public let epoch: Int

    public init(daemonPID: Int32, appPID: Int32, epoch: Int = Int(Date().timeIntervalSince1970)) {
        self.daemonPID = daemonPID
        self.appPID = appPID
        self.epoch = epoch
    }

    public var serialized: String { "\(daemonPID)|\(appPID)|\(epoch)\n" }

    public static func parse(_ text: String?) -> DaemonOwner? {
        guard let line = text?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else { return nil }
        let parts = line.components(separatedBy: "|")
        guard parts.count >= 2,
              let daemonPID = Int32(parts[0]), daemonPID > 0,
              let appPID = Int32(parts[1]), appPID > 0 else { return nil }
        let epoch = parts.count > 2 ? (Int(parts[2]) ?? 0) : 0
        return DaemonOwner(daemonPID: daemonPID, appPID: appPID, epoch: epoch)
    }

    public static func read(path: String) -> DaemonOwner? {
        parse(try? String(contentsOfFile: path, encoding: .utf8))
    }

    /// Write atomically so the app never reads a half-written record.
    public static func write(_ owner: DaemonOwner, to path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }
        let tmp = path + ".tmp.\(getpid())"
        try owner.serialized.write(toFile: tmp, atomically: false, encoding: .utf8)
        guard rename(tmp, path) == 0 else {
            try? FileManager.default.removeItem(atPath: tmp)
            throw NSError(domain: "MagpieTunnelCore.DaemonOwner", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法写入 \(path)"])
        }
    }

    public static func remove(path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}
