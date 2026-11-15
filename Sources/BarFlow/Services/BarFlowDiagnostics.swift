import Foundation
import Darwin
import os

/// Centralized lightweight structured logging (`os.Logger`) for BarFlow diagnostics.
/// Never invoke from hot SwiftUI/AppKit rendering paths; never log personal user data beyond bundle/item identifiers.
enum BarFlowLog {
    static let subsystem = "com.hunglx.BarFlow"
    static let scan = Logger(subsystem: subsystem, category: "scan")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let agent = Logger(subsystem: subsystem, category: "agent")

    /// Sanitizes an item identifier for public unified logging so non-bundle process names or localized titles are never leaked.
    static func sanitizeID(_ rawID: String) -> String {
        if rawID.hasPrefix("exec:") {
            return "exec:<binary>"
        }
        if let hashIndex = rawID.firstIndex(of: "#") {
            let prefix = String(rawID[..<hashIndex])
            let suffix = String(rawID[rawID.index(after: hashIndex)...])
            let cleanPrefix = prefix.hasPrefix("exec:") ? "exec:<binary>" : prefix
            let safeSuffix = suffix.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_" || $0 == ":"
            }
            return safeSuffix ? "\(cleanPrefix)#\(suffix)" : "\(cleanPrefix)#<id>"
        }
        return rawID
    }

    static func formatIDList(_ ids: some Sequence<String>) -> String {
        ids.map(sanitizeID).sorted().joined(separator: ",")
    }

    static func formatPIDList(_ pids: some Sequence<pid_t>) -> String {
        pids.sorted().map(String.init).joined(separator: ",")
    }
}

/// Trigger source for a menu bar scan.
enum ScanReason: Equatable, Hashable, Sendable, CustomStringConvertible {
    case startup
    case appLaunched(pid_t)
    case appTerminated
    case backgroundTick
    case wake
    case manual
    case postAgentReload
    case postInteraction

    var description: String {
        switch self {
        case .startup:
            return "startup"
        case .appLaunched(let pid):
            return "appLaunched(\(pid))"
        case .appTerminated:
            return "appTerminated"
        case .backgroundTick:
            return "backgroundTick"
        case .wake:
            return "wake"
        case .manual:
            return "manual"
        case .postAgentReload:
            return "postAgentReload"
        case .postInteraction:
            return "postInteraction"
        }
    }
}
