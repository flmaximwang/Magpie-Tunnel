import Foundation
import MagpieTunnelCore

/// The connection state of one tunnel, as the panel is allowed to describe it.
///
/// The daemon only ever writes three things: `connecting`, `up`, `down` — and
/// nothing at all. "Unknown" is reserved for the two cases where there is no
/// trustworthy record: no status file yet (right after launch), or a state
/// string written by some other process. A broken configuration is reported by
/// `PanelState` itself, never as a disconnection.
enum TunnelConnectionState: Equatable {
    /// The daemon probed the local port successfully.
    case connected
    /// The daemon has spawned ssh and is still probing. Only this interval may
    /// be shown as "连接中".
    case connecting
    /// The daemon reports a failure; `reason` is its short detail string.
    case disconnected(reason: String?)
    /// No usable status record.
    case unknown

    var label: String {
        switch self {
        case .connected: return "已连接"
        case .connecting: return "连接中"
        case .disconnected: return "未连接"
        case .unknown: return "状态未知"
        }
    }

    /// Short cause shown next to the state, never a paragraph.
    var detail: String? {
        guard case .disconnected(let reason) = self, let reason, !reason.isEmpty else { return nil }
        return reason
    }

    /// Map one status record onto the panel vocabulary. Anything the daemon did
    /// not write is untrusted and reads as unknown.
    static func from(_ record: StatusRecord?) -> TunnelConnectionState {
        guard let record else { return .unknown }
        switch record.state {
        case "up": return .connected
        case "connecting": return .connecting
        case "down": return .disconnected(reason: record.detail.isEmpty ? nil : record.detail)
        default: return .unknown
        }
    }
}

/// One tunnel row: name, local port and state, in config-file order.
struct TunnelRow: Equatable {
    let name: String
    let localPort: Int
    let state: TunnelConnectionState
    let url: String

    /// Both row actions (open / copy) exist only for a connected tunnel.
    var isConnectable: Bool { state == .connected }

    var portText: String { "127.0.0.1:\(localPort)" }

    /// Flat single-line form: accessibility, and the headless smoke test.
    var title: String {
        if let detail = state.detail {
            return "\(name)  \(portText)  \(state.label)：\(detail)"
        }
        return "\(name)  \(portText)  \(state.label)"
    }
}

/// What the panel shows in place of the tunnel list, and the button that sits
/// under it. Keeps the "no tunnels", "broken config" and "unreadable config"
/// cases distinct instead of collapsing them into one empty message.
enum PanelEmptyState: Equatable {
    case none
    /// Nothing configured yet: "尚未配置隧道" + "添加隧道".
    case noTunnels
    /// The file has rows, but none of them are usable.
    case brokenConfiguration(count: Int)
    /// The file exists but could not be read at all.
    case unreadableConfiguration

    var message: String? {
        switch self {
        case .none: return nil
        case .noTunnels: return "尚未配置隧道"
        case .brokenConfiguration(let count): return "配置有 \(count) 行错误，没有可用的隧道"
        case .unreadableConfiguration: return "配置无法读取"
        }
    }

    var actionTitle: String? {
        switch self {
        case .none: return nil
        case .noTunnels: return "添加隧道"
        case .brokenConfiguration, .unreadableConfiguration: return "修正配置"
        }
    }
}

/// The menu-bar glyph state. There are exactly two, matching the icon design:
/// a continuous tail when everything is up, a visible gap in the tail when
/// anything is wrong (a single outage, a missing status record, or no targets).
enum MenuIconState: String, CaseIterable, Equatable {
    case healthy
    case degraded
}

/// Everything the panel needs to draw itself, with no AppKit in sight.
struct PanelState: Equatable {
    /// Strict spelling of the app name; used in the header and every window.
    static let appDisplayName = "Magpie-WebUI-Tunnel"

    let rows: [TunnelRow]
    /// A whole-file problem (unreadable file), `nil` when the file was read.
    let configError: String?
    /// Per-line validation failures, already carrying their line numbers.
    let configDiagnostics: [String]

    var connectedCount: Int { rows.filter(\.isConnectable).count }
    var allUp: Bool { !rows.isEmpty && connectedCount == rows.count }

    var emptyState: PanelEmptyState {
        if configError != nil { return .unreadableConfiguration }
        if rows.isEmpty {
            return configDiagnostics.isEmpty ? .noTunnels : .brokenConfiguration(count: configDiagnostics.count)
        }
        return .none
    }

    /// Whether restarting tunnels is meaningful (at least one valid tunnel exists).
    var canRestartTunnels: Bool { emptyState == .none }

    /// One short sentence under the header: what is running, or what is wrong.
    var subtitle: String {
        if let configError { return "配置无法读取：\(configError)" }
        if rows.isEmpty {
            return emptyState.message ?? "尚未配置隧道"
        }
        if !configDiagnostics.isEmpty {
            return "\(rows.count) 条隧道，另有 \(configDiagnostics.count) 行配置错误"
        }
        if connectedCount == rows.count {
            return rows.count == 1 ? "1 条隧道，已连接" : "\(rows.count) 条隧道，全部已连接"
        }
        let unknownCount = rows.filter { $0.state == .unknown }.count
        if unknownCount == rows.count {
            return "\(rows.count) 条隧道，状态未知"
        }
        return "\(rows.count) 条隧道，\(connectedCount) 条已连接"
    }

    var iconState: MenuIconState {
        (allUp && configError == nil && configDiagnostics.isEmpty) ? .healthy : .degraded
    }

    /// Spoken by VoiceOver for the status item; the glyph carries no text.
    var iconAccessibilityLabel: String {
        if configError != nil { return "\(PanelState.appDisplayName)：配置无法读取" }
        if !configDiagnostics.isEmpty { return "\(PanelState.appDisplayName)：配置有错误" }
        if rows.isEmpty { return "\(PanelState.appDisplayName)：尚未配置隧道" }
        if allUp { return "\(PanelState.appDisplayName)：全部隧道已连接" }
        if connectedCount == 0 && rows.allSatisfy({ $0.state == .unknown }) {
            return "\(PanelState.appDisplayName)：隧道状态未知"
        }
        return "\(PanelState.appDisplayName)：\(connectedCount) 条已连接，\(rows.count - connectedCount) 条异常"
    }

    static let empty = PanelState(rows: [], configError: nil, configDiagnostics: [])
}

enum PanelStateBuilder {
    /// Build the panel from config targets (file order) and the daemon's status
    /// records. A missing status file reads as "状态未知", never as a
    /// disconnection: the daemon may simply not have written anything yet.
    static func build(targets: [TargetConfig],
                      statuses: [String: StatusRecord],
                      configError: String? = nil,
                      diagnostics: [String] = []) -> PanelState {
        let rows = targets.map { target in
            TunnelRow(name: target.name,
                      localPort: target.localPort,
                      state: .from(statuses[target.name]),
                      url: TunnelURLBuilder.url(for: target))
        }
        return PanelState(rows: rows, configError: configError, configDiagnostics: diagnostics)
    }
}
