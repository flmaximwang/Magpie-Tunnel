import Foundation

/// Builds the local browser URL for a tunnel target.
///
/// Invariant (backwards compatible with the legacy menu app and README):
/// `http://127.0.0.1:<local_port>/?k=<web_key>` and, when the key is empty,
/// `http://127.0.0.1:<local_port>/`. Magpie web only accepts the query
/// parameter name `k` — never `?key=` (that returns 401).
public enum TunnelURLBuilder {
    public static let host = "127.0.0.1"

    /// Full URL with key: `http://127.0.0.1:<port>/?k=<key>`; keyless: `http://127.0.0.1:<port>/`.
    public static func url(for target: TargetConfig) -> String {
        let base = "http://\(host):\(target.localPort)/"
        let key = target.webKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return base }
        return base + "?k=" + encodeKey(key)
    }

    /// Short menu label like `localhost:3430`.
    public static func hostPort(for target: TargetConfig) -> String {
        "localhost:\(target.localPort)"
    }

    /// Percent-encode a web key. Keys are normally alphanumeric hex, in which
    /// case this is the identity mapping; anything reserved still produces a
    /// valid URL component.
    static func encodeKey(_ key: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
    }
}
