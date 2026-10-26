import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

/// Represents a physical slot currently laid out on a display's menu bar.
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

/// Thread-safe snapshot of a display's geometry captured on MainActor for background scanning.
struct DisplayGeometry: Sendable {
    let displayID: CGDirectDisplayID
    let appKitFrame: CGRect
    let cgFrame: CGRect
    let menuBarThickness: CGFloat
}

/// Lightweight process descriptor captured on MainActor before background AX queries.
private struct CandidateProcess {
    let pid: pid_t
    let bundleID: String?
    let localizedName: String?
    let icon: NSImage
    let isSystem: Bool
    let isMovable: Bool
}

final class MenuBarScanner: @unchecked Sendable {
    static let shared = MenuBarScanner()

    private let scanQueue = DispatchQueue(label: "com.hunglx.BarFlow.scanner", qos: .userInitiated)
    private let cacheLock = NSLock()

    /// Known PIDs that exposed at least one `AXExtrasMenuBar` item.
    private var knownMenuBarPIDs = Set<pid_t>()
    /// PIDs that had no `AXExtrasMenuBar` items and the timestamp they were checked.
    private var negativePIDCache: [pid_t: CFAbsoluteTime] = [:]
    /// Negative cache TTL (seconds) so newly created status items in running apps are still discovered.
    private let negativeCacheTTL: CFAbsoluteTime = 12.0

    /// MainActor-owned pre-rendered `32x32` (@2x) icon cache keyed by PID so SwiftUI never downscales `512x512` icons.
    @MainActor private var scaledIconCache: [pid_t: NSImage] = [:]

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

    private let excludedContainerBundleIDs: Set<String> = [
        "com.apple.MenuBarAgent",
        "com.apple.controlcenter",
        "com.apple.systemuiserver"
    ]

    private init() {}

    // MARK: - Accessibility Permission Helpers

    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    @MainActor
    func promptForAccessibilityPermission(openSystemSettings: Bool = false) {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if openSystemSettings,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Cache Invalidation

    @MainActor
    func handleAppLaunched() {
        cacheLock.lock()
        negativePIDCache.removeAll()
        cacheLock.unlock()
    }

    @MainActor
    func handleAppTerminated(pid: pid_t) {
        if pid > 0 {
            scaledIconCache.removeValue(forKey: pid)
        }
        cacheLock.lock()
        if pid > 0 {
            knownMenuBarPIDs.remove(pid)
            negativePIDCache.removeValue(forKey: pid)
        } else {
            negativePIDCache.removeAll()
        }
        cacheLock.unlock()
    }

    // MARK: - Non-Blocking Async Menu Bar Scan

    /// Scans all running Menu Bar apps concurrently on a background queue (`0ms` main-thread blocking).
    @MainActor
    func scanMenuBarAsync(forceFullScan: Bool = false) async -> [MenuBarAppItem] {
        guard AXIsProcessTrusted() else { return [] }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let displays = Self.captureDisplayGeometries()

        // Capture lightweight metadata & pre-scaled 32x32 icons on MainActor (< 0.4ms warm)
        let runningApps = NSWorkspace.shared.runningApplications
        var activePIDSet = Set<pid_t>()
        var candidates: [CandidateProcess] = []
        candidates.reserveCapacity(runningApps.count)

        for app in runningApps {
            let pid = app.processIdentifier
            guard pid > 0, pid != ownPID, app.activationPolicy != .prohibited else { continue }
            activePIDSet.insert(pid)

            let bundleID = app.bundleIdentifier
            if let bundleID, excludedContainerBundleIDs.contains(bundleID) {
                continue
            }

            let icon: NSImage
            if let cached = scaledIconCache[pid] {
                icon = cached
            } else {
                let rendered = preScaleIcon(bestRawIcon(for: app), pointSize: 32)
                scaledIconCache[pid] = rendered
                icon = rendered
            }

            let isSystem = bundleID.map { systemBundleIDs.contains($0) || $0.hasPrefix("com.apple.") } ?? false
            let isMovable = !(bundleID.map { immovableBundleIDs.contains($0) } ?? false)

            candidates.append(
                CandidateProcess(
                    pid: pid,
                    bundleID: bundleID,
                    localizedName: app.localizedName,
                    icon: icon,
                    isSystem: isSystem,
                    isMovable: isMovable
                )
            )
        }

        // Prune stale icons from terminated processes
        if scaledIconCache.count > activePIDSet.count + 8 {
            scaledIconCache = scaledIconCache.filter { activePIDSet.contains($0.key) }
        }

        return await withCheckedContinuation { continuation in
            scanQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: [])
                    return
                }
                let items = self.performBackgroundScan(
                    candidates: candidates,
                    displays: displays,
                    forceFullScan: forceFullScan
                )
                continuation.resume(returning: items)
            }
        }
    }

    private func performBackgroundScan(
        candidates: [CandidateProcess],
        displays: [DisplayGeometry],
        forceFullScan: Bool
    ) -> [MenuBarAppItem] {
        guard !candidates.isEmpty else { return [] }

        let now = CFAbsoluteTimeGetCurrent()
        cacheLock.lock()
        let knownSnapshot = knownMenuBarPIDs
        let negativeSnapshot = negativePIDCache
        cacheLock.unlock()

        // Filter candidates using negative cache on warm scans
        let toProbe: [CandidateProcess]
        if forceFullScan {
            toProbe = candidates
        } else {
            toProbe = candidates.filter { proc in
                if knownSnapshot.contains(proc.pid) { return true }
                if let checkedAt = negativeSnapshot[proc.pid], (now - checkedAt) < negativeCacheTTL {
                    return false
                }
                return true
            }
        }

        let resultLock = NSLock()
        var discovered: [MenuBarAppItem] = []
        var newlyPositivePIDs = Set<pid_t>()
        var newlyNegativePIDs: [pid_t] = []

        DispatchQueue.concurrentPerform(iterations: toProbe.count) { idx in
            let proc = toProbe[idx]
            let children = self.readExtrasMenuBarChildren(for: proc.pid, timeout: 0.15)
            guard let primaryAX = children.first else {
                resultLock.lock()
                newlyNegativePIDs.append(proc.pid)
                resultLock.unlock()
                return
            }

            let (axTitle, axDesc, axFrame) = self.readAXMetadata(primaryAX, timeout: 0.15)
            let isOnBar = Self.isFrameVisiblyOnMenuBar(axFrame, displays: displays)
            let stableID = proc.bundleID ?? "pid:\(proc.pid):\(proc.localizedName ?? "App")"
            let appName = Self.friendlyAppName(
                bundleID: proc.bundleID,
                localizedName: proc.localizedName,
                pid: proc.pid,
                fallbackDesc: axDesc,
                fallbackTitle: axTitle
            )

            let item = MenuBarAppItem(
                id: stableID,
                pid: proc.pid,
                appName: appName,
                bundleIdentifier: proc.bundleID,
                appIcon: proc.icon,
                statusTitle: axTitle,
                statusDescription: axDesc,
                slotFrame: axFrame,
                isCurrentlyOnBar: isOnBar,
                axElement: primaryAX,
                isSystemItem: proc.isSystem,
                isMovable: proc.isMovable
            )

            resultLock.lock()
            newlyPositivePIDs.insert(proc.pid)
            discovered.append(item)
            resultLock.unlock()
        }

        // Update positive/negative caches
        cacheLock.lock()
        for pid in newlyPositivePIDs {
            knownMenuBarPIDs.insert(pid)
            negativePIDCache.removeValue(forKey: pid)
        }
        for pid in newlyNegativePIDs {
            knownMenuBarPIDs.remove(pid)
            negativePIDCache[pid] = now
        }
        cacheLock.unlock()

        // Deduplicate by stable ID and sort right-to-left (largest X first = rightmost on menu bar)
        var uniqueByID = Set<String>()
        var deduplicated: [MenuBarAppItem] = []
        deduplicated.reserveCapacity(discovered.count)
        for item in discovered {
            if uniqueByID.insert(item.id).inserted {
                deduplicated.append(item)
            }
        }

        deduplicated.sort { a, b in
            if a.isCurrentlyOnBar != b.isCurrentlyOnBar {
                return a.isCurrentlyOnBar && !b.isCurrentlyOnBar
            }
            if abs(a.sortX - b.sortX) > 1 {
                return a.sortX > b.sortX
            }
            return a.appName.localizedCaseInsensitiveCompare(b.appName) == .orderedAscending
        }

        return deduplicated
    }

    // MARK: - Fast Single-PID Status Item Lookup (Used on Click)

    /// Queries the live `AXExtrasMenuBar` status item element and CG frame for a single PID (`< 2ms`).
    /// Safe to invoke from any background queue.
    func liveStatusElement(for pid: pid_t, timeout: Float = 0.18) -> (element: AXUIElement, frame: CGRect?)? {
        let children = readExtrasMenuBarChildren(for: pid, timeout: timeout)
        guard let first = children.first else { return nil }
        AXUIElementSetMessagingTimeout(first, timeout)
        let frame = readAXFrame(first)
        return (first, frame)
    }

    func readExtrasMenuBarChildren(for pid: pid_t, timeout: Float = 0.18) -> [AXUIElement] {
        guard AXIsProcessTrusted() else { return [] }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, timeout)

        var barRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, "AXExtrasMenuBar" as CFString, &barRef) == .success,
              let bar = barRef else {
            return []
        }

        let barEl = bar as! AXUIElement
        AXUIElementSetMessagingTimeout(barEl, timeout)

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(barEl, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return []
        }
        return children
    }

    func readAXFrame(_ element: AXUIElement) -> CGRect? {
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

    private func readAXMetadata(_ element: AXUIElement, timeout: Float) -> (title: String, desc: String, frame: CGRect?) {
        AXUIElementSetMessagingTimeout(element, timeout)
        let title = readAXString(element, kAXTitleAttribute as CFString) ?? ""
        let desc = readAXString(element, kAXDescriptionAttribute as CFString) ?? ""
        let frame = readAXFrame(element)
        return (title, desc, frame)
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

    // MARK: - Live Slot Map for Physical ⌘-Drag Arrangement

    /// Builds an accurate left-to-right slot list on `targetDisplay` using live `AXExtrasMenuBar` frames.
    func readLiveSlotsForArrangement(
        apps: [MenuBarAppItem],
        ownPID: pid_t,
        ownMainToggleFrameCG: CGRect?,
        on display: DisplayGeometry
    ) -> [HostedBarSlot] {
        var slots: [HostedBarSlot] = []
        let hostRect = CGRect(
            x: display.cgFrame.minX,
            y: display.cgFrame.minY,
            width: display.cgFrame.width,
            height: display.menuBarThickness
        )

        if let ownRect = ownMainToggleFrameCG, display.cgFrame.intersects(ownRect) {
            slots.append(
                HostedBarSlot(
                    displayID: display.displayID,
                    hostWindowFrame: hostRect,
                    frame: ownRect,
                    sourcePID: ownPID,
                    identifier: "BarFlow.MainToggle"
                )
            )
        }

        for app in apps {
            guard let (_, frame) = liveStatusElement(for: app.pid, timeout: 0.15),
                  let rect = frame,
                  rect.width > 0,
                  Self.isFrameVisiblyOnDisplayMenuBar(rect, display: display) else {
                continue
            }
            slots.append(
                HostedBarSlot(
                    displayID: display.displayID,
                    hostWindowFrame: hostRect,
                    frame: rect,
                    sourcePID: app.pid,
                    identifier: app.id
                )
            )
        }

        slots.sort { $0.frame.minX < $1.frame.minX }
        return slots
    }

    // MARK: - Naming & Crisp Icon Pre-Scaling

    private static func friendlyAppName(
        bundleID: String?,
        localizedName: String?,
        pid: pid_t,
        fallbackDesc: String,
        fallbackTitle: String
    ) -> String {
        if let bundleID {
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
        if let name = localizedName, !name.isEmpty {
            return name
        }
        if !fallbackDesc.isEmpty {
            return fallbackDesc
        }
        if !fallbackTitle.isEmpty {
            return fallbackTitle
        }
        return bundleID ?? "Ứng dụng (\(pid))"
    }

    @MainActor
    private func bestRawIcon(for app: NSRunningApplication) -> NSImage {
        if let bundleID = app.bundleIdentifier {
            if bundleID == "com.apple.TextInputMenuAgent",
               let sym = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Input Menu") {
                return sym
            }
            if bundleID == "com.apple.Siri",
               let sym = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Spotlight") {
                return sym
            }
            if let bundleURL = app.bundleURL {
                let path = bundleURL.path
                if let range = path.range(of: ".app/") {
                    let rootAppPath = String(path[..<range.upperBound].dropLast())
                    return NSWorkspace.shared.icon(forFile: rootAppPath)
                }
            }
        }
        if let icon = app.icon {
            return icon
        }
        return NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) ?? NSImage()
    }

    /// Renders any `NSImage` once into a lightweight `64x64` pixel (`32x32` pt @2x) bitmap so SwiftUI renders at 120fps.
    @MainActor
    private func preScaleIcon(_ source: NSImage, pointSize: CGFloat) -> NSImage {
        if source.isTemplate {
            let copy = (source.copy() as? NSImage) ?? source
            copy.size = NSSize(width: pointSize, height: pointSize)
            return copy
        }
        let px = Int(pointSize * 2.0)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: px,
            pixelsHigh: px,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return source
        }
        rep.size = NSSize(width: pointSize, height: pointSize)

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            ctx.imageInterpolation = .high
            NSGraphicsContext.current = ctx
            source.draw(
                in: NSRect(x: 0, y: 0, width: pointSize, height: pointSize),
                from: .zero,
                operation: .copy,
                fraction: 1.0
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        let out = NSImage(size: NSSize(width: pointSize, height: pointSize))
        out.addRepresentation(rep)
        return out
    }

    // MARK: - Display Geometry Utilities

    static func isFrameVisiblyOnMenuBar(_ frame: CGRect?, displays: [DisplayGeometry]) -> Bool {
        guard let f = frame, f.width > 1, f.height > 1 else { return false }
        return displays.contains { isFrameVisiblyOnDisplayMenuBar(f, display: $0) }
    }

    static func isFrameVisiblyOnDisplayMenuBar(_ f: CGRect, display: DisplayGeometry) -> Bool {
        guard f.midX >= display.cgFrame.minX && f.midX <= display.cgFrame.maxX else {
            return false
        }
        return abs(f.minY - display.cgFrame.minY) <= (display.menuBarThickness + 16)
    }

    @MainActor
    static func captureDisplayGeometries() -> [DisplayGeometry] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1440
        return NSScreen.screens.compactMap { screen in
            guard let id = displayID(for: screen) else { return nil }
            let f = screen.frame
            let cgRect = CGRect(
                x: f.origin.x,
                y: primaryHeight - f.maxY,
                width: f.width,
                height: f.height
            )
            let thickness = effectiveMenuBarThickness(for: screen)
            return DisplayGeometry(
                displayID: id,
                appKitFrame: f,
                cgFrame: cgRect,
                menuBarThickness: thickness
            )
        }
    }

    @MainActor
    static func effectiveMenuBarThickness(for screen: NSScreen) -> CGFloat {
        max(
            screen.frame.maxY - screen.visibleFrame.maxY,
            screen.safeAreaInsets.top,
            30.0
        )
    }

    @MainActor
    static func widestDisplayGeometry() -> DisplayGeometry? {
        captureDisplayGeometries().max(by: { $0.cgFrame.width < $1.cgFrame.width })
    }

    @MainActor
    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    @MainActor
    static func appKitToCGRect(_ rect: NSRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1440
        return CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    @MainActor
    static func cgToAppKitPoint(_ point: CGPoint) -> NSPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1440
        return NSPoint(x: point.x, y: primaryHeight - point.y)
    }

    @MainActor
    static func screenContainingMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }
}
