import Foundation
import MagpieTunnelCore

/// Pure, testable model of the menu bar content. Mirrors the legacy
/// menu structure exactly (summary row, per-target rows, submenus).
struct TargetRow: Equatable {
    let name: String
    let isUp: Bool
    let url: String
    let hostPort: String

    /// "✓ alpha localhost:3430" / "✗ alpha localhost:3430"
    var title: String { (isUp ? "✓ " : "✗ ") + name + " " + hostPort }
}

struct MenuState: Equatable {
    let summaryTitle: String
    let targetRows: [TargetRow]
    let allUp: Bool

    /// Legacy icons: 🔗 when every tunnel is up, degraded 🔗⃠ otherwise
    /// (including an empty config — nothing running is not "all up").
    var iconEmoji: String { allUp ? "🔗" : "🔗⃠" }
}

enum MenuStateBuilder {
    /// Build the full menu model from config targets (file order) and the
    /// daemon's status records. A missing status file counts as down.
    static func build(targets: [TargetConfig], statuses: [String: StatusRecord]) -> MenuState {
        let rows = targets.map { target -> TargetRow in
            let up = statuses[target.name]?.isUp == true
            return TargetRow(name: target.name,
                             isUp: up,
                             url: TunnelURLBuilder.url(for: target),
                             hostPort: TunnelURLBuilder.hostPort(for: target))
        }
        let upCount = rows.filter(\.isUp).count
        let allUp = !rows.isEmpty && upCount == rows.count
        return MenuState(summaryTitle: "magpie 隧道 \(upCount)/\(rows.count)",
                         targetRows: rows,
                         allUp: allUp)
    }
}
