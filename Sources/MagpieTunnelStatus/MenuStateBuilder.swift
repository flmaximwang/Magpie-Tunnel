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

/// The menu-bar glyph state. There are exactly two, matching the icon design:
/// a continuous tail when everything is up, a visible gap in the tail when
/// anything is wrong (a single outage, a missing status record, or no targets).
enum MenuIconState: String, CaseIterable, Equatable {
    case healthy
    case degraded
}

struct MenuState: Equatable {
    let summaryTitle: String
    let targetRows: [TargetRow]
    let allUp: Bool

    var iconState: MenuIconState { allUp ? .healthy : .degraded }

    /// Spoken by VoiceOver for the status item; the emoji carried no text.
    var iconAccessibilityLabel: String {
        allUp ? "magpie 隧道：全部就绪" : "magpie 隧道：有隧道异常"
    }
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
