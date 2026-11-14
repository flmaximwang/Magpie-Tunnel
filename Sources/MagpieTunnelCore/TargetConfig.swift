import Foundation

/// One row of `targets.conf`: `名字|本机端口|ssh目标|远端端口|web key`。
/// The 5th field (web key) may be empty, in which case the row keeps its
/// trailing `|` exactly like the legacy files do.
public struct TargetConfig: Equatable, Hashable, Codable {
    public var name: String
    public var localPort: Int
    public var sshTarget: String
    public var remotePort: Int
    public var webKey: String

    public init(name: String, localPort: Int, sshTarget: String, remotePort: Int, webKey: String = "") {
        self.name = name
        self.localPort = localPort
        self.sshTarget = sshTarget
        self.remotePort = remotePort
        self.webKey = webKey
    }

    /// The exact `targets.conf` line for this target.
    /// With an empty key this produces `name|port|ssh|rport|` (trailing `|`),
    /// byte-identical to the legacy configuration files.
    public var confLine: String {
        [name, String(localPort), sshTarget, String(remotePort), webKey].joined(separator: "|")
    }

    /// Built-in defaults mirroring the legacy bash daemon. Used only when the
    /// configuration file does not exist at all (fresh install); an existing
    /// file with zero targets intentionally runs zero tunnels.
    public static let builtInDefaults: [TargetConfig] = [
        TargetConfig(
            name: "TC2C4G2026",
            localPort: 3430,
            sshTarget: "ubuntu@43.142.18.254",
            remotePort: 3430,
            webKey: "3bdf4869eb195854f1f322fee217dc6c"
        ),
        TargetConfig(
            name: "ZLab4090D",
            localPort: 3431,
            sshTarget: "wangfanlin1@100.68.85.3",
            remotePort: 3430,
            webKey: ""
        ),
    ]
}
