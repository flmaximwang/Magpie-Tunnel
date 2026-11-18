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

    /// Safety net: if the artwork is missing, draw the same idea in code — an
    /// arch with a perched bird whose tail fills (healthy) or splits (degraded)
    /// the opening — so the status item never renders empty.
    private static func fallbackImage(for state: MenuIconState) -> NSImage {
        let image = NSImage(size: pointSize, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            // Portal: two legs and a rounded crown.
            let arch = NSBezierPath()
            arch.move(to: NSPoint(x: rect.minX + rect.width * 0.27, y: rect.maxY))
            arch.line(to: NSPoint(x: rect.minX + rect.width * 0.27, y: rect.maxY - rect.height * 0.42))
            arch.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.maxY - rect.height * 0.42),
                           radius: rect.width * 0.23, startAngle: 180, endAngle: 0)
            arch.line(to: NSPoint(x: rect.minX + rect.width * 0.73, y: rect.maxY))
            arch.lineWidth = rect.width * 0.09
            arch.lineCapStyle = .round
            arch.stroke()

            // Bird: body + head on the crown.
            let body = NSBezierPath(ovalIn: NSRect(x: rect.minX + rect.width * 0.37,
                                                   y: rect.maxY - rect.height * 0.42,
                                                   width: rect.width * 0.34,
                                                   height: rect.height * 0.26))
            body.fill()
            let head = NSBezierPath(ovalIn: NSRect(x: rect.minX + rect.width * 0.63,
                                                   y: rect.maxY - rect.height * 0.36,
                                                   width: rect.width * 0.19,
                                                   height: rect.height * 0.19))
            head.fill()

            // Tail: solid when healthy, split in two when degraded.
            let segments: [(CGFloat, CGFloat)] = state == .healthy
                ? [(0.90, 1.0)]
                : [(0.76, 0.88), (0.99, 1.0)]
            for (from, to) in segments {
                let feather = NSBezierPath()
                feather.move(to: NSPoint(x: rect.minX + rect.width * 0.50,
                                         y: rect.maxY - rect.height * from))
                feather.line(to: NSPoint(x: rect.minX + rect.width * 0.56,
                                         y: rect.maxY - rect.height * to))
                feather.lineWidth = rect.width * 0.11
                feather.lineCapStyle = .round
                feather.stroke()
            }
            return true
        }
        return image
    }
}
