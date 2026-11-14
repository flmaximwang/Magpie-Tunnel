import Foundation

/// All filesystem locations the daemon and the status app share, with the
/// legacy defaults under the user's home plus environment overrides
/// (`MAGPIE_TUNNEL_CONFIG`, `MAGPIE_TUNNEL_STATUS_DIR`, `MAGPIE_TUNNEL_LOG_DIR`,
/// `MAGPIE_TUNNEL_LOCK_DIR`, `MAGPIE_TUNNEL_SSH_BIN`) for isolated testing.
public struct TunnelPaths: Equatable {
    public var configPath: String
    public var statusDirectory: String
    public var logDirectory: String
    public var lockDirectory: String
    public var sshBinary: String

    public init(configPath: String, statusDirectory: String, logDirectory: String,
                lockDirectory: String, sshBinary: String = "/usr/bin/ssh") {
        self.configPath = configPath
        self.statusDirectory = statusDirectory
        self.logDirectory = logDirectory
        self.lockDirectory = lockDirectory
        self.sshBinary = sshBinary
    }

    /// Default layout, byte-compatible with the legacy bash daemon:
    /// support dir `~/Library/Application Support/MagpieWebTunnel`, logs in `~/Library/Logs`.
    public static func defaults(home: String = NSHomeDirectory(),
                                environment: [String: String] = ProcessInfo.processInfo.environment) -> TunnelPaths {
        let support = home + "/Library/Application Support/MagpieWebTunnel"
        return TunnelPaths(
            configPath: environment["MAGPIE_TUNNEL_CONFIG"] ?? support + "/targets.conf",
            statusDirectory: environment["MAGPIE_TUNNEL_STATUS_DIR"] ?? support + "/status",
            logDirectory: environment["MAGPIE_TUNNEL_LOG_DIR"] ?? home + "/Library/Logs",
            lockDirectory: environment["MAGPIE_TUNNEL_LOCK_DIR"] ?? support,
            sshBinary: environment["MAGPIE_TUNNEL_SSH_BIN"] ?? "/usr/bin/ssh"
        )
    }

    /// Total log: `<logDir>/magpie-web-tunnel.log` (same name as legacy).
    public var mainLogPath: String { logDirectory + "/magpie-web-tunnel.log" }

    /// Per-target log: `<logDir>/magpie-web-tunnel-<name>.log` (same as legacy).
    public func targetLogPath(name: String) -> String {
        logDirectory + "/magpie-web-tunnel-" + name + ".log"
    }

    /// New flock-based PID file for the Swift daemon.
    public var lockFilePath: String { lockDirectory + "/tunneld.lock" }

    /// Legacy bash daemon's mkdir lock, watched for interoperability.
    public var legacyLockDirectory: String { lockDirectory + "/tunnel.lock" }
}
