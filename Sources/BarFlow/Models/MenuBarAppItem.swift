import Foundation
import AppKit
import ApplicationServices

/// Represents a running application (or individual status item / system extra) on the macOS Menu Bar.
struct MenuBarAppItem: Identifiable, Equatable {
    /// Stable unique identifier across scans and app launches.
    let id: String
    /// Process identifier of the owning application or container agent.
    let pid: pid_t
    /// Human-readable display name of the application or status item.
    let appName: String
    /// Bundle identifier if available.
    let bundleIdentifier: String?
    /// Accessibility identifier of this specific status item (e.g. `com.apple.menuextra.wifi` or multi-item ID).
    let axIdentifier: String?
    /// Index of this status item within its owning process's `AXExtrasMenuBar` children.
    let axChildIndex: Int
    /// Pre-scaled crisp application icon (`32x32` pt @2x) for zero-lag SwiftUI rendering.
    let appIcon: NSImage
    /// Live text/status title exposed by the status item (e.g. "Mon, 26 Oct" for Itsycal).
    var statusTitle: String
    /// Accessibility description if provided by the status item.
    var statusDescription: String
    /// Current screen-space frame (CoreGraphics top-left origin), if available.
    var slotFrame: CGRect?
    /// Whether this item currently has an active visible slot on the menu bar (not pushed into overflow).
    var isCurrentlyOnBar: Bool
    /// Underlying Accessibility element for direct `AXPress` invocation.
    let axElement: AXUIElement?
    /// Whether this item belongs to macOS system services (Wi-Fi, Battery, Spotlight, Input Source, etc.).
    let isSystemItem: Bool
    /// Whether macOS allows moving/hiding this item via Command-drag.
    let isMovable: Bool

    /// Effective X coordinate for sorting right-to-left on the menu bar.
    var sortX: CGFloat {
        slotFrame?.minX ?? -99999
    }

    static func == (lhs: MenuBarAppItem, rhs: MenuBarAppItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.pid == rhs.pid &&
        lhs.appName == rhs.appName &&
        lhs.statusTitle == rhs.statusTitle &&
        lhs.isCurrentlyOnBar == rhs.isCurrentlyOnBar
    }
}

/// Auto-hide timeout presets for the floating secondary bar (`Ctrl + B`).
enum AutoHideDuration: Int, CaseIterable, Identifiable {
    case threeSeconds = 3
    case fiveSeconds = 5
    case eightSeconds = 8
    case twelveSeconds = 12
    case twentySeconds = 20
    case never = 0

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .threeSeconds: return "3 giây"
        case .fiveSeconds: return "5 giây"
        case .eightSeconds: return "8 giây"
        case .twelveSeconds: return "12 giây"
        case .twentySeconds: return "20 giây"
        case .never: return "Không tự ẩn (chỉ ẩn khi bấm lại Ctrl+B hoặc click ra ngoài)"
        }
    }

    var shortLabel: String {
        switch self {
        case .never: return "Thủ công"
        default: return "\(rawValue)s"
        }
    }
}
