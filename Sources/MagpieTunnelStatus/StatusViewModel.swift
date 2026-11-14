import Foundation
import MagpieTunnelCore

/// Owns reading config + status files and producing `MenuState`. Kept free
/// of AppKit so the refresh pipeline is fully unit-testable; the app
/// delegate wires it into NSMenu on a ~10s timer (legacy cadence).
final class StatusViewModel {
    let paths: TunnelPaths
    private(set) var state = MenuState(summaryTitle: "magpie 隧道 0/0", targetRows: [], allUp: false)
    private(set) var lastDiagnostics: [String] = []

    init(paths: TunnelPaths) {
        self.paths = paths
    }

    /// Read config + statuses and rebuild the menu state. Config missing →
    /// built-in defaults (same fallback as the daemon).
    @discardableResult
    func refresh() -> MenuState {
        let targets: [TargetConfig]
        if FileManager.default.fileExists(atPath: paths.configPath),
           let parsed = try? TargetsParser.parseFile(at: paths.configPath) {
            targets = parsed.targets
            lastDiagnostics = parsed.diagnostics
        } else {
            targets = TargetConfig.builtInDefaults
            lastDiagnostics = []
        }
        let statuses = (try? StatusStore(directory: paths.statusDirectory))?.readAll() ?? [:]
        state = MenuStateBuilder.build(targets: targets, statuses: statuses)
        return state
    }
}
