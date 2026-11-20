import AppKit
import Foundation

/// Renders the template artwork into an `NSImage` for the status item.
///
/// The artwork is a "template image": black with alpha only, so AppKit tints it
/// for light and dark menu bars automatically. Caching by state matters because
/// `rebuildMenu` runs on the 10 s refresh timer.
enum MenuIcon {
    /// Nominal size of the status-item artwork. The menu bar gives a status item
    /// roughly 22 pt of height; keeping the image at 18 pt leaves the same
    /// optical breathing room the neighbouring Wi-Fi / Bluetooth glyphs have.
    static let pointSize = NSSize(width: 18, height: 18)

    private static var cache: [MenuIconState: NSImage] = [:]

    static func image(for state: MenuIconState) -> NSImage {
        if let cached = cache[state] { return cached }
        let image = render(state) ?? fallbackImage(for: state)
        image.isTemplate = true
        cache[state] = image
        return image
    }

    /// Builds one `NSImage` holding both the 1x and the @2x representation, so
    /// the glyph stays crisp on a Retina menu bar instead of being upscaled.
    /// PNGs live in `Contents/Resources` of the app bundle; the `#filePath`
    /// based lookup keeps the same artwork reachable when running the SwiftPM
    /// binary straight out of `.build`.
    private static func render(_ state: MenuIconState) -> NSImage? {
        let image = NSImage(size: pointSize)
        var added = false
        for suffix in ["", "@2x"] {
            let path = artworkPath(for: state, suffix: suffix)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let rep = NSBitmapImageRep(data: data) else { continue }
            // Both reps claim 18 pt; the 36 px one is 2x. AppKit picks it on
            // a Retina bar, so the glyph is never upscaled.
            rep.size = pointSize
            image.addRepresentation(rep)
            added = true
        }
        return added ? image : nil
    }

    private static func artworkPath(for state: MenuIconState, suffix: String) -> String {
        let fileName = "MenuIcon-\(state.rawValue)\(suffix).png"
        let candidates = [
            // Inside an app bundle: Contents/MacOS/<binary> → ../Resources
            Bundle.main.resourcePath.map { $0 + "/" + fileName },
            // SwiftPM layout: .build/<config>/<binary> → ../../../resources/icon
            repoRoot() + "/resources/icon/" + fileName,
        ]
        for candidate in candidates.compactMap({ $0 }) where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        return Bundle.main.resourcePath.map { $0 + "/" + fileName } ?? fileName
    }

    private static func repoRoot() -> String {
        let thisFile = (#filePath as NSString).deletingLastPathComponent // .../Sources/MagpieTunnelStatus
        return thisFile.components(separatedBy: "/").dropLast(2).joined(separator: "/")
    }

    /// Draw the SVG silhouettes in their 36-unit coordinate space if the PNGs
    /// are missing, including the tail gap for the degraded state.
    private static func fallbackImage(for state: MenuIconState) -> NSImage {
        NSImage(size: pointSize, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: rect.width / 36, y: rect.height / 36)
            context.setStrokeColor(gray: 0, alpha: 1)
            context.setFillColor(gray: 0, alpha: 1)

            // Rounded-square portal frame: outer rounded square, inner arch on
            // the old stroke centreline, round-cap pillar feet (each pillar
            // symmetric about its own axis). One connected loop, filled.
            context.move(to: CGPoint(x: 10, y: 1))
            context.addLine(to: CGPoint(x: 26, y: 1))
            context.addArc(center: CGPoint(x: 26, y: 10), radius: 9,
                           startAngle: -.pi / 2, endAngle: 0, clockwise: false)
            context.addLine(to: CGPoint(x: 35, y: 33))
            context.addArc(center: CGPoint(x: 33, y: 33), radius: 2,
                           startAngle: 0, endAngle: .pi, clockwise: false)
            context.addLine(to: CGPoint(x: 31, y: 17))
            context.addArc(center: CGPoint(x: 18, y: 17), radius: 13,
                           startAngle: 0, endAngle: .pi, clockwise: true)
            context.addLine(to: CGPoint(x: 5, y: 33))
            context.addArc(center: CGPoint(x: 3, y: 33), radius: 2,
                           startAngle: 0, endAngle: .pi, clockwise: false)
            context.addLine(to: CGPoint(x: 1, y: 10))
            context.addArc(center: CGPoint(x: 10, y: 10), radius: 9,
                           startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: false)
            context.closePath()
            context.fillPath()

            context.move(to: CGPoint(x: 10, y: 10))
            context.addLine(to: CGPoint(x: 18.4, y: 15.6))
            context.addLine(to: CGPoint(x: 20.3, y: 12.9))
            context.addQuadCurve(to: CGPoint(x: 25.1, y: 12.5), control: CGPoint(x: 22.4, y: 9.9))
            context.addLine(to: CGPoint(x: 27, y: 12.6))
            context.addLine(to: CGPoint(x: 25.7, y: 15))
            context.addQuadCurve(to: CGPoint(x: 18.9, y: 22.4), control: CGPoint(x: 24.5, y: 20.9))
            if state == .healthy {
                context.addLine(to: CGPoint(x: 10, y: 29))
                context.addLine(to: CGPoint(x: 12.3, y: 23))
            } else {
                context.addLine(to: CGPoint(x: 17.9, y: 23.1))
                context.addLine(to: CGPoint(x: 14.4, y: 20.5))
            }
            context.addLine(to: CGPoint(x: 15, y: 19.8))
            context.addQuadCurve(to: CGPoint(x: 10, y: 10), control: CGPoint(x: 11.2, y: 16.3))
            context.closePath()
            if state == .degraded {
                context.addLines(between: [CGPoint(x: 11.7, y: 24.5), CGPoint(x: 14.1, y: 26), CGPoint(x: 10, y: 29)])
                context.closePath()
            }
            context.fillPath()
            return true
        }
    }
}
