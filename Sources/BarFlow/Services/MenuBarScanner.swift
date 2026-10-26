import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

/// Represents a physical slot currently laid out on a display's menu bar by `MenuBarAgent` (macOS 26/27+) or WindowServer.
struct HostedBarSlot: Equatable {
    let displayID: CGDirectDisplayID
    let hostWindowFrame: CGRect
    let frame: CGRect
    let sourcePID: pid_t
    let identifier: String?

    var isOverflowChevron: Bool {
        sourcePID == 0
    }

    var center: CGPoint {
        CGPoint(x: frame.midX, y: frame.midY)
    }
}

/// Complete snapshot of the menu bar layout across displays at a point in time.
struct MenuBarScanSnapshot {
    let apps: [MenuBarAppItem]
    /// Keyed by CGDirectDisplayID -> all laid-out slots sorted left-to-right (ascending minX).
    let slotsByDisplay: [CGDirectDisplayID: [HostedBarSlot]]
    /// Overflow `«` chevron frame per display, if present.
    let overflowChevronByDisplay: [CGDirectDisplayID: CGRect]
}

@MainActor
final class MenuBarScanner {
    static let shared = MenuBarScanner()

    private let systemBundleIDs: Set<String> = [
        "com.apple.controlcenter",
        "com.apple.MenuBarAgent",
        "com.apple.systemuiserver",
        "com.apple.Siri",
        "com.apple.Spotlight",
        "com.apple.TextInputMenuAgent"
    ]

    private let immovableBundleIDs: Set<String> = [
        "com.apple.controlcenter",
        "com.apple.MenuBarAgent"
    ]

    private init() {}

    // MARK: - Accessibility Permission Helpers

    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    func promptForAccessibilityPermission() {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Full Menu Bar Scan

    /// Scans both `MenuBarAgent` slot trees (for exact on-bar coordinates) and `AXExtrasMenuBar` across all running apps
    /// (so hidden/overflowed menu bar apps are always discovered even when pushed off the visible bar).
    func scanMenuBar(ownMainToggleFrameCG: CGRect? = nil) -> MenuBarScanSnapshot {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let (slotsByDisplay, chevronsByDisplay) = readHostedSlotsByDisplay(
            ownPID: ownPID,
            ownMainToggleFrameCG: ownMainToggleFrameCG
        )

        // Choose the widest display's slot map as reference for sorting & on-bar status
        let widestDisplayID = Self.widestDisplayID()
        let referenceSlots: [HostedBarSlot] = {
            if let widest = widestDisplayID, let slots = slotsByDisplay[widest], !slots.isEmpty {
                return slots
            }
            return slotsByDisplay.values.max(by: { $0.count < $1.count }) ?? []
        }()

        var slotsByPID: [pid_t: [HostedBarSlot]] = [:]
        for slot in referenceSlots where slot.sourcePID > 0 && slot.sourcePID != ownPID {
            slotsByPID[slot.sourcePID, default: []].append(slot)
        }

        var discoveredItems: [MenuBarAppItem] = []
        var seenIDs = Set<String>()

        let runningApps = NSWorkspace.shared.runningApplications
        for app in runningApps {
            let pid = app.processIdentifier
            guard pid > 0, pid != ownPID else { continue }

            let bundleID = app.bundleIdentifier
            // Skip MenuBarAgent / ControlCenter raw container entries in main selectable app list;
            // third-party and user-facing extras (including Spotlight/Siri, Input Menu, etc.) have their own processes.
            if bundleID == "com.apple.MenuBarAgent" || bundleID == "com.apple.controlcenter" || bundleID == "com.apple.systemuiserver" {
                continue
            }

            let axChildren = readExtrasMenuBarChildren(for: pid)
            let hostedSlots = slotsByPID[pid] ?? []

            // Only include apps that actually own at least one menu bar status item!
            guard !axChildren.isEmpty || !hostedSlots.isEmpty else { continue }

            let stableID = bundleID ?? "pid:\(pid):\(app.localizedName ?? "App")"
            guard !seenIDs.contains(stableID) else { continue }
            seenIDs.insert(stableID)

            let primaryAX = axChildren.first
            let (axTitle, axDesc, axFrame) = primaryAX.map { readAXMetadata($0) } ?? ("", "", nil)

            // Prefer exact slot frame from MenuBarAgent on widest display; fall back to AXExtrasMenuBar frame if visible
            let liveSlotFrame: CGRect? = hostedSlots.first?.frame ?? axFrame
            let isOnBar: Bool = {
                if !hostedSlots.isEmpty {
                    return true
                }
                if let f = axFrame, let screen = Self.screenContaining(cgPoint: CGPoint(x: f.midX, y: f.midY)) {
                    let cgScreenTop = Self.cgScreenRect(for: screen).minY
                    return abs(f.minY - cgScreenTop) <= 36
                }
                return false
            }()

            let appName = friendlyAppName(for: app, fallbackDesc: axDesc, fallbackTitle: axTitle)
            let icon = bestIcon(for: app)
            let isSystem = bundleID.map { systemBundleIDs.contains($0) || $0.hasPrefix("com.apple.") } ?? false
            let isMovable = !(bundleID.map { immovableBundleIDs.contains($0) } ?? false)

            let item = MenuBarAppItem(
                id: stableID,
                pid: pid,
                appName: appName,
                bundleIdentifier: bundleID,
                appIcon: icon,
                menuBarSnapshot: nil,
                statusTitle: axTitle,
                statusDescription: axDesc,
                slotFrame: liveSlotFrame,
                isCurrentlyOnBar: isOnBar,
                axElement: primaryAX,
                isSystemItem: isSystem,
                isMovable: isMovable
            )
            discoveredItems.append(item)
        }

        // Sort right-to-left (largest X first = rightmost on menu bar) for items on bar, then alphabetically for hidden items
        discoveredItems.sort { a, b in
            if a.isCurrentlyOnBar != b.isCurrentlyOnBar {
                return a.isCurrentlyOnBar && !b.isCurrentlyOnBar
            }
            if abs(a.sortX - b.sortX) > 1 {
                return a.sortX > b.sortX
            }
            return a.appName.localizedCaseInsensitiveCompare(b.appName) == .orderedAscending
        }

        return MenuBarScanSnapshot(
            apps: discoveredItems,
            slotsByDisplay: slotsByDisplay,
            overflowChevronByDisplay: chevronsByDisplay
        )
    }

    /// Quickly finds the live slot for a specific PID (or own accessibility identifier) on a target display.
    func findSlot(
        forPID targetPID: pid_t,
        identifier: String? = nil,
        on displayID: CGDirectDisplayID,
        ownMainToggleFrameCG: CGRect? = nil
    ) -> HostedBarSlot? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let (slotsByDisplay, _) = readHostedSlotsByDisplay(
            ownPID: ownPID,
            ownMainToggleFrameCG: ownMainToggleFrameCG
        )
        guard let slots = slotsByDisplay[displayID] else { return nil }
        if let identifier {
            return slots.first { $0.sourcePID == targetPID && $0.identifier == identifier }
        }
        return slots.first { $0.sourcePID == targetPID }
    }

    // MARK: - MenuBarAgent Slot Tree Reader (macOS 26/27+)

    func readHostedSlotsByDisplay(
        ownPID: pid_t,
        ownMainToggleFrameCG: CGRect?
    ) -> ([CGDirectDisplayID: [HostedBarSlot]], [CGDirectDisplayID: CGRect]) {
        guard AXIsProcessTrusted() else { return ([:], [:]) }

        guard let agentApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else {
            return readLegacyWindowServerSlots(ownPID: ownPID)
        }

        let axAgent = AXUIElementCreateApplication(agentApp.processIdentifier)
        AXUIElementSetMessagingTimeout(axAgent, 0.8)

        var winsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axAgent, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let axWindows = winsRef as? [AXUIElement],
              !axWindows.isEmpty else {
            return readLegacyWindowServerSlots(ownPID: ownPID)
        }

        let activeDisplays = Self.activeDisplayIDs()
        var candidateWindowsByDisplay: [CGDirectDisplayID: [[HostedBarSlot]]] = [:]

        for window in axWindows {
            guard let hostFrame = readAXFrame(window), hostFrame.width > 0 else { continue }
            guard let displayID = activeDisplays.first(where: { CGDisplayBounds($0).intersects(hostFrame) }) else {
                continue
            }

            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let slotElements = childrenRef as? [AXUIElement] else {
                continue
            }

            var parsedSlots: [HostedBarSlot] = []
            for slotEl in slotElements {
                guard let frame = readAXFrame(slotEl), frame.width > 0 else { continue }

                var slotChildrenRef: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(slotEl, kAXChildrenAttribute as CFString, &slotChildrenRef)
                let content = (slotChildrenRef as? [AXUIElement])?.first

                var pid: pid_t = 0
                if let content {
                    AXUIElementGetPid(content, &pid)
                }

                var ident: String? = nil
                if pid == ownPID, let content {
                    ident = readAXString(content, kAXIdentifierAttribute as CFString)
                    if ident == nil || ident?.isEmpty == true {
                        var innerRef: CFTypeRef?
                        if AXUIElementCopyAttributeValue(content, kAXChildrenAttribute as CFString, &innerRef) == .success,
                           let innerFirst = (innerRef as? [AXUIElement])?.first {
                            ident = readAXString(innerFirst, kAXIdentifierAttribute as CFString)
                        }
                    }
                }

                parsedSlots.append(
                    HostedBarSlot(
                        displayID: displayID,
                        hostWindowFrame: hostFrame,
                        frame: frame,
                        sourcePID: pid,
                        identifier: ident
                    )
                )
            }

            parsedSlots.sort { $0.frame.minX < $1.frame.minX }
            candidateWindowsByDisplay[displayID, default: []].append(parsedSlots)
        }

        var finalSlotsByDisplay: [CGDirectDisplayID: [HostedBarSlot]] = [:]
        var chevronsByDisplay: [CGDirectDisplayID: CGRect] = [:]

        for (displayID, candidates) in candidateWindowsByDisplay {
            // Pick the active space's MenuBarAgent window:
            // 1. Prefer candidate matching our own main toggle window frame if on this display
            // 2. Otherwise pick the candidate with the most laid-out slots
            let chosen: [HostedBarSlot]
            if let ownFrame = ownMainToggleFrameCG,
               CGDisplayBounds(displayID).intersects(ownFrame),
               let matching = candidates.first(where: { slots in
                   slots.contains { s in
                       s.sourcePID == ownPID && abs(s.frame.minX - ownFrame.minX) <= 6
                   }
               }) {
                chosen = matching
            } else {
                chosen = candidates.max(by: { $0.count < $1.count }) ?? []
            }

            finalSlotsByDisplay[displayID] = chosen
            if let chevronSlot = chosen.first(where: { $0.isOverflowChevron }) {
                chevronsByDisplay[displayID] = chevronSlot.frame
            }
        }

        return (finalSlotsByDisplay, chevronsByDisplay)
    }

    // MARK: - Legacy macOS 14-15 WindowServer Fallback

    private func readLegacyWindowServerSlots(
        ownPID: pid_t
    ) -> ([CGDirectDisplayID: [HostedBarSlot]], [CGDirectDisplayID: CGRect]) {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return ([:], [:])
        }
        let activeDisplays = Self.activeDisplayIDs()
        var byDisplay: [CGDirectDisplayID: [HostedBarSlot]] = [:]

        for info in windowList {
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 25 else { continue }
            let pid = pid_t(info[kCGWindowOwnerPID as String] as? Int ?? 0)
            guard pid > 0 else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let x = boundsDict["X"] as? Double,
                  let y = boundsDict["Y"] as? Double,
                  let w = boundsDict["Width"] as? Double,
                  let h = boundsDict["Height"] as? Double,
                  w > 0, h > 0, h <= 50 else { continue }

            let rect = CGRect(x: x, y: y, width: w, height: h)
            guard let displayID = activeDisplays.first(where: { CGDisplayBounds($0).intersects(rect) }) else {
                continue
            }
            let dispBounds = CGDisplayBounds(displayID)
            let hostRect = CGRect(x: dispBounds.minX, y: dispBounds.minY, width: dispBounds.width, height: 30)
            byDisplay[displayID, default: []].append(
                HostedBarSlot(
                    displayID: displayID,
                    hostWindowFrame: hostRect,
                    frame: rect,
                    sourcePID: pid,
                    identifier: nil
                )
            )
        }

        for key in byDisplay.keys {
            byDisplay[key]?.sort { $0.frame.minX < $1.frame.minX }
        }
        return (byDisplay, [:])
    }

    // MARK: - AXExtrasMenuBar Per-App Reader

    func readExtrasMenuBarChildren(for pid: pid_t) -> [AXUIElement] {
        guard AXIsProcessTrusted() else { return [] }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.35)

        var barRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, "AXExtrasMenuBar" as CFString, &barRef) == .success,
              let bar = barRef else {
            return []
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return []
        }
        return children
    }

    private func readAXMetadata(_ element: AXUIElement) -> (title: String, desc: String, frame: CGRect?) {
        AXUIElementSetMessagingTimeout(element, 0.3)
        let title = readAXString(element, kAXTitleAttribute as CFString) ?? ""
        let desc = readAXString(element, kAXDescriptionAttribute as CFString) ?? ""
        let frame = readAXFrame(element)
        return (title, desc, frame)
    }

    private func readAXFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef,
              let sizeVal = sizeRef else {
            return nil
        }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &pt)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    private func readAXString(_ element: AXUIElement, _ attr: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &ref) == .success,
              let str = ref as? String,
              !str.isEmpty else {
            return nil
        }
        return str
    }

    // MARK: - Naming & Icon Helpers

    private func friendlyAppName(for app: NSRunningApplication, fallbackDesc: String, fallbackTitle: String) -> String {
        if let bundleID = app.bundleIdentifier {
            switch bundleID {
            case "com.apple.Siri":
                return !fallbackTitle.isEmpty ? fallbackTitle : "Spotlight / Siri"
            case "com.apple.TextInputMenuAgent":
                return "Bộ gõ bàn phím (Input Menu)"
            case "com.google.GeminiMacOS.launcher":
                return "Gemini"
            default:
                break
            }
        }
        if let name = app.localizedName, !name.isEmpty {
            return name
        }
        if !fallbackDesc.isEmpty {
            return fallbackDesc
        }
        if !fallbackTitle.isEmpty {
            return fallbackTitle
        }
        return app.bundleIdentifier ?? "Ứng dụng (\(app.processIdentifier))"
    }

    private func bestIcon(for app: NSRunningApplication) -> NSImage {
        if let bundleID = app.bundleIdentifier {
            if bundleID == "com.apple.TextInputMenuAgent",
               let sym = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Input Menu") {
                return sym
            }
            if bundleID == "com.apple.Siri",
               let sym = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Spotlight") {
                return sym
            }
            // For helper/launcher processes inside a parent .app bundle, resolve parent bundle icon if needed
            if let bundleURL = app.bundleURL {
                let path = bundleURL.path
                if let range = path.range(of: ".app/") {
                    let rootAppPath = String(path[..<range.upperBound].dropLast())
                    let icon = NSWorkspace.shared.icon(forFile: rootAppPath)
                    return icon
                }
            }
        }
        if let icon = app.icon {
            return icon
        }
        return NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) ?? NSImage()
    }

    // MARK: - Display Geometry Utilities

    static func activeDisplayIDs() -> [CGDirectDisplayID] {
        NSScreen.screens.compactMap { screen in
            screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        }
    }

    static func widestDisplayID() -> CGDirectDisplayID? {
        activeDisplayIDs().max(by: { CGDisplayBounds($0).width < CGDisplayBounds($1).width })
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// Converts an AppKit `NSRect` (bottom-left of primary screen) to CoreGraphics `CGRect` (top-left of primary screen).
    static func appKitToCGRect(_ rect: NSRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1440
        return CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Converts a CoreGraphics `CGPoint` (top-left origin) to AppKit `NSPoint` (bottom-left origin).
    static func cgToAppKitPoint(_ point: CGPoint) -> NSPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1440
        return NSPoint(x: point.x, y: primaryHeight - point.y)
    }

    static func cgScreenRect(for screen: NSScreen) -> CGRect {
        appKitToCGRect(screen.frame)
    }

    static func screenContaining(cgPoint: CGPoint) -> NSScreen? {
        let appKitPt = cgToAppKitPoint(cgPoint)
        return NSScreen.screens.first(where: { NSMouseInRect(appKitPt, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func screenContainingMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }
}
