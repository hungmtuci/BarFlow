import Foundation
import AppKit
import ApplicationServices
import Carbon

/// Represents a user-customizable global keyboard shortcut for toggling the Secondary Bar.
struct HotKeyBinding: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let defaultCtrlB = HotKeyBinding(
        keyCode: UInt32(kVK_ANSI_B),
        carbonModifiers: UInt32(controlKey)
    )

    var isDefault: Bool {
        self == Self.defaultCtrlB
    }

    var appKitModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if (carbonModifiers & UInt32(controlKey)) != 0 { flags.insert(.control) }
        if (carbonModifiers & UInt32(optionKey)) != 0  { flags.insert(.option) }
        if (carbonModifiers & UInt32(shiftKey)) != 0   { flags.insert(.shift) }
        if (carbonModifiers & UInt32(cmdKey)) != 0     { flags.insert(.command) }
        return flags
    }

    /// Compact Apple symbol representation, e.g. `"⌃B"`, `"⌥Space"`, `"⌘⇧B"`.
    var compactDisplay: String {
        var prefix = ""
        if (carbonModifiers & UInt32(controlKey)) != 0 { prefix += "⌃" }
        if (carbonModifiers & UInt32(optionKey)) != 0  { prefix += "⌥" }
        if (carbonModifiers & UInt32(shiftKey)) != 0   { prefix += "⇧" }
        if (carbonModifiers & UInt32(cmdKey)) != 0     { prefix += "⌘" }
        return prefix + Self.keyLabel(for: keyCode)
    }

    /// Readable representation, e.g. `"Ctrl + B"`, `"Opt + Space"`, `"Cmd + Shift + B"`.
    var readableDisplay: String {
        var parts: [String] = []
        if (carbonModifiers & UInt32(controlKey)) != 0 { parts.append("Ctrl") }
        if (carbonModifiers & UInt32(optionKey)) != 0  { parts.append("Opt") }
        if (carbonModifiers & UInt32(shiftKey)) != 0   { parts.append("Shift") }
        if (carbonModifiers & UInt32(cmdKey)) != 0     { parts.append("Cmd") }
        parts.append(Self.keyLabel(for: keyCode))
        return parts.joined(separator: " + ")
    }

    /// Single-character equivalent for `NSMenuItem.keyEquivalent` when supported.
    var menuKeyEquivalent: String {
        let label = Self.keyLabel(for: keyCode)
        if label == "Space" { return " " }
        if label.count == 1 { return label.lowercased() }
        return ""
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.option)  { mask |= UInt32(optionKey) }
        if flags.contains(.shift)   { mask |= UInt32(shiftKey) }
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        return mask
    }

    static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        switch Int(keyCode) {
        case kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
             kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12:
            return true
        default:
            return false
        }
    }

    static func keyLabel(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Tab: return "Tab"
        case kVK_Return: return "↩"
        case kVK_ANSI_Grave: return "`"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return "Key\(keyCode)"
        }
    }
}

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
