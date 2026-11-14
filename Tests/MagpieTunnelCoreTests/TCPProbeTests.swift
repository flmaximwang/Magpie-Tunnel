import XCTest
@testable import MagpieTunnelCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class TCPProbeTests: XCTestCase {
    /// Bind port 0, learn the ephemeral port, close — returns a free port.
    func freePort() -> Int {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        precondition(sock >= 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(bindResult == 0)
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = getsockname(sock, sa, &len)
            }
        }
        let port = Int(UInt16(bigEndian: bound.sin_port))
        close(sock)
        return port
    }

    var listener: Process!

    /// Start `/usr/bin/nc -l 127.0.0.1 <port>` as a throwaway listener.
    func startListener(port: Int) throws -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        proc.arguments = ["-l", "127.0.0.1", String(port)]
        try proc.run()
        // Give nc a moment to bind.
        Thread.sleep(forTimeInterval: 0.3)
        return proc
    }

    override func tearDown() {
        listener?.terminate()
        listener?.waitUntilExit()
        listener = nil
        super.tearDown()
    }

    func testProbeSucceedsAgainstOpenPort() throws {
        let port = freePort()
        listener = try startListener(port: port)
        XCTAssertTrue(TCPProbe.canConnect(port: port, timeout: 2.0))
    }

    func testProbeFailsAgainstClosedPort() {
        let port = freePort()
        XCTAssertFalse(TCPProbe.canConnect(port: port, timeout: 0.5))
    }

    func testProbeRejectsInvalidPorts() {
        XCTAssertFalse(TCPProbe.canConnect(port: 0))
        XCTAssertFalse(TCPProbe.canConnect(port: 70000))
        XCTAssertFalse(TCPProbe.canConnect(port: -5))
    }
}
