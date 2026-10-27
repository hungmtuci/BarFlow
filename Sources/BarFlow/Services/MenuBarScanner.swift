import Foundation
import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Darwin

/// Represents a physical slot currently laid out on a display's menu bar.
struct HostedBarSlot: Equatable {
    let displayID: CGDirectDisplayID
    let hostWindowFrame: CGRect
    let frame: CGRect
    let sourcePID: pid_t
    let itemID: String?
    let identifier: String?

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
private struct CandidateProcess: Sendable {
    let pid: pid_t
    let bundleID: String?
    let localizedName: String?
    let icon: NSImage
    let isSystem: Bool
    let isMovable: Bool
    let isSystemExtrasContainer: Bool
}

/// Result of probing a single PID's `AXExtrasMenuBar`.
private enum ExtrasProbeResult {
    case found([AXUIElement])
    case definitelyEmpty
    case timedOutOrBusy
}

final class MenuBarScanner: @unchecked Sendable {
    static let shared = MenuBarScanner()

    private let scanQueue = DispatchQueue(label: "com.hunglx.BarFlow.scanner", qos: .userInitiated)
    private let workerQueue = DispatchQueue(label: "com.hunglx.BarFlow.scanner.workers", qos: .userInitiated, attributes: .concurrent)
    private let cacheLock = NSLock()

    /// Known PIDs that exposed at least one Menu Bar item.
    private var knownMenuBarPIDs = Set<pid_t>()
    /// PIDs that definitively returned no `AXExtrasMenuBar` (never populated on IPC timeout!).
    private var negativePIDCache: [pid_t: CFAbsoluteTime] = [:]
    private let negativeCacheTTL: CFAbsoluteTime = 15.0

    /// MainActor-owned pre-rendered `32x32` (@2x) icon cache keyed by PID or symbol key.
    @MainActor private var scaledIconCache: [String: NSImage] = [:]
    /// MainActor-owned cached `CandidateProcess` per PID so warm scans do zero LaunchServices/icon work on MainActor.
    @MainActor private var candidateProcessCache: [pid_t: CandidateProcess] = [:]
    @MainActor private var skippedDaemonPIDs = Set<pid_t>()

    private let systemExtrasContainerBundleIDs: Set<String> = [
        "com.apple.MenuBarAgent",
        "com.apple.controlcenter",
        "com.apple.systemuiserver"
    ]

    private let systemAppBundleIDs: Set<String> = [
        "com.apple.Siri",
        "com.apple.campo",
        "com.apple.Spotlight",
        "com.apple.TextInputMenuAgent",
        "com.apple.Passwords.MenuBarExtra"
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
            scaledIconCache.removeValue(forKey: "pid:\(pid)")
            candidateProcessCache.removeValue(forKey: pid)
            skippedDaemonPIDs.remove(pid)
        } else {
            candidateProcessCache.removeAll()
            skippedDaemonPIDs.removeAll()
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

    // MARK: - Non-Blocking Comprehensive Menu Bar Scan

    /// Scans 100% of running Menu Bar apps & movable system extras concurrently on a background queue.
    @MainActor
    func scanMenuBarAsync(forceFullScan: Bool = false) async -> [MenuBarAppItem] {
        guard AXIsProcessTrusted() else { return [] }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let displays = Self.captureDisplayGeometries()
        let symbolIcons = prepareSystemSymbolIconMap()
        let fallbackDefaultIcon = symbolIcons["default"] ?? NSImage()

        // Capture ALL NSWorkspace runningApplications across .regular, .accessory, AND .prohibited (< 0.05ms with PID cache!)
        let runningApps = NSWorkspace.shared.runningApplications
        var candidatesByPID: [pid_t: CandidateProcess] = [:]
        candidatesByPID.reserveCapacity(runningApps.count)

        for app in runningApps {
            let pid = app.processIdentifier
            guard pid > 0, pid != ownPID else { continue }

            if skippedDaemonPIDs.contains(pid) {
                continue
            }
            if let cachedCandidate = candidateProcessCache[pid] {
                candidatesByPID[pid] = cachedCandidate
                continue
            }

            let bundleID = app.bundleIdentifier
            let name = app.localizedName
            if Self.isKnownNonMenuBarAppleDaemon(bundleID: bundleID, name: name) {
                skippedDaemonPIDs.insert(pid)
                continue
            }

            let isContainer = bundleID.map { systemExtrasContainerBundleIDs.contains($0) } ?? false
            let cacheKey = "pid:\(pid)"
            let icon: NSImage
            if let cached = scaledIconCache[cacheKey] {
                icon = cached
            } else {
                let rendered = preScaleIcon(bestRawIcon(for: app), pointSize: 32)
                scaledIconCache[cacheKey] = rendered
                icon = rendered
            }

            let isSystem = isContainer || (bundleID.map { systemAppBundleIDs.contains($0) || $0.hasPrefix("com.apple.") } ?? false)

            let candidate = CandidateProcess(
                pid: pid,
                bundleID: bundleID,
                localizedName: name,
                icon: icon,
                isSystem: isSystem,
                isMovable: true,
                isSystemExtrasContainer: isContainer
            )
            candidateProcessCache[pid] = candidate
            candidatesByPID[pid] = candidate
        }

        return await withCheckedContinuation { continuation in
            scanQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: [])
                    return
                }
                let items = self.performBackgroundScan(
                    ownPID: ownPID,
                    initialCandidatesByPID: candidatesByPID,
                    displays: displays,
                    symbolIcons: symbolIcons,
                    fallbackDefaultIcon: fallbackDefaultIcon,
                    forceFullScan: forceFullScan
                )
                continuation.resume(returning: items)
            }
        }
    }

    private func performBackgroundScan(
        ownPID: pid_t,
        initialCandidatesByPID: [pid_t: CandidateProcess],
        displays: [DisplayGeometry],
        symbolIcons: [String: NSImage],
        fallbackDefaultIcon: NSImage,
        forceFullScan: Bool
    ) -> [MenuBarAppItem] {
        var candidatesByPID = initialCandidatesByPID

        // 1. Discover any additional PIDs (e.g. raw BSD/Go/Rust binaries not in NSWorkspace) directly from MenuBarAgent slots!
        let agentSlotElementsByPID = readMenuBarAgentSlotElementsByPID(ownPID: ownPID)
        for (slotPID, _) in agentSlotElementsByPID where candidatesByPID[slotPID] == nil {
            let procName = Self.bsdProcessName(for: slotPID)
            candidatesByPID[slotPID] = CandidateProcess(
                pid: slotPID,
                bundleID: nil,
                localizedName: procName,
                icon: fallbackDefaultIcon,
                isSystem: false,
                isMovable: true,
                isSystemExtrasContainer: false
            )
        }

        let allCandidates = Array(candidatesByPID.values)
        guard !allCandidates.isEmpty else { return [] }

        let now = CFAbsoluteTimeGetCurrent()
        cacheLock.lock()
        let knownSnapshot = knownMenuBarPIDs
        let negativeSnapshot = negativePIDCache
        cacheLock.unlock()

        // Always include PIDs currently seen in MenuBarAgent slots, known PIDs, system containers, and non-negatively-cached PIDs
        let toProbe: [CandidateProcess]
        if forceFullScan {
            toProbe = allCandidates
        } else {
            toProbe = allCandidates.filter { proc in
                if proc.isSystemExtrasContainer || knownSnapshot.contains(proc.pid) || agentSlotElementsByPID[proc.pid] != nil {
                    return true
                }
                if let checkedAt = negativeSnapshot[proc.pid], (now - checkedAt) < negativeCacheTTL {
                    return false
                }
                return true
            }
        }

        let resultLock = NSLock()
        var discovered: [MenuBarAppItem] = []
        var newlyPositivePIDs = Set<pid_t>()
        var newlyDefiniteNegativePIDs: [pid_t] = []
        var retryCandidates: [CandidateProcess] = []

        // Bounded concurrency (max 8 concurrent IPC calls) so macOS AX server never drops busy apps
        let semaphore = DispatchSemaphore(value: 8)
        let group = DispatchGroup()

        for proc in toProbe {
            group.enter()
            workerQueue.async {
                defer {
                    semaphore.signal()
                    group.leave()
                }
                semaphore.wait()

                let outcome = self.probeExtrasMenuBar(for: proc.pid, timeout: 0.55)
                switch outcome {
                case .found(let rawChildren):
                    let built = self.buildItems(
                        for: proc,
                        rawChildren: rawChildren,
                        displays: displays,
                        symbolIcons: symbolIcons,
                        agentSlotElementsByPID: agentSlotElementsByPID
                    )
                    resultLock.lock()
                    newlyPositivePIDs.insert(proc.pid)
                    discovered.append(contentsOf: built)
                    resultLock.unlock()

                case .definitelyEmpty:
                    // Check if MenuBarAgent still has a live slot element for this PID
                    if let fallbackElements = agentSlotElementsByPID[proc.pid], !fallbackElements.isEmpty {
                        let built = self.buildItems(
                            for: proc,
                            rawChildren: fallbackElements,
                            displays: displays,
                            symbolIcons: symbolIcons,
                            agentSlotElementsByPID: agentSlotElementsByPID
                        )
                        if !built.isEmpty {
                            resultLock.lock()
                            newlyPositivePIDs.insert(proc.pid)
                            discovered.append(contentsOf: built)
                            resultLock.unlock()
                            return
                        }
                    }
                    resultLock.lock()
                    newlyDefiniteNegativePIDs.append(proc.pid)
                    resultLock.unlock()

                case .timedOutOrBusy:
                    // NEVER mark a timed-out app as negative! Queue for a calm retry pass.
                    resultLock.lock()
                    retryCandidates.append(proc)
                    resultLock.unlock()
                }
            }
        }
        group.wait()

        // Calm retry pass (1.0s timeout) for any app whose runloop was momentarily busy
        for proc in retryCandidates {
            switch probeExtrasMenuBar(for: proc.pid, timeout: 1.0) {
            case .found(let rawChildren):
                let built = buildItems(
                    for: proc,
                    rawChildren: rawChildren,
                    displays: displays,
                    symbolIcons: symbolIcons,
                    agentSlotElementsByPID: agentSlotElementsByPID
                )
                newlyPositivePIDs.insert(proc.pid)
                discovered.append(contentsOf: built)
            case .definitelyEmpty:
                if let fallbackElements = agentSlotElementsByPID[proc.pid], !fallbackElements.isEmpty {
                    let built = buildItems(
                        for: proc,
                        rawChildren: fallbackElements,
                        displays: displays,
                        symbolIcons: symbolIcons,
                        agentSlotElementsByPID: agentSlotElementsByPID
                    )
                    if !built.isEmpty {
                        newlyPositivePIDs.insert(proc.pid)
                        discovered.append(contentsOf: built)
                        continue
                    }
                }
                newlyDefiniteNegativePIDs.append(proc.pid)
            case .timedOutOrBusy:
                if let fallbackElements = agentSlotElementsByPID[proc.pid], !fallbackElements.isEmpty {
                    let built = buildItems(
                        for: proc,
                        rawChildren: fallbackElements,
                        displays: displays,
                        symbolIcons: symbolIcons,
                        agentSlotElementsByPID: agentSlotElementsByPID
                    )
                    if !built.isEmpty {
                        newlyPositivePIDs.insert(proc.pid)
                        discovered.append(contentsOf: built)
                    }
                }
            }
        }

        // Merge any System Menu Extras currently hidden by BarFlow so they remain visible & clickable in `Ctrl + B`!
        let persistedHiddenSys = MenuBarVisibilityEngine.shared.persistedHiddenSystemItems()
        for persisted in persistedHiddenSys {
            let alreadyPresent = discovered.contains { existing in
                if existing.id == persisted.id { return true }
                if let pa = persisted.axIdentifier, !pa.isEmpty, existing.axIdentifier == pa { return true }
                if existing.appName == persisted.appName && existing.isSystemItem { return true }
                return false
            }
            if !alreadyPresent {
                let icon = symbolIcons[persisted.symbolKey] ?? symbolIcons["default"] ?? fallbackDefaultIcon
                discovered.append(
                    MenuBarAppItem(
                        id: persisted.id,
                        pid: 0,
                        appName: persisted.appName,
                        bundleIdentifier: persisted.bundleIdentifier,
                        axIdentifier: persisted.axIdentifier,
                        axChildIndex: 0,
                        appIcon: icon,
                        statusTitle: "",
                        statusDescription: persisted.appName,
                        slotFrame: nil,
                        isCurrentlyOnBar: false,
                        axElement: nil,
                        isSystemItem: true,
                        isMovable: true
                    )
                )
            }
        }

        // Update positive & negative caches safely
        cacheLock.lock()
        for pid in newlyPositivePIDs {
            knownMenuBarPIDs.insert(pid)
            negativePIDCache.removeValue(forKey: pid)
        }
        for pid in newlyDefiniteNegativePIDs where !newlyPositivePIDs.contains(pid) {
            knownMenuBarPIDs.remove(pid)
            negativePIDCache[pid] = now
        }
        cacheLock.unlock()

        // Deduplicate by stable ID while preserving the most informative entry
        var uniqueByID = Set<String>()
        var deduplicated: [MenuBarAppItem] = []
        deduplicated.reserveCapacity(discovered.count)
        for item in discovered {
            if uniqueByID.insert(item.id).inserted {
                deduplicated.append(item)
            }
        }

        // Sort naturally Left -> Right (smallest X first = leftmost on Menu Bar) for items on bar, then alphabetically
        deduplicated.sort { a, b in
            if a.isCurrentlyOnBar != b.isCurrentlyOnBar {
                return a.isCurrentlyOnBar && !b.isCurrentlyOnBar
            }
            if a.slotFrame != nil && b.slotFrame != nil && abs(a.sortX - b.sortX) > 1 {
                return a.sortX < b.sortX
            }
            return a.appName.localizedCaseInsensitiveCompare(b.appName) == .orderedAscending
        }

        return deduplicated
    }

    // MARK: - Item Construction (Supports Multi-Icon Apps & System Menu Extras)

    private func buildItems(
        for proc: CandidateProcess,
        rawChildren: [AXUIElement],
        displays: [DisplayGeometry],
        symbolIcons: [String: NSImage],
        agentSlotElementsByPID: [pid_t: [AXUIElement]]
    ) -> [MenuBarAppItem] {
        guard !rawChildren.isEmpty else { return [] }

        // Case A: System Extras Container (`MenuBarAgent`, `ControlCenter`, `SystemUIServer`)
        if proc.isSystemExtrasContainer {
            var extras: [MenuBarAppItem] = []
            for (idx, rawChild) in rawChildren.enumerated() {
                let playable = unwrapPlayableMenuBarElement(rawChild, timeout: 0.25)
                let (title, desc, innerFrame) = readAXMetadata(playable, timeout: 0.25)
                let frame = innerFrame ?? readAXFrame(rawChild)
                let axID = readAXString(playable, kAXIdentifierAttribute as CFString)
                    ?? readAXString(rawChild, kAXIdentifierAttribute as CFString)

                // Exclude permanently locked Clock & Control Center corner anchors
                if Self.isImmovableCornerSystemExtra(axID: axID, title: title, desc: desc) {
                    continue
                }

                let (extraName, symbolKey) = Self.systemExtraPresentation(axID: axID, title: title, desc: desc)
                let icon = symbolIcons[symbolKey] ?? symbolIcons["default"] ?? proc.icon
                let stableID: String
                if let axID, !axID.isEmpty {
                    stableID = axID
                } else {
                    let cleanKey = desc.isEmpty ? (title.isEmpty ? "\(idx)" : title) : desc
                    stableID = "systemextra:\(proc.bundleID ?? "macos"):\(cleanKey)"
                }

                let isOnBar = Self.isFrameVisiblyOnMenuBar(frame, displays: displays)
                extras.append(
                    MenuBarAppItem(
                        id: stableID,
                        pid: proc.pid,
                        appName: extraName,
                        bundleIdentifier: axID ?? proc.bundleID,
                        axIdentifier: axID,
                        axChildIndex: idx,
                        appIcon: icon,
                        statusTitle: title,
                        statusDescription: desc,
                        slotFrame: frame,
                        isCurrentlyOnBar: isOnBar,
                        axElement: playable,
                        isSystemItem: true,
                        isMovable: true
                    )
                )
            }
            return extras
        }

        // Case B: Standard, Helper, or `.prohibited` Tray Application (1 or MULTIPLE Menu Bar icons!)
        let baseID = proc.bundleID ?? "pid:\(proc.pid):\(proc.localizedName ?? "App")"
        var items: [MenuBarAppItem] = []
        items.reserveCapacity(rawChildren.count)

        let hasMenuBarAgentSlots = !agentSlotElementsByPID.isEmpty
        let isPIDHostedInAgent = !hasMenuBarAgentSlots || (agentSlotElementsByPID[proc.pid] != nil)

        for (idx, rawChild) in rawChildren.enumerated() {
            let playable = unwrapPlayableMenuBarElement(rawChild, timeout: 0.25)
            let (axTitle, axDesc, innerFrame) = readAXMetadata(playable, timeout: 0.25)
            let axFrame = innerFrame ?? readAXFrame(rawChild)
            let axID = readAXString(playable, kAXIdentifierAttribute as CFString)
            let isOnBar = isPIDHostedInAgent && Self.isFrameVisiblyOnMenuBar(axFrame, displays: displays)

            let baseAppName = Self.friendlyAppName(
                bundleID: proc.bundleID,
                localizedName: proc.localizedName,
                pid: proc.pid,
                fallbackDesc: axDesc,
                fallbackTitle: axTitle
            )

            let finalID: String
            let finalName: String
            if rawChildren.count == 1 {
                finalID = baseID
                finalName = baseAppName
            } else {
                let disambiguator = (axID?.isEmpty == false ? axID! : nil)
                    ?? (!axDesc.isEmpty ? axDesc : (!axTitle.isEmpty ? axTitle : "\(idx + 1)"))
                finalID = (idx == 0) ? baseID : "\(baseID)#\(disambiguator)"
                let labelSuffix = !axDesc.isEmpty ? axDesc : (!axTitle.isEmpty ? axTitle : "#\(idx + 1)")
                finalName = (labelSuffix.localizedCaseInsensitiveContains(baseAppName))
                    ? labelSuffix
                    : "\(baseAppName) — \(labelSuffix)"
            }

            items.append(
                MenuBarAppItem(
                    id: finalID,
                    pid: proc.pid,
                    appName: finalName,
                    bundleIdentifier: proc.bundleID,
                    axIdentifier: axID,
                    axChildIndex: idx,
                    appIcon: proc.icon,
                    statusTitle: axTitle,
                    statusDescription: axDesc,
                    slotFrame: axFrame,
                    isCurrentlyOnBar: isOnBar,
                    axElement: playable,
                    isSystemItem: proc.isSystem,
                    isMovable: proc.isMovable
                )
            )
        }

        return items
    }

    // MARK: - AXExtrasMenuBar & MenuBarAgent Readers

    private func probeExtrasMenuBar(for pid: pid_t, timeout: Float) -> ExtrasProbeResult {
        guard AXIsProcessTrusted() else { return .definitelyEmpty }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, timeout)

        var barRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, "AXExtrasMenuBar" as CFString, &barRef)
        switch err {
        case .success:
            guard let bar = barRef else { return .definitelyEmpty }
            let barEl = bar as! AXUIElement
            AXUIElementSetMessagingTimeout(barEl, timeout)
            var childrenRef: CFTypeRef?
            let chErr = AXUIElementCopyAttributeValue(barEl, kAXChildrenAttribute as CFString, &childrenRef)
            if chErr == .cannotComplete {
                return .timedOutOrBusy
            }
            guard chErr == .success, let children = childrenRef as? [AXUIElement], !children.isEmpty else {
                return .definitelyEmpty
            }
            return .found(children)
        case .cannotComplete:
            return .timedOutOrBusy
        default:
            return .definitelyEmpty
        }
    }

    /// Reads hosted slot PIDs and fallback `AXMenuBarItem` elements from `MenuBarAgent` (macOS 26/27).
    private func readMenuBarAgentSlotElementsByPID(ownPID: pid_t) -> [pid_t: [AXUIElement]] {
        guard AXIsProcessTrusted(),
              let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else {
            return [:]
        }
        let agentPID = agent.processIdentifier
        let axAgent = AXUIElementCreateApplication(agentPID)
        AXUIElementSetMessagingTimeout(axAgent, 0.45)

        var winsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axAgent, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let windows = winsRef as? [AXUIElement] else {
            return [:]
        }

        var byPID: [pid_t: [AXUIElement]] = [:]
        // Inspect up to 2 display windows (covers primary + secondary displays quickly in ~8ms)
        for win in windows.prefix(2) {
            var slotsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(win, kAXChildrenAttribute as CFString, &slotsRef) == .success,
                  let slots = slotsRef as? [AXUIElement] else { continue }
            for slot in slots {
                var contentRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(slot, kAXChildrenAttribute as CFString, &contentRef) == .success,
                      let content = (contentRef as? [AXUIElement])?.first else { continue }
                var spid: pid_t = 0
                AXUIElementGetPid(content, &spid)
                guard spid > 0, spid != ownPID, spid != agentPID else { continue }
                if byPID[spid] == nil {
                    byPID[spid] = [content]
                }
            }
        }
        return byPID
    }

    /// Unwraps container groups (`AXHostingView` in `MenuBarAgent` or `AXApplication` -> `AXMenuBar` -> `AXMenuBarItem`)
    /// down to the interactive `AXMenuBarItem` that responds to `AXPress`.
    private func unwrapPlayableMenuBarElement(_ element: AXUIElement, timeout: Float) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, timeout)
        let role = readAXString(element, kAXRoleAttribute as CFString) ?? ""

        if role == "AXGroup" || role == "AXApplication" || role == "AXMenuBar" {
            var chRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &chRef) == .success,
               let children = chRef as? [AXUIElement], !children.isEmpty {
                // For AXApplication, prefer the AXExtrasMenuBar or last AXMenuBar child (not the Apple main menu bar)
                if role == "AXApplication", let lastBar = children.last {
                    return unwrapPlayableMenuBarElement(lastBar, timeout: timeout)
                }
                if let first = children.first {
                    return unwrapPlayableMenuBarElement(first, timeout: timeout)
                }
            }
        }
        return element
    }

    // MARK: - Fast Live Element Lookup (Used When Clicking in `Ctrl + B` or Arranging)

    /// Resolves the exact live `AXUIElement` and CG frame for a `MenuBarAppItem` (`< 3ms`).
    func liveStatusElement(
        for item: MenuBarAppItem,
        preferredDisplay: DisplayGeometry? = nil,
        timeout: Float = 0.20
    ) -> (element: AXUIElement, frame: CGRect?)? {
        // For MenuBarAgent system extras on multi-monitor setups, check the preferred display's MenuBarAgent window first
        if let targetID = item.axIdentifier,
           targetID.hasPrefix("com.apple.menuextra."),
           let preferredDisplay,
           let agentMatch = findMenuBarAgentSystemExtra(identifier: targetID, on: preferredDisplay, timeout: timeout) {
            return agentMatch
        }

        let children = readExtrasMenuBarChildren(for: item.pid, timeout: timeout)
        guard !children.isEmpty else {
            if let fallback = item.axElement {
                AXUIElementSetMessagingTimeout(fallback, timeout)
                return (fallback, readAXFrame(fallback))
            }
            return nil
        }

        // 1. Match by explicit AXIdentifier when present (system extras or multi-item apps)
        if let targetID = item.axIdentifier, !targetID.isEmpty {
            for raw in children {
                let playable = unwrapPlayableMenuBarElement(raw, timeout: timeout)
                let candidateID = readAXString(playable, kAXIdentifierAttribute as CFString)
                    ?? readAXString(raw, kAXIdentifierAttribute as CFString)
                if candidateID == targetID {
                    return (playable, readAXFrame(playable) ?? readAXFrame(raw))
                }
            }
        }

        // 2. Match by child index within bounds
        let chosenRaw = (item.axChildIndex >= 0 && item.axChildIndex < children.count)
            ? children[item.axChildIndex]
            : children[0]
        let playable = unwrapPlayableMenuBarElement(chosenRaw, timeout: timeout)
        return (playable, readAXFrame(playable) ?? readAXFrame(chosenRaw))
    }

    private func findMenuBarAgentSystemExtra(
        identifier: String,
        on display: DisplayGeometry,
        timeout: Float
    ) -> (element: AXUIElement, frame: CGRect?)? {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else {
            return nil
        }
        let axAgent = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(axAgent, timeout)
        var winsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axAgent, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let wins = winsRef as? [AXUIElement] else {
            return nil
        }
        for win in wins {
            guard let winFrame = readAXFrame(win), display.cgFrame.intersects(winFrame) else { continue }
            var slotsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(win, kAXChildrenAttribute as CFString, &slotsRef) == .success,
                  let slots = slotsRef as? [AXUIElement] else { continue }
            for slot in slots {
                var gRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(slot, kAXChildrenAttribute as CFString, &gRef) == .success,
                      let group = (gRef as? [AXUIElement])?.first else { continue }
                let playable = unwrapPlayableMenuBarElement(group, timeout: timeout)
                if readAXString(playable, kAXIdentifierAttribute as CFString) == identifier {
                    return (playable, readAXFrame(playable) ?? readAXFrame(slot))
                }
            }
        }
        return nil
    }

    /// Triggers the always-present Control Center (`com.apple.menuextra.controlcenter`) icon on the active screen (`< 5ms`).
    @MainActor
    func pressControlCenterMenuExtra() -> Bool {
        if let disp = Self.displayGeometryContainingMouse(),
           let match = findMenuBarAgentSystemExtra(identifier: "com.apple.menuextra.controlcenter", on: disp, timeout: 0.20) {
            AXUIElementSetMessagingTimeout(match.element, 0.20)
            let err = AXUIElementPerformAction(match.element, kAXPressAction as CFString)
            if err == .success || err == .cannotComplete {
                return true
            }
        }
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else {
            return false
        }
        let children = readExtrasMenuBarChildren(for: agent.processIdentifier, timeout: 0.20)
        for raw in children {
            let playable = unwrapPlayableMenuBarElement(raw, timeout: 0.20)
            let id = readAXString(playable, kAXIdentifierAttribute as CFString) ?? ""
            if id == "com.apple.menuextra.controlcenter" || id.lowercased().contains("bento") {
                AXUIElementSetMessagingTimeout(playable, 0.20)
                let err = AXUIElementPerformAction(playable, kAXPressAction as CFString)
                return err == .success || err == .cannotComplete
            }
        }
        return false
    }

    func readExtrasMenuBarChildren(for pid: pid_t, timeout: Float = 0.20) -> [AXUIElement] {
        guard case .found(let children) = probeExtrasMenuBar(for: pid, timeout: timeout) else {
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
                    itemID: "BarFlow.MainToggle",
                    identifier: "BarFlow.MainToggle"
                )
            )
        }

        for item in apps {
            guard let (_, frame) = liveStatusElement(for: item, preferredDisplay: display, timeout: 0.18),
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
                    sourcePID: item.pid,
                    itemID: item.id,
                    identifier: item.axIdentifier
                )
            )
        }

        slots.sort { $0.frame.minX < $1.frame.minX }
        return slots
    }

    // MARK: - Process Classification, Friendly Naming & Icon Helpers

    private static func isKnownNonMenuBarAppleDaemon(bundleID: String?, name: String?) -> Bool {
        if let n = name, n == "universalaccessd" {
            return true
        }
        guard let b = bundleID else { return false }
        if b.hasPrefix("com.apple.WebKit.") ||
           b.hasPrefix("com.apple.Virtualization.") ||
           b.localizedCaseInsensitiveContains("widget") ||
           b.localizedCaseInsensitiveContains("appintentsextension") ||
           b == "com.apple.ViewBridgeAuxiliary" ||
           b == "com.apple.UIKitSystemApp" ||
           b == "com.apple.chronod" ||
           b == "com.apple.sharingd" ||
           b == "com.apple.universalcontrol" {
            return true
        }
        return false
    }

    private static func isImmovableCornerSystemExtra(axID: String?, title: String, desc: String) -> Bool {
        if let id = axID?.lowercased() {
            if id == "com.apple.menuextra.clock" || id == "com.apple.menuextra.controlcenter" || id.contains("bento") {
                return true
            }
        }
        let d = desc.lowercased()
        if d == "clock" || d == "control center" || d == "đồng hồ" || d == "trung tâm điều khiển" {
            return true
        }
        return false
    }

    private static func systemExtraPresentation(axID: String?, title: String, desc: String) -> (name: String, symbolKey: String) {
        let key = (axID ?? "").lowercased() + " " + desc.lowercased() + " " + title.lowercased()
        if key.contains("wifi") || key.contains("wi-fi") || key.contains("wi‑fi") {
            return ("Wi-Fi", "wifi")
        }
        if key.contains("battery") || key.contains("pin") {
            return ("Pin (Battery)", "battery")
        }
        if key.contains("airplay") || key.contains("mirror") || key.contains("display") || key.contains("phản chiếu") {
            return ("Phản chiếu màn hình (Screen Mirroring)", "mirror")
        }
        if key.contains("bluetooth") {
            return ("Bluetooth", "bluetooth")
        }
        if key.contains("sound") || key.contains("volume") || key.contains("âm thanh") {
            return ("Âm thanh (Sound)", "sound")
        }
        if key.contains("focus") || key.contains("dnd") || key.contains("tập trung") {
            return ("Tập trung (Focus)", "focus")
        }
        if key.contains("nowplaying") || key.contains("now playing") {
            return ("Đang phát (Now Playing)", "nowplaying")
        }
        if key.contains("timemachine") || key.contains("time machine") {
            return ("Time Machine", "timemachine")
        }
        if key.contains("vpn") || key.contains("network") {
            return ("VPN", "vpn")
        }
        if key.contains("user") || key.contains("người dùng") {
            return ("Người dùng (Fast User Switching)", "user")
        }
        if key.contains("siri") {
            return ("Siri", "siri")
        }
        if key.contains("spotlight") {
            return ("Spotlight", "spotlight")
        }
        let fallback = !desc.isEmpty ? desc : (!title.isEmpty ? title : "Tiện ích hệ thống")
        return (fallback, "default")
    }

    private static func friendlyAppName(
        bundleID: String?,
        localizedName: String?,
        pid: pid_t,
        fallbackDesc: String,
        fallbackTitle: String
    ) -> String {
        if let bundleID {
            switch bundleID {
            case "com.apple.campo", "com.apple.Spotlight":
                return "Spotlight"
            case "com.apple.Siri":
                return !fallbackTitle.isEmpty ? fallbackTitle : "Siri / Spotlight"
            case "com.apple.TextInputMenuAgent":
                return "Bộ gõ bàn phím (Input Menu)"
            case "com.apple.Passwords.MenuBarExtra":
                return "Mật khẩu (Passwords)"
            case "com.philandro.anydesk":
                return "AnyDesk"
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

    private static func bsdProcessName(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 1024)
        let len = proc_name(pid, &buffer, UInt32(buffer.count))
        guard len > 0 else { return nil }
        return String(cString: buffer)
    }

    @MainActor
    private func prepareSystemSymbolIconMap() -> [String: NSImage] {
        let specs: [(String, String)] = [
            ("wifi", "wifi"),
            ("battery", "battery.100percent"),
            ("mirror", "rectangle.on.rectangle"),
            ("bluetooth", "dot.radiowaves.left.and.right"),
            ("sound", "speaker.wave.2.fill"),
            ("focus", "moon.fill"),
            ("nowplaying", "play.circle.fill"),
            ("timemachine", "clock.arrow.circlepath"),
            ("vpn", "network"),
            ("user", "person.crop.circle"),
            ("siri", "mic.circle.fill"),
            ("spotlight", "magnifyingglass"),
            ("keyboard", "keyboard"),
            ("default", "menubar.rectangle")
        ]
        var map: [String: NSImage] = [:]
        for (key, sfName) in specs {
            let cacheKey = "sym:\(key)"
            if let cached = scaledIconCache[cacheKey] {
                map[key] = cached
            } else if let raw = NSImage(systemSymbolName: sfName, accessibilityDescription: key) {
                let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
                let configured = raw.withSymbolConfiguration(config) ?? raw
                configured.isTemplate = true
                scaledIconCache[cacheKey] = configured
                map[key] = configured
            }
        }
        return map
    }

    @MainActor
    private func bestRawIcon(for app: NSRunningApplication) -> NSImage {
        if let bundleID = app.bundleIdentifier {
            if bundleID == "com.apple.TextInputMenuAgent",
               let sym = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Input Menu") {
                sym.isTemplate = true
                return sym
            }
            if (bundleID == "com.apple.Siri" || bundleID == "com.apple.campo" || bundleID == "com.apple.Spotlight"),
               let sym = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Spotlight") {
                sym.isTemplate = true
                return sym
            }
            if bundleID == "com.apple.Passwords.MenuBarExtra",
               let sym = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "Passwords") {
                sym.isTemplate = true
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
        if let bundleURL = app.bundleURL {
            return NSWorkspace.shared.icon(forFile: bundleURL.path)
        }
        return NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) ?? NSImage()
    }

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
        return abs(f.minY - display.cgFrame.minY) <= (display.menuBarThickness + 18)
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
    static func displayGeometryContainingMouse() -> DisplayGeometry? {
        let screen = screenContainingMouse()
        guard let targetID = displayID(for: screen) else {
            return captureDisplayGeometries().first
        }
        return captureDisplayGeometries().first(where: { $0.displayID == targetID })
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
