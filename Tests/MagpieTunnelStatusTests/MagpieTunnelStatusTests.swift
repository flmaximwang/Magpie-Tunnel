import XCTest
@testable import MagpieTunnelCore

// Placeholder suite — real menu model tests arrive with magpie-tunnel-4nm.3.
final class MagpieTunnelStatusPlaceholderTests: XCTestCase {
    func testCoreIsLinked() {
        XCTAssertFalse(TargetConfig.builtInDefaults.isEmpty)
    }
}
