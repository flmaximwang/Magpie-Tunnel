import Foundation
import MagpieTunnelCore

/// Owns reading config + status files and producing `PanelState`. Kept free
/// of AppKit so the refresh pipeline is fully unit-testable; the app delegate
/// wires it into the panel on a short timer.
///
/// The config file is the single source of truth for what is configured, so a
/// missing file means "no tunnels", exactly like an empty file. It must never
/// silently turn into the built-in sample targets: the panel would then list
/// tunnels the user never asked for, and deleting the last tunnel would
/// resurrect them.
final class StatusViewModel {
    let paths: TunnelPaths
    private(set) var state = PanelState.empty
    private(set) var lastDiagnostics: [String] = []
    /// Why the config file could not be read, when it exists but is unusable.
    private(set) var configError: String?

    init(paths: TunnelPaths) {
        self.paths = paths
    }

    /// Read config + statuses and rebuild the panel state.
    @discardableResult
    func refresh() -> PanelState {
        let targets: [TargetConfig]
        var diagnostics: [String] = []
        configError = nil

        if FileManager.default.fileExists(atPath: paths.configPath) {
            if let text = try? String(contentsOfFile: paths.configPath, encoding: .utf8) {
                let document = ConfigDocument.parse(text)
                targets = document.targets
                diagnostics = document.diagnostics
            } else {
                targets = []
                configError = "文件无法读取"
            }
        } else {
            targets = []
        }

        lastDiagnostics = diagnostics
        let statuses = (try? StatusStore(directory: paths.statusDirectory))?.readAll() ?? [:]
        state = PanelStateBuilder.build(targets: targets, statuses: statuses,
                                        configError: configError, diagnostics: diagnostics)
        return state
    }

    /// Status records only, for callers that poll faster than the config scan.
    func readStatuses() -> [String: StatusRecord] {
        (try? StatusStore(directory: paths.statusDirectory))?.readAll() ?? [:]
    }
}
