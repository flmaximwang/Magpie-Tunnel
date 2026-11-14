import XCTest
@testable import MagpieTunnelCore

// Placeholder suite — real daemon integration tests arrive with magpie-tunnel-4nm.2.
final class MagpieTunnelDaemonPlaceholderTests: XCTestCase {
    func testCoreIsLinked() {
        XCTAssertEqual(TargetConfig.builtInDefaults.count, 2)
    }
}
