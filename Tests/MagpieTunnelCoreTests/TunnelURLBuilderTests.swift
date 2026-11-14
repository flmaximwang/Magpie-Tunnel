import XCTest
@testable import MagpieTunnelCore

final class TunnelURLBuilderTests: XCTestCase {
    func testURLWithKeyUsesKParameter() {
        let target = TargetConfig(name: "TC2C4G2026", localPort: 3430,
                                  sshTarget: "ubuntu@43.142.18.254", remotePort: 3430,
                                  webKey: "3bdf4869eb195854f1f322fee217dc6c")
        XCTAssertEqual(TunnelURLBuilder.url(for: target),
                       "http://127.0.0.1:3430/?k=3bdf4869eb195854f1f322fee217dc6c")
    }

    func testURLWithoutKeyHasNoQuery() {
        let target = TargetConfig(name: "ZLab4090D", localPort: 3431,
                                  sshTarget: "wangfanlin1@100.68.85.3", remotePort: 3430, webKey: "")
        XCTAssertEqual(TunnelURLBuilder.url(for: target), "http://127.0.0.1:3431/")
    }

    func testNeverUsesKeyEqualsParameterName() {
        for key in ["abc", "", "3bdf4869eb195854f1f322fee217dc6c"] {
            let target = TargetConfig(name: "t", localPort: 3430, sshTarget: "h", remotePort: 3430, webKey: key)
            let url = TunnelURLBuilder.url(for: target)
            XCTAssertFalse(url.contains("?key="), "URL must never use ?key=: \(url)")
            XCTAssertFalse(url.contains("&key="), "URL must never use &key=: \(url)")
            XCTAssertTrue(url.hasPrefix("http://127.0.0.1:3430/"), "URL must target loopback: \(url)")
        }
    }

    func testWhitespaceOnlyKeyTreatedAsKeyless() {
        let target = TargetConfig(name: "t", localPort: 3430, sshTarget: "h", remotePort: 3430, webKey: "   ")
        XCTAssertEqual(TunnelURLBuilder.url(for: target), "http://127.0.0.1:3430/")
    }

    func testKeyWithReservedCharactersIsPercentEncoded() {
        let target = TargetConfig(name: "t", localPort: 3430, sshTarget: "h", remotePort: 3430, webKey: "a b&c")
        XCTAssertEqual(TunnelURLBuilder.url(for: target), "http://127.0.0.1:3430/?k=a%20b%26c")
    }

    func testHexKeyIsNotEscaped() {
        let target = TargetConfig(name: "t", localPort: 20001, sshTarget: "h", remotePort: 3430, webKey: "deadBEEF123-_.")
        XCTAssertEqual(TunnelURLBuilder.url(for: target), "http://127.0.0.1:20001/?k=deadBEEF123-_.")
    }

    func testHostPortLabel() {
        let target = TargetConfig(name: "t", localPort: 3430, sshTarget: "h", remotePort: 3430, webKey: "k")
        XCTAssertEqual(TunnelURLBuilder.hostPort(for: target), "localhost:3430")
    }
}
