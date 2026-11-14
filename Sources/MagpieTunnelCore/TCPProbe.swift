import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// TCP loopback probe used to decide whether an `ssh -L` forward is ready —
/// the Swift equivalent of the legacy bash `probe()` / `/dev/tcp` check.
public enum TCPProbe {
    /// Returns true when a TCP connection to `host:port` succeeds within `timeout`.
    public static func canConnect(host: String = "127.0.0.1", port: Int, timeout: TimeInterval = 1.0) -> Bool {
        guard port > 0, port <= 65535 else { return false }

        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        // Non-blocking for a bounded connect.
        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }

        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if connectResult == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pollfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&pollfd, 1, Int32(timeout * 1000))
        guard ready > 0 else { return false }

        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(sock, SOL_SOCKET, SO_ERROR, &error, &length)
        return error == 0
    }
}
