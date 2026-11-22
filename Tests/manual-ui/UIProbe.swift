import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO

// Small read-only probe used by ui_acceptance.sh. Every command prints one
// JSON object on stdout and exits non-zero only for usage errors, so the shell
// driver can keep going and report "unknown" instead of aborting.
//
// Commands:
//   trusted                       accessibility trust of *this* process
//   windows <pid> [--all]         CGWindowList entries owned by <pid>
//   image <png>                   pixel statistics of a screenshot
//   statusitem <pid>              AX frame of the menu-bar status item
//   pressitem <pid>               AXPress the status item itself (AXMenuBarItem)
//   obstructors <pid>             on-screen windows above the menu bar that cover
//                                 the status item (the click-swallowing case)
//   find <pid> <title>            AX frame of the first element with that title
//   press <pid> <title>           AXPress by title, for diagnostics only
//   click <x> <y>                 synthetic left click at screen coordinates
//   axhealth <pid> <titleSubstr>  element counts inside a window (layout health)
//   axlatency <pid> [n]           median/max AX query latency (main-thread health)
//   sample <pid> <seconds>        run `sample`, classify the main thread
//   logscan <pid>                 look for layout/exception signatures in the log
//   control <mode>                control windows for the screenshot experiments
//                                 (element | offorder | occluded)

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
    return value
}

func children(_ el: AXUIElement) -> [AXUIElement] {
    (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

func role(_ el: AXUIElement) -> String { (attr(el, kAXRoleAttribute as String) as? String) ?? "" }
func title(_ el: AXUIElement) -> String { (attr(el, kAXTitleAttribute as String) as? String) ?? "" }

func frame(_ el: AXUIElement) -> CGRect? {
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard let p = attr(el, kAXPositionAttribute as String), let s = attr(el, kAXSizeAttribute as String) else { return nil }
    AXValueGetValue(p as! AXValue, .cgPoint, &origin)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: origin, size: size)
}

func emit(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

func rounded(_ value: Double, _ places: Double = 10000) -> Double {
    (value * places).rounded() / places
}

// MARK: - window list

func windowList(pid: Int, all: Bool) -> [[String: Any]] {
    let options: CGWindowListOption = all
        ? [.optionAll, .excludeDesktopElements]
        : [.optionOnScreenOnly, .excludeDesktopElements]
    let infos = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
    var rows: [[String: Any]] = []
    for info in infos where (info[kCGWindowOwnerPID as String] as? Int) == pid {
        let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
        rows.append([
            "id": info[kCGWindowNumber as String] as? Int ?? -1,
            "layer": info[kCGWindowLayer as String] as? Int ?? -999,
            "onscreen": info[kCGWindowIsOnscreen as String] as? Bool ?? false,
            "alpha": (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? -1,
            "name": info[kCGWindowName as String] as? String ?? "",
            "x": (bounds["X"] as? NSNumber)?.doubleValue ?? 0,
            "y": (bounds["Y"] as? NSNumber)?.doubleValue ?? 0,
            "w": (bounds["Width"] as? NSNumber)?.doubleValue ?? 0,
            "h": (bounds["Height"] as? NSNumber)?.doubleValue ?? 0,
            "memory": info[kCGWindowMemoryUsage as String] as? Int ?? -1,
        ])
    }
    return rows
}

// MARK: - click obstruction

/// A synthetic click is delivered to the topmost window under the pointer.
/// Menu-bar items live just above the menu-bar window level; a window level
/// higher than that (screen-capture overlays, layer >= 1000 panels, some window
/// managers) receives the click instead, and the status item never opens.
///
/// Default threshold: one level above CGWindowLevelForKey(.mainMenuWindow), so
/// layers >= 1000 are always included. On the machine this was written for the
/// swallowing overlay sat at layer 25, just 1 above the menu bar (24) — a literal
/// `>= 1000` test would not have caught it.
func obstructors(pid: Int, minimumLayer: Int?, point: CGPoint?) -> [String: Any] {
    var target = point
    if target == nil {
        let app = application(Int32(pid))
        if let item = statusItemElement(app), let box = frame(item) {
            target = CGPoint(x: box.midX, y: box.midY)
        }
    }
    let base = Int(CGWindowLevelForKey(.mainMenuWindow))
    let threshold = minimumLayer ?? (base + 1)
    guard let probePoint = target else {
        return ["obstructed": false, "error": "no-status-item-frame",
                "minLayer": threshold, "menuBarLayer": base, "windows": []]
    }
    let infos = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                            kCGNullWindowID) as? [[String: Any]]) ?? []
    var rows: [[String: Any]] = []
    for info in infos {
        let layer = info[kCGWindowLayer as String] as? Int ?? -999
        guard layer >= threshold else { continue }
        let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let rect = CGRect(x: (bounds["X"] as? NSNumber)?.doubleValue ?? 0,
                          y: (bounds["Y"] as? NSNumber)?.doubleValue ?? 0,
                          width: (bounds["Width"] as? NSNumber)?.doubleValue ?? 0,
                          height: (bounds["Height"] as? NSNumber)?.doubleValue ?? 0)
        guard rect.width > 0, rect.height > 0, rect.contains(probePoint) else { continue }
        let owner = info[kCGWindowOwnerName as String] as? String ?? ""
        rows.append([
            "pid": info[kCGWindowOwnerPID as String] as? Int ?? -1,
            "owner": owner,
            "layer": layer,
            "bounds": "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))",
            "alpha": (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? -1,
        ])
    }
    return ["obstructed": !rows.isEmpty, "x": rounded(probePoint.x), "y": rounded(probePoint.y),
            "minLayer": threshold, "menuBarLayer": base, "windows": rows]
}

// MARK: - image statistics

func imageStats(path: String) -> [String: Any] {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return ["error": "cannot-read"]
    }
    let width = image.width, height = image.height
    var data = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return ["error": "no-context"]
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var opaque = 0, nearWhite = 0, nearBlack = 0
    var luma = 0.0, lumaSquared = 0.0
    var buckets = Set<Int>()
    for i in stride(from: 0, to: data.count, by: 4) {
        let alpha = Int(data[i + 3])
        if alpha > 8 { opaque += 1 }
        if alpha > 200 && data[i] >= 250 && data[i + 1] >= 250 && data[i + 2] >= 250 { nearWhite += 1 }
        if alpha > 200 && data[i] <= 5 && data[i + 1] <= 5 && data[i + 2] <= 5 { nearBlack += 1 }
        let value = 0.299 * Double(data[i]) + 0.587 * Double(data[i + 1]) + 0.114 * Double(data[i + 2])
        luma += value
        lumaSquared += value * value
        buckets.insert(Int(data[i] / 8) << 16 | Int(data[i + 1] / 8) << 8 | Int(data[i + 2] / 8))
    }
    let pixels = Double(width * height)
    let mean = luma / pixels
    return [
        "width": width, "height": height, "pixels": width * height,
        "opaqueRatio": rounded(Double(opaque) / pixels),
        "nearWhiteRatio": rounded(Double(nearWhite) / pixels),
        "nearBlackRatio": rounded(Double(nearBlack) / pixels),
        "meanLuma": rounded(mean, 10),
        "lumaStdDev": rounded(max(0, lumaSquared / pixels - mean * mean).squareRoot(), 100),
        "distinctColorBuckets": buckets.count,
    ]
}

// MARK: - accessibility

func application(_ pid: Int32) -> AXUIElement { AXUIElementCreateApplication(pid) }

/// LSUIElement apps don't answer kAXMenuBarAttribute on every OS build
/// (`-25212`), but the menu bar is always present in AXChildren.
func statusItemElement(_ app: AXUIElement) -> AXUIElement? {
    for child in children(app) where role(child) == kAXMenuBarRole as String {
        if let item = children(child).first { return item }
    }
    return nil
}

func findElement(_ el: AXUIElement, title wanted: String, depth: Int = 0) -> AXUIElement? {
    if depth > 24 { return nil }
    if title(el) == wanted { return el }
    for child in children(el) {
        if let hit = findElement(child, title: wanted, depth: depth + 1) { return hit }
    }
    return nil
}

func findWindow(_ el: AXUIElement, containing substring: String, depth: Int = 0) -> AXUIElement? {
    guard depth <= 12 else { return nil }
    if role(el) == kAXWindowRole as String, title(el).contains(substring) { return el }
    // Windows hang off kAXWindowsAttribute on the application element, not off
    // AXChildren, so both have to be walked.
    if depth == 0, let windows = attr(el, kAXWindowsAttribute as String) as? [AXUIElement] {
        for window in windows where title(window).contains(substring) { return window }
    }
    for child in children(el) {
        if let hit = findWindow(child, containing: substring, depth: depth + 1) { return hit }
    }
    return nil
}

func click(_ point: CGPoint) {
    let source = CGEventSource(stateID: .hidSystemState)
    func post(_ type: CGEventType, _ button: CGMouseButton) {
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)?
            .post(tap: .cghidEventTap)
    }
    CGWarpMouseCursorPosition(point)
    usleep(120_000)
    post(.mouseMoved, .left)
    usleep(40_000)
    post(.leftMouseDown, .left)
    usleep(90_000)
    post(.leftMouseUp, .left)
}

// MARK: - sample parsing

/// Parses one `sample` call graph line into (sampleCount, symbolName).
///
/// Lines look like `    + 773 -[NSApplication run]  (in AppKit) + 396`, where
/// the leading `+ ! : |` characters are ASCII art for the call tree, so the
/// frame counts have to be read from the line itself rather than counted per
/// occurrence (a recursive frame appears once with a large count).
func sampleLine(_ line: String) -> (count: Int, symbol: String)? {
    var rest = Substring(line)
    while let first = rest.first, "+!:| ".contains(first) { rest = rest.dropFirst() }
    guard let space = rest.firstIndex(of: " ") else { return nil }
    guard let count = Int(rest[rest.startIndex..<space]) else { return nil }
    let afterCount = rest[rest.index(after: space)...].trimmingCharacters(in: .whitespaces)
    guard afterCount.hasPrefix("-") || afterCount.hasPrefix("_") || afterCount.first?.isLetter == true
            || afterCount.first?.isNumber == true else { return nil }
    let symbol = afterCount.components(separatedBy: "  (in ").first ?? afterCount
    return (count, symbol)
}

func classifySample(path: String) -> [String: Any] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return ["error": "no-sample-file"] }
    let lines = text.components(separatedBy: "\n")
    // The main thread is labelled `com.apple.main-thread` while it only owns the
    // main queue, and `Main Thread  DispatchQueue_<multiple>` once a timer has
    // made it the target of more than one queue. Both are the same thread.
    guard let header = lines.firstIndex(where: { $0.contains("com.apple.main-thread") || $0.contains(": Main Thread") }) else {
        return ["verdict": "no-main-thread-symbol", "samplePath": path]
    }
    // The main-thread block ends where the next thread block starts.
    var block: [String] = []
    for line in lines[(header + 1)...] {
        if line.contains("Thread_") && !line.contains("(in ") { break }
        if line.contains("Total number in stack") || line.contains("Binary Images:") { break }
        block.append(line)
    }

    var total = 0
    var frames: [String: Int] = [:]
    var deepest = ""
    for line in block {
        guard let parsed = sampleLine(line) else { continue }
        frames[parsed.symbol, default: 0] += parsed.count
        total = max(total, parsed.count)
        // The last usable line of the block is the innermost frame of the last
        // subtree. Only meaningful when the thread is actually doing work; when
        // it is idling in mach_msg the stack is just the run-loop plumbing.
        deepest = parsed.symbol
    }
    // One chain lists each of its frames once with the same count, and the run
    // loop plumbing appears several times per chain, so the metrics take the
    // MAX count of each group instead of summing overlapping symbols
    // (summing would report 4x the real number of samples).
    let idleSymbols = ["__CFRunLoopServiceMachPort", "mach_msg2_trap", "mach_msg", "mach_msg_overwrite"]
    let idle = idleSymbols.compactMap { frames[$0] }.max() ?? 0
    // Frames that mean the main thread is doing layout work instead of idling.
    let layoutMarkers = ["-[NSView layout]", "NSISEngine", "systemLayoutSizeFittingSize",
                         "NSPerformVisuallyAtomicChange", "__CFRunLoopDoObservers",
                         "layoutSubtreeIfNeeded"]
    let layout = layoutMarkers.compactMap { marker in
        frames.filter { $0.key.contains(marker) }.values.max()
    }.max() ?? 0

    // The single heaviest leaf frame tells you what the main thread was doing.
    let leaves = frames.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key) x\($0.value)" }

    let verdict: String
    if total == 0 {
        verdict = "unparsed"
    } else if layout >= total / 3 + 1 {
        verdict = "thrashing-in-layout"
    } else if idle >= total / 2 + 1 {
        verdict = "responsive-idle"
    } else if frames.keys.contains(where: { $0.contains("-[NSApplication run]") }) {
        verdict = "responsive-busy"
    } else {
        verdict = "not-in-event-loop"
    }
    let stuckIn = verdict == "thrashing-in-layout" ? "layout" : (idle >= total / 2 + 1 ? "mach_msg" : deepest)
    return ["verdict": verdict, "samples": total, "idleFrames": idle, "layoutFrames": layout,
            "stuckIn": stuckIn, "deepestFrame": deepest, "topFrames": leaves, "samplePath": path]
}

// MARK: - log signatures

func logScan(pid: Int) -> [String: Any] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    process.arguments = ["show", "--last", "10m", "--style", "compact", "--predicate", "processID == \(pid)"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return ["error": "log-unavailable"] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let text = String(data: data, encoding: .utf8) ?? ""
    func count(_ needle: String) -> Int { text.components(separatedBy: needle).count - 1 }

    let exceptions = count("NSUnknownKeyException")
    let uncaught = count("An uncaught exception was raised")
    let layoutRecursion = count("layoutSubtreeIfNeeded on a view which is already being laid out")
    var frame = ""
    for line in text.components(separatedBy: "\n") where line.contains("ConfigWindowController") && line.contains("0x") {
        frame = line.trimmingCharacters(in: .whitespaces)
        break
    }
    return ["unknownKeyException": exceptions, "uncaughtException": uncaught,
            "layoutRecursionWarning": layoutRecursion, "firstAppFrame": frame, "lines": text.components(separatedBy: "\n").count]
}

// MARK: - control windows (screenshot-limitation experiments)

func runControl(mode: String) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    func makeWindow(_ rect: NSRect, _ titleText: String, _ body: String) -> NSWindow {
        let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = titleText
        let label = NSTextField(labelWithString: body)
        label.font = .systemFont(ofSize: 40)
        label.frame = NSRect(x: 24, y: rect.height / 2 - 40, width: rect.width - 48, height: 60)
        window.contentView?.addSubview(label)
        return window
    }

    print("CONTROL-WINDOW-ID-PENDING")
    switch mode {
    case "element":
        let window = makeWindow(NSRect(x: 200, y: 400, width: 500, height: 300),
                                "CONTROL-LSUIELEMENT", "HELLO-FROM-PROBE")
        window.makeKeyAndOrderFront(nil)
        print("WINID=\(window.windowNumber)")
    case "offorder":
        // Built exactly like the config window, but never ordered front: if
        // screencapture -l still produces content, then "blank capture" cannot
        // be explained by "window is not on screen".
        let window = makeWindow(NSRect(x: 200, y: 400, width: 500, height: 300),
                                "CONTROL-NEVER-ORDERED", "GHOST-WINDOW-CONTENT")
        print("WINID=\(window.windowNumber)")
    case "occluded":
        let below = makeWindow(NSRect(x: 300, y: 300, width: 500, height: 300),
                               "CONTROL-BELOW", "COVERED-CONTENT")
        below.makeKeyAndOrderFront(nil)
        let above = NSWindow(contentRect: NSRect(x: 250, y: 250, width: 700, height: 460),
                             styleMask: [.titled], backing: .buffered, defer: false)
        above.title = "CONTROL-ABOVE"
        above.backgroundColor = .black
        above.makeKeyAndOrderFront(nil)
        print("WINID=\(below.windowNumber)")
    default:
        FileHandle.standardError.write("unknown control mode \(mode)\n".data(using: .utf8)!)
        exit(64)
    }
    fflush(stdout)
    DispatchQueue.main.asyncAfter(deadline: .now() + 25) { exit(0) }
    app.run()
}

// MARK: - dispatch

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write("usage: UIProbe <command>\n".data(using: .utf8)!)
    exit(2)
}

switch arguments[1] {
case "trusted":
    emit(["axTrusted": AXIsProcessTrusted()])

case "windows":
    let pid = Int(arguments[2])!
    emit(["windows": windowList(pid: pid, all: arguments.contains("--all"))])

case "image":
    emit(imageStats(path: arguments[2]))

case "statusitem":
    let pid = Int32(arguments[2])!
    let app = application(pid)
    if let item = statusItemElement(app), let box = frame(item) {
        emit(["found": true, "role": role(item), "x": box.minX, "y": box.minY, "w": box.width, "h": box.height,
              "centerX": box.midX, "centerY": box.midY, "title": title(item)])
    } else {
        emit(["found": false])
    }

case "pressitem":
    // AXPress on the status item itself. Unlike `press <pid> ""`, which walks the
    // tree by title and therefore matches the AXMenuBar, this targets the same
    // AXMenuBarItem that `statusitem` reports — the exact fallback the acceptance
    // script uses when a synthetic click is swallowed by an overlay window.
    let pid = Int32(arguments[2])!
    let app = application(pid)
    if let item = statusItemElement(app) {
        let error = AXUIElementPerformAction(item, kAXPressAction as CFString)
        emit(["found": true, "role": role(item), "pressResult": error.rawValue, "pressOK": error == .success])
    } else {
        emit(["found": false])
    }

case "obstructors":
    // `obstructors <pid> [--at <x> <y>] [--min-layer <n>]`
    // Read-only: reports what sits above the status item, never clicks anything.
    let pid = Int(arguments[2])!
    var point: CGPoint? = nil
    var minimumLayer: Int? = nil
    var index = 3
    while index + 1 < arguments.count {
        switch arguments[index] {
        case "--at":
            guard index + 2 < arguments.count, let x = Double(arguments[index + 1]),
                  let y = Double(arguments[index + 2]) else {
                FileHandle.standardError.write("--at needs two numbers\n".data(using: .utf8)!)
                exit(64)
            }
            point = CGPoint(x: x, y: y)
            index += 3
        case "--min-layer":
            guard index + 1 < arguments.count, let layer = Int(arguments[index + 1]) else {
                FileHandle.standardError.write("--min-layer needs an integer\n".data(using: .utf8)!)
                exit(64)
            }
            minimumLayer = layer
            index += 2
        default:
            index += 1
        }
    }
    emit(obstructors(pid: pid, minimumLayer: minimumLayer, point: point))

case "find":
    let pid = Int32(arguments[2])!, wanted = arguments[3]
    let app = application(pid)
    if let element = findElement(app, title: wanted), let box = frame(element) {
        emit(["found": true, "role": role(element), "x": box.minX, "y": box.minY, "w": box.width, "h": box.height,
              "centerX": box.midX, "centerY": box.midY])
    } else {
        emit(["found": false])
    }

case "press":
    let pid = Int32(arguments[2])!, wanted = arguments[3]
    let app = application(pid)
    if let element = findElement(app, title: wanted) {
        let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
        emit(["found": true, "role": role(element), "pressResult": error.rawValue, "pressOK": error == .success])
    } else {
        emit(["found": false])
    }

case "key":
    // Synthetic key press by virtual key code (53 = Escape), used to dismiss a
    // popover when it has lost focus and AX can no longer see its buttons.
    let code = CGKeyCode(UInt16(arguments[2])!)
    let source = CGEventSource(stateID: .hidSystemState)
    CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
    usleep(60_000)
    CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    emit(["key": Int(code)])

case "click":
    click(CGPoint(x: Double(arguments[2])!, y: Double(arguments[3])!))
    emit(["clicked": true, "x": Double(arguments[2])!, "y": Double(arguments[3])!])


case "axhealth":
    let pid = Int32(arguments[2])!, substring = arguments[3]
    let app = application(pid)
    guard let window = findWindow(app, containing: substring) else { emit(["found": false]); exit(0) }
    var total = 0
    var collapsed = 0
    func walk(_ element: AXUIElement, _ depth: Int) {
        guard depth <= 24 else { return }
        total += 1
        if let box = frame(element), box.width <= 3 || box.height <= 3 { collapsed += 1 }
        for child in children(element) { walk(child, depth + 1) }
    }
    walk(window, 0)
    emit(["found": true, "elements": total, "collapsedControls": collapsed])

case "axlatency":
    let pid = Int32(arguments[2])!, count = arguments.count > 3 ? Int(arguments[3])! : 5
    let app = application(pid)
    var times: [Double] = []
    var failures = 0
    for _ in 0..<count {
        let start = CFAbsoluteTimeGetCurrent()
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) != .success { failures += 1 }
        times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }
    let sorted = times.sorted()
    emit(["calls": count, "failures": failures, "medianMs": rounded(sorted[sorted.count / 2], 10),
          "maxMs": rounded(sorted.last ?? 0, 10)])

case "classify":
    emit(classifySample(path: arguments[2]))

case "sample":
    let pid = arguments[2], seconds = arguments[3]
    let outputPath = NSTemporaryDirectory() + "ui-acceptance-sample-\(pid).txt"
    try? FileManager.default.removeItem(atPath: outputPath)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
    process.arguments = [pid, seconds, "-file", outputPath]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { emit(["error": "sample-unavailable"]); exit(0) }
    process.waitUntilExit()
    emit(classifySample(path: outputPath))

case "logscan":
    emit(logScan(pid: Int(arguments[2])!))

case "control":
    runControl(mode: arguments[2])

default:
    FileHandle.standardError.write("unknown command \(arguments[1])\n".data(using: .utf8)!)
    exit(64)
}
