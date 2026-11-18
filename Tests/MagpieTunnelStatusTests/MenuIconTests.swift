import AppKit
import XCTest
@testable import MagpieTunnelStatus

/// Guards the two properties the status item actually depends on: the artwork
/// resolves (never empty) and both Retina representations are in the image.
final class MenuIconTests: XCTestCase {
    func testBothStatesProduceATemplateImageAt18Points() {
        for state in MenuIconState.allCases {
            let image = MenuIcon.image(for: state)
            XCTAssertEqual(image.size, MenuIcon.pointSize)
            XCTAssertTrue(image.isTemplate, "模板图才会被菜单栏按浅/深色自动着色")
            XCTAssertFalse(image.representations.isEmpty)
        }
    }

    func testRetinaAndOneXRepresentationsAreBothPresent() {
        let image = MenuIcon.image(for: .healthy)
        let pixels = image.representations.compactMap { rep -> Int? in
            guard let bitmap = rep as? NSBitmapImageRep else { return nil }
            return bitmap.pixelsWide
        }
        XCTAssertEqual(pixels.sorted(), [18, 36], "18 px + 36 px(@2x) 两档都要在，Retina 才不会放大")
    }

    func testArtworkIsPureBlackWithAlpha() throws {
        // Template images must carry shape in alpha only; a coloured glyph
        // would be tinted into a muddy grey by AppKit.
        for state in MenuIconState.allCases {
            let image = MenuIcon.image(for: state)
            guard let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first else {
                return XCTFail("没有位图表征")
            }
            var maxRed: CGFloat = 0
            var minAlpha: CGFloat = 1
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    // The PNG is greyscale+alpha; NSColor only exposes RGB
                    // components after an explicit colour-space conversion.
                    guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    maxRed = max(maxRed, colour.redComponent)
                    minAlpha = min(minAlpha, colour.alphaComponent)
                }
            }
            XCTAssertEqual(maxRed, 0, accuracy: 0.001, "\(state) 有非黑像素")
            XCTAssertLessThan(minAlpha, 0.5, "\(state) 缺少形状（alpha 全不透明）")
        }
    }

    func testCachedImageIsReusedForTheSameState() {
        // rebuildMenu runs every refresh tick; re-decoding PNGs there would be
        // pointless I/O at 10 s intervals.
        let first = MenuIcon.image(for: .degraded)
        let second = MenuIcon.image(for: .degraded)
        XCTAssertTrue(first === second)
    }
}
