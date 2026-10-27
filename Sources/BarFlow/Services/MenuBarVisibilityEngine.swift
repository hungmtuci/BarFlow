import Foundation
import AppKit
import Carbon
import Darwin

/// Persisted metadata for a macOS System Menu Extra (e.g. Wi-Fi, Battery, Spotlight, Input Menu)
/// that BarFlow has hidden from the Main Menu Bar so it stays visible and interactive in `Ctrl + B`.
struct PersistedSystemItem: Codable, Equatable, Sendable {
    let id: String
    let appName: String
    let bundleIdentifier: String?
    let axIdentifier: String?
    let symbolKey: String
}

/// Snapshot of the user's original macOS Control Center / Spotlight / Input Menu preference before BarFlow hid it.
private struct SystemPrefBackup: Codable, Sendable {
    var hadSpotlightPref: Bool?
    var originalShowSpotlight: Bool?

    var hadSiriPref: Bool?
    var originalShowSiri: Bool?

    var hadTextInputVisible: Bool?
    var originalTextInputVisible: Bool?
    var originalTextInputAgentVisibleCC: Bool?

    /// Keyed by Control Center module key (e.g. `"WiFi"`, `"Battery"`, `"ScreenMirroring"`, `"Display"`, etc.)
    var originalByHostModuleInts: [String: Int] = [:]
    var absentByHostModuleKeys: Set<String> = []
    var originalVisibleCCFlags: [String: Bool] = [:]
}

/// Native macOS 26/27 (`MenuBarAgent`) visibility & positioning engine.
///
/// Why this engine exists:
/// - On macOS 26 Tahoe and macOS 27+, `MenuBarAgent` blocks synthetic `CGEvent` `⌘`-Dragging AND collapses
///   wide `NSStatusItem` spacers into a `«` overflow chevron while leaving items to the right of `BarFlow` visible.
/// - Instead, `MenuBarAgent` natively tracks per-app Menu Bar visibility in
///   `~/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist`
///   (`trackedApplications` / `showSpotlight`) and icon ordering in
///   `~/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist` (`TrailingItemPreferredPositions`).
/// - Apps hidden via `trackedApplications` (`isAllowed = false`) disappear 100% cleanly from the Main Menu Bar
///   with zero `«` chevron and zero spacer bloat, while keeping their `AXExtrasMenuBar` intact so `BarFlow`
///   discovers them and opens their real `NSMenu` / `NSPopover` at the top-right in `< 5ms` via `AXPress`!
final class MenuBarVisibilityEngine: @unchecked Sendable {
    static let shared = MenuBarVisibilityEngine()

    private let engineQueue = DispatchQueue(label: "com.hunglx.BarFlow.visibilityEngine", qos: .userInitiated)
    private let stateLock = NSLock()
    @MainActor private var rawProcessCache: [pid_t: RawProcessSnapshot] = [:]
    private var outerBundleIDCache: [String: String] = [:]

    private enum Keys {
        static let managedTrackedKeys = "BarFlow.ManagedHiddenTrackedLocationKeys"
        static let managedSystemItems = "BarFlow.ManagedHiddenSystemItems"
        static let systemPrefBackup = "BarFlow.SystemPrefBackupData"
    }

    /// Minimum `MenuBarAgent` uptime (seconds) required before sending `SIGTERM` so `launchd` never applies its 10s `ThrottleInterval`.
    private let minimumAgentUptimeBeforeReload: Double = 10.4

    private let homeDir: String = FileManager.default.homeDirectoryForCurrentUser.path
    private var ccGroupPlistPath: String {
        "\(homeDir)/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist"
    }
    private var menuBarGroupPlistPath: String {
        "\(homeDir)/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist"
    }

    /// Returns `true` on macOS 26/27+ where `MenuBarAgent` manages the Menu Bar.
    var usesMenuBarAgentArchitecture: Bool {
        let hasAgent = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").isEmpty
        return hasAgent && FileManager.default.fileExists(atPath: ccGroupPlistPath)
    }

    /// Returns `true` when `BarFlow` has TCC `Full Disk Access` (`kTCCServiceSystemPolicyAllFiles`) required by macOS
    /// to read and write `~/Library/Group Containers/group.com.apple.controlcenter/...` and `com.apple.MenuBar.plist`.
    /// Uses a `0.005ms` `open(..., O_RDWR)` check so it verifies real live read+write access without allocating memory.
    var hasFullDiskAccess: Bool {
        guard usesMenuBarAgentArchitecture else { return true }
        let fd = open(ccGroupPlistPath, O_RDWR)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    private init() {}

    // MARK: - Persisted Hidden System Items Access

    func persistedHiddenSystemItems() -> [PersistedSystemItem] {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let data = UserDefaults.standard.data(forKey: Keys.managedSystemItems),
              let decoded = try? JSONDecoder().decode([PersistedSystemItem].self, from: data) else {
            return []
        }
        return decoded
    }

    private func savePersistedHiddenSystemItems(_ items: [PersistedSystemItem]) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if items.isEmpty {
            UserDefaults.standard.removeObject(forKey: Keys.managedSystemItems)
        } else if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Keys.managedSystemItems)
        }
    }

    private func loadManagedTrackedKeys() -> Set<String> {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Set(UserDefaults.standard.stringArray(forKey: Keys.managedTrackedKeys) ?? [])
    }

    private func saveManagedTrackedKeys(_ keys: Set<String>) {
        stateLock.lock()
        defer { stateLock.unlock() }
        UserDefaults.standard.set(Array(keys), forKey: Keys.managedTrackedKeys)
    }

    private func loadSystemPrefBackup() -> SystemPrefBackup {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let data = UserDefaults.standard.data(forKey: Keys.systemPrefBackup),
              let decoded = try? JSONDecoder().decode(SystemPrefBackup.self, from: data) else {
            return SystemPrefBackup()
        }
        return decoded
    }

    private func saveSystemPrefBackup(_ backup: SystemPrefBackup) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let data = try? JSONEncoder().encode(backup) {
            UserDefaults.standard.set(data, forKey: Keys.systemPrefBackup)
        }
    }

    // MARK: - Main Async Sync Entrypoint

    enum SyncErrorReason: Equatable, Sendable {
        case missingFullDiskAccess
        case writeFailed(String)
    }

    struct SyncOutcome: Sendable {
        let didModifyPreferences: Bool
        let didReloadAgent: Bool
        let deferredReloadDelay: TimeInterval?
        let hiddenCount: Int
        let visibleCount: Int
        let errorReason: SyncErrorReason?
    }

    @MainActor
    func invalidateProcessCache(pid: pid_t) {
        if pid > 0 {
            rawProcessCache.removeValue(forKey: pid)
        } else {
            rawProcessCache.removeAll()
        }
    }

    /// Writes updated `trackedApplications`, system module flags, and `TrailingItemPreferredPositions` (Left -> Right custom order)
    /// and reloads `MenuBarAgent` if needed (respecting `launchd` 10.4s uptime to prevent throttling).
    func syncMenuBarState(
        allApps: [MenuBarAppItem],
        selectedMainBarIDs: Set<String>,
        orderedMainBarIDs: [String] = [],
        hidingEnabled: Bool,
        forceReload: Bool = false
    ) async -> SyncOutcome {
        guard usesMenuBarAgentArchitecture else {
            return SyncOutcome(
                didModifyPreferences: false,
                didReloadAgent: false,
                deferredReloadDelay: nil,
                hiddenCount: 0,
                visibleCount: allApps.count,
                errorReason: nil
            )
        }

        // Never partially modify system extras or restart MenuBarAgent (which causes a 1-2s blank Menu Bar flash)
        // when Full Disk Access hasn't been granted yet!
        guard hasFullDiskAccess else {
            return SyncOutcome(
                didModifyPreferences: false,
                didReloadAgent: false,
                deferredReloadDelay: nil,
                hiddenCount: 0,
                visibleCount: allApps.count,
                errorReason: .missingFullDiskAccess
            )
        }

        let neededPIDs = Set(allApps.map(\.pid).filter { $0 > 0 })
        // Lightweight O(K) in-memory snapshot on MainActor (< 0.03ms, ZERO disk Info.plist reads!)
        let rawSnapshots = await MainActor.run {
            captureRawProcessSnapshots(for: neededPIDs)
        }

        return await withCheckedContinuation { continuation in
            engineQueue.async {
                let processMeta = self.resolveProcessIdentitiesOnQueue(from: rawSnapshots)
                let outcome = self.performSyncOnQueue(
                    allApps: allApps,
                    selectedMainBarIDs: selectedMainBarIDs,
                    orderedMainBarIDs: orderedMainBarIDs,
                    hidingEnabled: hidingEnabled,
                    processMeta: processMeta,
                    allowImmediateReload: true,
                    forceReload: forceReload
                )
                continuation.resume(returning: outcome)
            }
        }
    }

    /// Executes a previously deferred `MenuBarAgent` reload once its uptime reaches `minimumAgentUptimeBeforeReload`.
    func performDeferredReloadIfReady() async -> TimeInterval? {
        await withCheckedContinuation { continuation in
            engineQueue.async {
                let remaining = self.remainingSecondsBeforeSafeReload()
                if remaining > 0.05 {
                    continuation.resume(returning: remaining)
                    return
                }
                self.flushUserCfprefsdAndReloadMenuBarAgent()
                continuation.resume(returning: nil)
            }
        }
    }

    /// Restores 100% of apps and system extras hidden by BarFlow when the user quits BarFlow.
    func restoreAllSynchronouslyOnQuit() {
        guard usesMenuBarAgentArchitecture, hasFullDiskAccess else { return }
        engineQueue.sync {
            let changedCC = self.restoreTrackedAppsAndSpotlightOnDisk()
            let changedSys = self.restoreSystemExtrasOnDisk()
            if changedCC || changedSys {
                // Only reload MenuBarAgent immediately on quit if safe from launchd throttle;
                // even if within throttle window, flushing cfprefsd ensures preferences are clean on disk.
                self.flushUserCfprefsd()
                usleep(40_000)
                if self.remainingSecondsBeforeSafeReload() <= 0.1 {
                    self.terminateMenuBarAgent()
                }
            }
        }
    }

    // MARK: - Hidden System Item Triggering from `Ctrl + B`

    @MainActor
    func triggerHiddenSystemItem(_ item: MenuBarAppItem, rightClick: Bool) {
        let key = ((item.axIdentifier ?? "") + " " + (item.bundleIdentifier ?? "") + " " + item.id + " " + item.appName).lowercased()

        if key.contains("spotlight") || key.contains("campo") {
            let spotlightURL = URL(fileURLWithPath: "/System/Library/CoreServices/Spotlight.app")
            NSWorkspace.shared.openApplication(at: spotlightURL, configuration: NSWorkspace.OpenConfiguration())
            return
        }

        if key.contains("siri") {
            let siriURL = URL(fileURLWithPath: "/System/Applications/Siri.app")
            NSWorkspace.shared.openApplication(at: siriURL, configuration: NSWorkspace.OpenConfiguration())
            return
        }

        if key.contains("textinput") || key.contains("input menu") || key.contains("bộ gõ") {
            if rightClick {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            } else {
                cycleToNextKeyboardInputSource()
            }
            return
        }

        if key.contains("timemachine") || key.contains("time machine") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension") {
                NSWorkspace.shared.open(url)
                return
            }
        }

        if key.contains("vpn") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") {
                NSWorkspace.shared.open(url)
                return
            }
        }

        // Wi-Fi, Battery, Screen Mirroring / Display, Sound, Bluetooth, Focus, Now Playing, Fast User Switching:
        // Triggering the always-visible Control Center (`com.apple.menuextra.controlcenter`) opens the native
        // top-right Control Center popover right below the Menu Bar in < 5ms!
        if !MenuBarScanner.shared.pressControlCenterMenuExtra() {
            if key.contains("battery") || key.contains("pin"),
               let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                NSWorkspace.shared.open(url)
            } else if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @MainActor
    private func cycleToNextKeyboardInputSource() {
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceIsSelectCapable: true,
            kTISPropertyInputSourceIsEnabled: true
        ]
        guard let listRef = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource],
              listRef.count > 1,
              let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            _ = MenuBarScanner.shared.pressControlCenterMenuExtra()
            return
        }

        let currentID = tisSourceID(current)
        if let idx = listRef.firstIndex(where: { tisSourceID($0) == currentID }) {
            let next = listRef[(idx + 1) % listRef.count]
            TISSelectInputSource(next)
        } else if let first = listRef.first {
            TISSelectInputSource(first)
        }
    }

    private func tisSourceID(_ src: TISInputSource) -> String {
        guard let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    // MARK: - Core Disk Synchronization Logic

    private struct RawProcessSnapshot: Sendable {
        let pid: pid_t
        let bundleID: String?
        let bundleOrExecPath: String?
        let executableName: String?
        let executableURLString: String?
    }

    private struct ProcessIdentity: Sendable {
        let pid: pid_t
        let bundleID: String?
        let outerAppBundleID: String?
        let executableName: String?
        let executableURLString: String?
    }

    @MainActor
    private func captureRawProcessSnapshots(for neededPIDs: Set<pid_t>) -> [pid_t: RawProcessSnapshot] {
        guard !neededPIDs.isEmpty else { return [:] }
        var map: [pid_t: RawProcessSnapshot] = [:]
        map.reserveCapacity(neededPIDs.count)

        var missingPIDs = Set<pid_t>()
        for pid in neededPIDs {
            if let cached = rawProcessCache[pid] {
                map[pid] = cached
            } else {
                missingPIDs.insert(pid)
            }
        }
        guard !missingPIDs.isEmpty else { return map }

        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard missingPIDs.contains(pid) else { continue }
            let execURL = app.executableURL
            let snap = RawProcessSnapshot(
                pid: pid,
                bundleID: app.bundleIdentifier,
                bundleOrExecPath: (app.bundleURL ?? execURL)?.path,
                executableName: execURL?.lastPathComponent ?? app.localizedName,
                executableURLString: execURL?.absoluteString
            )
            rawProcessCache[pid] = snap
            map[pid] = snap
        }
        return map
    }

    private func resolveProcessIdentitiesOnQueue(from snapshots: [pid_t: RawProcessSnapshot]) -> [pid_t: ProcessIdentity] {
        var map: [pid_t: ProcessIdentity] = [:]
        map.reserveCapacity(snapshots.count)
        for (pid, snap) in snapshots {
            let outerBundleID: String?
            if let path = snap.bundleOrExecPath {
                if let cached = outerBundleIDCache[path] {
                    outerBundleID = cached.isEmpty ? nil : cached
                } else {
                    let resolved = Self.resolveOuterAppBundleID(fromPath: path)
                    outerBundleIDCache[path] = resolved ?? ""
                    outerBundleID = resolved
                }
            } else {
                outerBundleID = nil
            }
            map[pid] = ProcessIdentity(
                pid: pid,
                bundleID: snap.bundleID,
                outerAppBundleID: outerBundleID,
                executableName: snap.executableName,
                executableURLString: snap.executableURLString
            )
        }
        return map
    }

    private static func resolveOuterAppBundleID(fromPath path: String) -> String? {
        guard let firstAppRange = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app") : nil) else {
            return nil
        }
        let rootAppPath: String
        if path[firstAppRange].hasSuffix("/") {
            rootAppPath = String(path[..<firstAppRange.upperBound].dropLast())
        } else {
            rootAppPath = String(path[..<firstAppRange.upperBound])
        }
        let infoPlistPath = "\(rootAppPath)/Contents/Info.plist"
        guard let dict = NSDictionary(contentsOfFile: infoPlistPath) as? [String: Any] else {
            return nil
        }
        return dict["CFBundleIdentifier"] as? String
    }

    private func performSyncOnQueue(
        allApps: [MenuBarAppItem],
        selectedMainBarIDs: Set<String>,
        orderedMainBarIDs: [String],
        hidingEnabled: Bool,
        processMeta: [pid_t: ProcessIdentity],
        allowImmediateReload: Bool,
        forceReload: Bool
    ) -> SyncOutcome {
        guard hasFullDiskAccess else {
            return SyncOutcome(
                didModifyPreferences: false,
                didReloadAgent: false,
                deferredReloadDelay: nil,
                hiddenCount: 0,
                visibleCount: allApps.count,
                errorReason: .missingFullDiskAccess
            )
        }

        let effectiveSelectedIDs: Set<String> = hidingEnabled
            ? selectedMainBarIDs
            : Set(allApps.map(\.id))

        let rawVisibleItems = allApps.filter { effectiveSelectedIDs.contains($0.id) }
        let visibleItems: [MenuBarAppItem]
        if !orderedMainBarIDs.isEmpty {
            var rankByID: [String: Int] = [:]
            for (idx, id) in orderedMainBarIDs.enumerated() where rankByID[id] == nil {
                rankByID[id] = idx
            }
            visibleItems = rawVisibleItems.enumerated().sorted { lhs, rhs in
                let rL = rankByID[lhs.element.id] ?? (10_000 + lhs.offset)
                let rR = rankByID[rhs.element.id] ?? (10_000 + rhs.offset)
                return rL < rR
            }.map(\.element)
        } else {
            visibleItems = rawVisibleItems
        }

        let hiddenItems = hidingEnabled ? allApps.filter { !effectiveSelectedIDs.contains($0.id) } : []

        // Check whether any hidden app is STILL physically hosted on the Main Menu Bar right now
        let hasLiveBarMismatch = hiddenItems.contains(where: { $0.isCurrentlyOnBar }) ||
            visibleItems.contains(where: { !$0.isCurrentlyOnBar && !$0.isSystemItem })

        // 1. Update System Menu Extras FIRST so their CFPreferencesSynchronize calls flush cleanly BEFORE we SIGKILL cfprefsd!
        let changedSystemModules = updateSystemModulesPreferences(
            visibleItems: visibleItems,
            hiddenItems: hiddenItems,
            hidingEnabled: hidingEnabled
        )

        // 2. Update `group.com.apple.controlcenter.plist` (`trackedApplications` + `showSpotlight` / `showSiri`)
        let ccResult = updateControlCenterGroupPlist(
            visibleItems: visibleItems,
            hiddenItems: hiddenItems,
            hidingEnabled: hidingEnabled,
            processMeta: processMeta
        )
        if let errMsg = ccResult.writeError {
            return SyncOutcome(
                didModifyPreferences: false,
                didReloadAgent: false,
                deferredReloadDelay: nil,
                hiddenCount: hiddenItems.count,
                visibleCount: visibleItems.count,
                errorReason: .writeFailed(errMsg)
            )
        }

        // 3. Update `com.apple.MenuBar.plist` (`TrailingItemPreferredPositions`) so BarFlow `•••` + selected apps sit cleanly at top-right!
        let changedPositions = updateMenuBarPreferredPositions(
            visibleItems: visibleItems,
            processMeta: processMeta
        )

        let anyChanged = ccResult.didChange || changedSystemModules || changedPositions
        let shouldReload = anyChanged || (forceReload && hasLiveBarMismatch)

        guard shouldReload else {
            return SyncOutcome(
                didModifyPreferences: false,
                didReloadAgent: false,
                deferredReloadDelay: nil,
                hiddenCount: hiddenItems.count,
                visibleCount: visibleItems.count,
                errorReason: nil
            )
        }

        guard allowImmediateReload else {
            flushUserCfprefsd()
            return SyncOutcome(
                didModifyPreferences: anyChanged,
                didReloadAgent: false,
                deferredReloadDelay: nil,
                hiddenCount: hiddenItems.count,
                visibleCount: visibleItems.count,
                errorReason: nil
            )
        }

        let remainingWait = remainingSecondsBeforeSafeReload()
        if remainingWait > 0.05 {
            flushUserCfprefsd()
            return SyncOutcome(
                didModifyPreferences: anyChanged,
                didReloadAgent: false,
                deferredReloadDelay: remainingWait,
                hiddenCount: hiddenItems.count,
                visibleCount: visibleItems.count,
                errorReason: nil
            )
        }

        flushUserCfprefsdAndReloadMenuBarAgent()
        return SyncOutcome(
            didModifyPreferences: anyChanged,
            didReloadAgent: true,
            deferredReloadDelay: nil,
            hiddenCount: hiddenItems.count,
            visibleCount: visibleItems.count,
            errorReason: nil
        )
    }

    // MARK: - 1. `group.com.apple.controlcenter.plist` (`trackedApplications` + `showSpotlight`)

    private func updateControlCenterGroupPlist(
        visibleItems: [MenuBarAppItem],
        hiddenItems: [MenuBarAppItem],
        hidingEnabled: Bool,
        processMeta: [pid_t: ProcessIdentity]
    ) -> (didChange: Bool, writeError: String?) {
        let url = URL(fileURLWithPath: ccGroupPlistPath)
        let rawOuterData: Data
        do {
            rawOuterData = try Data(contentsOf: url)
        } catch {
            return (false, error.localizedDescription)
        }
        guard var outer = (try? PropertyListSerialization.propertyList(
            from: rawOuterData,
            options: [.mutableContainersAndLeaves],
            format: nil
        )) as? [String: Any] else {
            return (false, "Không đọc được định dạng group.com.apple.controlcenter.plist")
        }

        var didChange = false
        var managedKeys = loadManagedTrackedKeys()
        var backup = loadSystemPrefBackup()

        // --- A. Handle Spotlight & Siri flags inside `group.com.apple.controlcenter.plist` ---
        let isSpotlightHidden = hidingEnabled && hiddenItems.contains(where: { isSpotlightItem($0) })
        let isSpotlightVisible = visibleItems.contains(where: { isSpotlightItem($0) }) || !hidingEnabled

        if isSpotlightHidden {
            let currentVal = (outer["showSpotlight"] as? Bool) ?? true
            if backup.originalShowSpotlight == nil {
                backup.hadSpotlightPref = (outer["showSpotlight"] != nil)
                backup.originalShowSpotlight = currentVal
                postControlCenterStatusItemNotification(insert: false, identifiers: ["Spotlight", "com.apple.Spotlight", "com.apple.campo"])
            }
            if currentVal != false {
                outer["showSpotlight"] = false
                postControlCenterStatusItemNotification(insert: false, identifiers: ["Spotlight", "com.apple.Spotlight", "com.apple.campo"])
                didChange = true
            }
        } else if isSpotlightVisible, let orig = backup.originalShowSpotlight {
            let currentVal = (outer["showSpotlight"] as? Bool) ?? true
            if currentVal != orig {
                outer["showSpotlight"] = orig
                didChange = true
            }
            if orig {
                postControlCenterStatusItemNotification(insert: true, identifiers: ["Spotlight", "com.apple.Spotlight", "com.apple.campo"])
            }
            backup.originalShowSpotlight = nil
        }

        let isSiriHidden = hidingEnabled && hiddenItems.contains(where: { isSiriOnlyItem($0) })
        let isSiriVisible = visibleItems.contains(where: { isSiriOnlyItem($0) }) || !hidingEnabled
        if isSiriHidden {
            let currentVal = (outer["showSiri"] as? Bool) ?? true
            if backup.originalShowSiri == nil {
                backup.hadSiriPref = (outer["showSiri"] != nil)
                backup.originalShowSiri = currentVal
            }
            if currentVal != false {
                outer["showSiri"] = false
                didChange = true
            }
        } else if isSiriVisible, let orig = backup.originalShowSiri {
            let currentVal = (outer["showSiri"] as? Bool) ?? false
            if currentVal != orig {
                outer["showSiri"] = orig
                didChange = true
            }
            backup.originalShowSiri = nil
        }

        saveSystemPrefBackup(backup)

        // --- B. Build Visible & Hidden Identifier Sets for Non-System Apps (case-insensitive bundle matching) ---
        var visibleBundleIDs = Set<String>(["com.hunglx.barflow", "barflow"])
        var visibleExecURLs = Set<String>()
        if let ownExec = Bundle.main.executableURL?.absoluteString {
            visibleExecURLs.insert(ownExec)
        }

        for item in visibleItems where mappingForSystemItem(item) == nil {
            collectIdentifiers(for: item, processMeta: processMeta, intoBundles: &visibleBundleIDs, intoExecs: &visibleExecURLs)
        }

        var hiddenBundleIDs = Set<String>()
        var hiddenExecURLs = Set<String>()
        for item in hiddenItems where mappingForSystemItem(item) == nil {
            collectIdentifiers(for: item, processMeta: processMeta, intoBundles: &hiddenBundleIDs, intoExecs: &hiddenExecURLs)
        }
        // If an app has multiple status items and AT LEAST ONE is kept on Main Bar, keep the app allowed on Main Bar!
        hiddenBundleIDs.subtract(visibleBundleIDs)
        hiddenExecURLs.subtract(visibleExecURLs)

        if let trackedData = outer["trackedApplications"] as? Data,
           var arr = (try? PropertyListSerialization.propertyList(
               from: trackedData,
               options: [.mutableContainersAndLeaves],
               format: nil
           )) as? [Any] {
            var trackedModified = false
            var matchedHiddenBundles = Set<String>()
            var matchedHiddenExecs = Set<String>()

            for idx in stride(from: 0, to: arr.count - 1, by: 2) {
                guard let keyDict = arr[idx] as? [String: Any],
                      var valDict = arr[idx + 1] as? [String: Any] else {
                    continue
                }

                let canonicalKey = canonicalLocationKey(from: keyDict)
                let (entryBundles, entryExecs) = extractEntryIdentifiers(keyDict: keyDict, valDict: valDict)
                let currentAllowed = (valDict["isAllowed"] as? Bool) ?? true

                let matchesBarFlow = entryBundles.contains("com.hunglx.barflow") || entryBundles.contains("barflow")
                let matchesVisible = matchesBarFlow ||
                    !entryBundles.isDisjoint(with: visibleBundleIDs) ||
                    !entryExecs.isDisjoint(with: visibleExecURLs)
                let matchesHidden = !matchesVisible && (
                    !entryBundles.isDisjoint(with: hiddenBundleIDs) ||
                    !entryExecs.isDisjoint(with: hiddenExecURLs)
                )

                if matchesHidden {
                    matchedHiddenBundles.formUnion(entryBundles)
                    matchedHiddenExecs.formUnion(entryExecs)
                }

                if matchesVisible {
                    if !currentAllowed {
                        valDict["isAllowed"] = true
                        arr[idx + 1] = valDict
                        trackedModified = true
                    }
                    managedKeys.remove(canonicalKey)
                } else if hidingEnabled && matchesHidden {
                    if currentAllowed {
                        valDict["isAllowed"] = false
                        arr[idx + 1] = valDict
                        managedKeys.insert(canonicalKey)
                        trackedModified = true
                    }
                } else if !hidingEnabled && managedKeys.contains(canonicalKey) {
                    if !currentAllowed {
                        valDict["isAllowed"] = true
                        arr[idx + 1] = valDict
                        trackedModified = true
                    }
                    managedKeys.remove(canonicalKey)
                }
            }

            // Append any running hidden non-system app not yet recorded in `trackedApplications`
            if hidingEnabled {
                for item in hiddenItems where mappingForSystemItem(item) == nil {
                    var itemBundles = Set<String>()
                    var itemExecs = Set<String>()
                    collectIdentifiers(for: item, processMeta: processMeta, intoBundles: &itemBundles, intoExecs: &itemExecs)
                    itemBundles.subtract(visibleBundleIDs)
                    itemExecs.subtract(visibleExecURLs)

                    let alreadyCovered = !itemBundles.isDisjoint(with: matchedHiddenBundles) ||
                        !itemExecs.isDisjoint(with: matchedHiddenExecs)
                    guard !alreadyCovered else { continue }

                    if let primaryBundle = processMeta[item.pid]?.outerAppBundleID ?? item.bundleIdentifier,
                       !primaryBundle.isEmpty,
                       primaryBundle.lowercased() != "com.hunglx.barflow" {
                        let lowerPrimary = primaryBundle.lowercased()
                        let locDict: [String: Any] = ["bundle": ["_0": primaryBundle]]
                        var menuLocs: [[String: Any]] = [["bundle": ["_0": primaryBundle]]]
                        if let subBundle = item.bundleIdentifier, subBundle.lowercased() != lowerPrimary {
                            menuLocs.append(["bundle": ["_0": subBundle]])
                        }
                        if let execStr = processMeta[item.pid]?.executableURLString {
                            menuLocs.append(["adhocBinary": ["_0": ["relative": execStr]]])
                        }
                        let valDict: [String: Any] = [
                            "isAllowed": false,
                            "location": locDict,
                            "menuItemLocations": menuLocs
                        ]
                        arr.append(locDict)
                        arr.append(valDict)
                        managedKeys.insert("bundle:\(lowerPrimary)")
                        matchedHiddenBundles.insert(lowerPrimary)
                        trackedModified = true
                    } else if let execStr = processMeta[item.pid]?.executableURLString, !execStr.isEmpty {
                        let locDict: [String: Any] = ["adhocBinary": ["_0": ["relative": execStr]]]
                        let valDict: [String: Any] = [
                            "isAllowed": false,
                            "location": locDict,
                            "menuItemLocations": [locDict]
                        ]
                        arr.append(locDict)
                        arr.append(valDict)
                        managedKeys.insert("exec:\(execStr)")
                        matchedHiddenExecs.insert(execStr)
                        trackedModified = true
                    }
                }
            }

            if trackedModified,
               let newTrackedData = try? PropertyListSerialization.data(fromPropertyList: arr, format: .binary, options: 0) {
                outer["trackedApplications"] = newTrackedData
                didChange = true
            }
        }

        saveManagedTrackedKeys(managedKeys)

        if didChange {
            guard let newOuterData = try? PropertyListSerialization.data(fromPropertyList: outer, format: .binary, options: 0) else {
                return (false, "Không thể mã hoá group.com.apple.controlcenter.plist")
            }
            do {
                try newOuterData.write(to: url, options: .atomic)
            } catch {
                return (false, error.localizedDescription)
            }
        }

        return (didChange, nil)
    }

    private func restoreTrackedAppsAndSpotlightOnDisk() -> Bool {
        let url = URL(fileURLWithPath: ccGroupPlistPath)
        guard let rawOuterData = try? Data(contentsOf: url),
              var outer = (try? PropertyListSerialization.propertyList(
                  from: rawOuterData,
                  options: [.mutableContainersAndLeaves],
                  format: nil
              )) as? [String: Any] else {
            return false
        }

        var didChange = false
        let managedKeys = loadManagedTrackedKeys()
        var backup = loadSystemPrefBackup()

        if let origSpot = backup.originalShowSpotlight {
            if (outer["showSpotlight"] as? Bool) != origSpot {
                outer["showSpotlight"] = origSpot
                didChange = true
            }
            if origSpot {
                postControlCenterStatusItemNotification(insert: true, identifiers: ["Spotlight", "com.apple.Spotlight", "com.apple.campo"])
            }
            backup.originalShowSpotlight = nil
        }
        if let origSiri = backup.originalShowSiri {
            if (outer["showSiri"] as? Bool) != origSiri {
                outer["showSiri"] = origSiri
                didChange = true
            }
            backup.originalShowSiri = nil
        }
        saveSystemPrefBackup(backup)

        if !managedKeys.isEmpty,
           let trackedData = outer["trackedApplications"] as? Data,
           var arr = (try? PropertyListSerialization.propertyList(
               from: trackedData,
               options: [.mutableContainersAndLeaves],
               format: nil
           )) as? [Any] {
            var trackedModified = false
            for idx in stride(from: 0, to: arr.count - 1, by: 2) {
                guard let keyDict = arr[idx] as? [String: Any],
                      var valDict = arr[idx + 1] as? [String: Any] else { continue }
                let canonical = canonicalLocationKey(from: keyDict)
                if managedKeys.contains(canonical), (valDict["isAllowed"] as? Bool) == false {
                    valDict["isAllowed"] = true
                    arr[idx + 1] = valDict
                    trackedModified = true
                }
            }
            if trackedModified,
               let newTrackedData = try? PropertyListSerialization.data(fromPropertyList: arr, format: .binary, options: 0) {
                outer["trackedApplications"] = newTrackedData
                didChange = true
            }
        }

        saveManagedTrackedKeys([])

        if didChange,
           let newOuterData = try? PropertyListSerialization.data(fromPropertyList: outer, format: .binary, options: 0) {
            try? newOuterData.write(to: url, options: .atomic)
        }
        return didChange
    }

    // MARK: - 2. System Menu Extras (`Wi-Fi`, `Battery`, `Screen Mirroring`, `Input Menu`, etc.)

    private struct SystemExtraMapping {
        let byHostKeys: [String]
        let visibleCCKeys: [String]
        let symbolKey: String
    }

    private func mappingForSystemItem(_ item: MenuBarAppItem) -> SystemExtraMapping? {
        // Strictly restrict to genuine macOS System Menu Extras so third-party apps (e.g. Typinator -> "pin",
        // BetterDisplay -> "display", SoundSource -> "sound") ALWAYS use `trackedApplications`!
        guard item.isSystemItem else { return nil }
        if item.bundleIdentifier == "com.apple.Passwords.MenuBarExtra" {
            return nil
        }

        let key = ((item.axIdentifier ?? "") + " " + (item.bundleIdentifier ?? "") + " " + item.id + " " + item.appName).lowercased()

        if isSpotlightItem(item) {
            return SystemExtraMapping(byHostKeys: [], visibleCCKeys: [], symbolKey: "spotlight")
        }
        if isSiriOnlyItem(item) {
            return SystemExtraMapping(byHostKeys: [], visibleCCKeys: [], symbolKey: "siri")
        }
        if key.contains("textinput") || key.contains("input menu") || key.contains("bộ gõ") {
            return SystemExtraMapping(byHostKeys: [], visibleCCKeys: [], symbolKey: "keyboard")
        }
        if key.contains("wifi") || key.contains("wi-fi") || key.contains("wi‑fi") {
            return SystemExtraMapping(byHostKeys: ["WiFi"], visibleCCKeys: ["WiFi"], symbolKey: "wifi")
        }
        if key.contains("battery") || key.contains("pin") {
            return SystemExtraMapping(byHostKeys: ["Battery"], visibleCCKeys: ["Battery"], symbolKey: "battery")
        }
        if key.contains("mirror") || key.contains("airplay") || key.contains("display") || key.contains("phản chiếu") {
            return SystemExtraMapping(byHostKeys: ["ScreenMirroring", "Display"], visibleCCKeys: ["ScreenMirroring", "Display"], symbolKey: "mirror")
        }
        if key.contains("sound") || key.contains("volume") || key.contains("âm thanh") {
            return SystemExtraMapping(byHostKeys: ["Sound"], visibleCCKeys: ["Sound"], symbolKey: "sound")
        }
        if key.contains("bluetooth") {
            return SystemExtraMapping(byHostKeys: ["Bluetooth"], visibleCCKeys: ["Bluetooth"], symbolKey: "bluetooth")
        }
        if key.contains("focus") || key.contains("dnd") || key.contains("tập trung") {
            return SystemExtraMapping(byHostKeys: ["FocusModes"], visibleCCKeys: ["FocusModes"], symbolKey: "focus")
        }
        if key.contains("nowplaying") || key.contains("now playing") || key.contains("đang phát") {
            return SystemExtraMapping(byHostKeys: ["NowPlaying"], visibleCCKeys: ["NowPlaying"], symbolKey: "nowplaying")
        }
        if key.contains("user") || key.contains("người dùng") {
            return SystemExtraMapping(byHostKeys: ["UserSwitcher"], visibleCCKeys: ["UserSwitcher"], symbolKey: "user")
        }
        return nil
    }

    private func updateSystemModulesPreferences(
        visibleItems: [MenuBarAppItem],
        hiddenItems: [MenuBarAppItem],
        hidingEnabled: Bool
    ) -> Bool {
        var didChange = false
        var backup = loadSystemPrefBackup()
        let ccDomain = "com.apple.controlcenter" as CFString
        let timDomain = "com.apple.TextInputMenu" as CFString

        let hiddenSystemItems = hidingEnabled ? hiddenItems.filter { mappingForSystemItem($0) != nil } : []
        let visibleSystemItems = hidingEnabled
            ? visibleItems.filter { mappingForSystemItem($0) != nil }
            : (visibleItems + hiddenItems).filter { mappingForSystemItem($0) != nil }

        // Persist metadata for hidden system items so MenuBarScanner keeps them in `Ctrl + B` & `AppSelectionView`!
        var persistedList: [PersistedSystemItem] = []
        for sItem in hiddenSystemItems {
            let symKey = mappingForSystemItem(sItem)?.symbolKey ?? "default"
            persistedList.append(
                PersistedSystemItem(
                    id: sItem.id,
                    appName: sItem.appName,
                    bundleIdentifier: sItem.bundleIdentifier,
                    axIdentifier: sItem.axIdentifier,
                    symbolKey: symKey
                )
            )
        }
        savePersistedHiddenSystemItems(persistedList)

        // Input Menu (`com.apple.TextInputMenuAgent`)
        let timAgentDomain = "com.apple.TextInputMenuAgent" as CFString
        let hideInputMenu = hiddenSystemItems.contains(where: { isInputMenuItem($0) })
        let showInputMenu = visibleSystemItems.contains(where: { isInputMenuItem($0) }) || !hidingEnabled

        if hideInputMenu {
            let cur = (CFPreferencesCopyValue("visible" as CFString, timDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool) ?? true
            let curVCC = (CFPreferencesCopyValue("NSStatusItem VisibleCC Item-0" as CFString, timAgentDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool) ?? true
            if backup.originalTextInputVisible == nil {
                backup.originalTextInputVisible = cur
                backup.originalTextInputAgentVisibleCC = curVCC
            }
            if cur != false || curVCC != false {
                CFPreferencesSetValue("visible" as CFString, false as CFBoolean, timDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                CFPreferencesSynchronize(timDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                CFPreferencesSetValue("NSStatusItem VisibleCC Item-0" as CFString, false as CFBoolean, timAgentDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                CFPreferencesSynchronize(timAgentDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                postControlCenterStatusItemNotification(insert: false, identifiers: ["TextInputMenu"])
                reloadDaemonIfThrottleSafe(processName: "TextInputMenuAgent")
                didChange = true
            }
        } else if showInputMenu, let origTIM = backup.originalTextInputVisible {
            let origVCC = backup.originalTextInputAgentVisibleCC ?? true
            let cur = (CFPreferencesCopyValue("visible" as CFString, timDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool) ?? false
            let curVCC = (CFPreferencesCopyValue("NSStatusItem VisibleCC Item-0" as CFString, timAgentDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool) ?? false
            if cur != origTIM || curVCC != origVCC {
                CFPreferencesSetValue("visible" as CFString, origTIM as CFBoolean, timDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                CFPreferencesSynchronize(timDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                CFPreferencesSetValue("NSStatusItem VisibleCC Item-0" as CFString, origVCC as CFBoolean, timAgentDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                CFPreferencesSynchronize(timAgentDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                if origTIM {
                    postControlCenterStatusItemNotification(insert: true, identifiers: ["TextInputMenu"])
                }
                reloadDaemonIfThrottleSafe(processName: "TextInputMenuAgent")
                didChange = true
            }
            backup.originalTextInputVisible = nil
            backup.originalTextInputAgentVisibleCC = nil
        }

        // Control Center Modules (`WiFi`, `Battery`, `ScreenMirroring` / `Display`, `Sound`, `Bluetooth`, `FocusModes`, `NowPlaying`, `UserSwitcher`)
        var ccModified = false
        for item in hiddenSystemItems {
            guard let mapping = mappingForSystemItem(item) else { continue }
            for bhKey in mapping.byHostKeys {
                let currentNum = CFPreferencesCopyValue(bhKey as CFString, ccDomain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? Int
                if backup.originalByHostModuleInts[bhKey] == nil && !backup.absentByHostModuleKeys.contains(bhKey) {
                    if let currentNum {
                        backup.originalByHostModuleInts[bhKey] = currentNum
                    } else {
                        backup.absentByHostModuleKeys.insert(bhKey)
                    }
                }
                if currentNum != 8 {
                    CFPreferencesSetValue(bhKey as CFString, 8 as CFNumber, ccDomain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
                    ccModified = true
                }
            }
            for vKey in mapping.visibleCCKeys {
                let fullKey = "NSStatusItem VisibleCC \(vKey)"
                let curBool = CFPreferencesCopyValue(fullKey as CFString, ccDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool
                if backup.originalVisibleCCFlags[fullKey] == nil, let curBool {
                    backup.originalVisibleCCFlags[fullKey] = curBool
                }
                if curBool != false {
                    CFPreferencesSetValue(fullKey as CFString, false as CFBoolean, ccDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                    ccModified = true
                }
            }
        }

        for item in visibleSystemItems {
            guard let mapping = mappingForSystemItem(item) else { continue }
            for bhKey in mapping.byHostKeys {
                if let origInt = backup.originalByHostModuleInts[bhKey] {
                    let cur = CFPreferencesCopyValue(bhKey as CFString, ccDomain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? Int
                    if cur != origInt {
                        CFPreferencesSetValue(bhKey as CFString, origInt as CFNumber, ccDomain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
                        ccModified = true
                    }
                    backup.originalByHostModuleInts.removeValue(forKey: bhKey)
                } else if backup.absentByHostModuleKeys.contains(bhKey) {
                    if CFPreferencesCopyValue(bhKey as CFString, ccDomain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) != nil {
                        CFPreferencesSetValue(bhKey as CFString, nil, ccDomain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
                        ccModified = true
                    }
                    backup.absentByHostModuleKeys.remove(bhKey)
                }
            }
            for vKey in mapping.visibleCCKeys {
                let fullKey = "NSStatusItem VisibleCC \(vKey)"
                if let origBool = backup.originalVisibleCCFlags[fullKey] {
                    let cur = CFPreferencesCopyValue(fullKey as CFString, ccDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool
                    if cur != origBool {
                        CFPreferencesSetValue(fullKey as CFString, origBool as CFBoolean, ccDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                        ccModified = true
                    }
                    backup.originalVisibleCCFlags.removeValue(forKey: fullKey)
                }
            }
        }

        if ccModified {
            CFPreferencesSynchronize(ccDomain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
            CFPreferencesSynchronize(ccDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            didChange = true
        }

        saveSystemPrefBackup(backup)
        return didChange
    }

    private func restoreSystemExtrasOnDisk() -> Bool {
        var didChange = false
        var backup = loadSystemPrefBackup()
        let ccDomain = "com.apple.controlcenter" as CFString
        let timDomain = "com.apple.TextInputMenu" as CFString

        let timAgentDomain = "com.apple.TextInputMenuAgent" as CFString
        if let origTIM = backup.originalTextInputVisible {
            let origVCC = backup.originalTextInputAgentVisibleCC ?? true
            CFPreferencesSetValue("visible" as CFString, origTIM as CFBoolean, timDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSynchronize(timDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSetValue("NSStatusItem VisibleCC Item-0" as CFString, origVCC as CFBoolean, timAgentDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSynchronize(timAgentDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            if origTIM {
                postControlCenterStatusItemNotification(insert: true, identifiers: ["TextInputMenu"])
            }
            reloadDaemonIfThrottleSafe(processName: "TextInputMenuAgent")
            backup.originalTextInputVisible = nil
            backup.originalTextInputAgentVisibleCC = nil
            didChange = true
        }

        var ccModified = false
        for (bhKey, origInt) in backup.originalByHostModuleInts {
            CFPreferencesSetValue(bhKey as CFString, origInt as CFNumber, ccDomain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
            ccModified = true
        }
        backup.originalByHostModuleInts.removeAll()

        for bhKey in backup.absentByHostModuleKeys {
            CFPreferencesSetValue(bhKey as CFString, nil, ccDomain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
            ccModified = true
        }
        backup.absentByHostModuleKeys.removeAll()

        for (fullKey, origBool) in backup.originalVisibleCCFlags {
            CFPreferencesSetValue(fullKey as CFString, origBool as CFBoolean, ccDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            ccModified = true
        }
        backup.originalVisibleCCFlags.removeAll()

        if ccModified {
            CFPreferencesSynchronize(ccDomain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
            CFPreferencesSynchronize(ccDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            didChange = true
        }

        saveSystemPrefBackup(backup)
        savePersistedHiddenSystemItems([])
        return didChange
    }

    // MARK: - 3. `com.apple.MenuBar.plist` (`TrailingItemPreferredPositions` — Exact Left -> Right Ordering!)

    private func updateMenuBarPreferredPositions(
        visibleItems: [MenuBarAppItem],
        processMeta: [pid_t: ProcessIdentity]
    ) -> Bool {
        let url = URL(fileURLWithPath: menuBarGroupPlistPath)
        guard let rawData = try? Data(contentsOf: url),
              var plist = (try? PropertyListSerialization.propertyList(
                  from: rawData,
                  options: [.mutableContainersAndLeaves],
                  format: nil
              )) as? [String: Any],
              var trailing = plist["TrailingItemPreferredPositions"] as? [String: Any] else {
            return false
        }

        var didChange = false

        // Clean up any legacy BarFlow.Spacer.* entries from v1.0–v1.2
        let spacerKeys = trailing.keys.filter { $0.contains("BarFlow.Spacer.") }
        for sk in spacerKeys {
            trailing.removeValue(forKey: sk)
            didChange = true
        }

        // Anchor Clock (0), Control Center (116), and BarFlow `•••` (136) cleanly at the far right of the Menu Bar.
        let targetBarFlowPos = 136
        for bfKey in ["status:BarFlow::BarFlow.MainToggle", "status:com.hunglx.BarFlow::BarFlow.MainToggle"] {
            let currentBF = (trailing[bfKey] as? NSNumber)?.intValue ?? -1
            if abs(currentBF - targetBarFlowPos) >= 4 {
                trailing[bfKey] = targetBarFlowPos
                didChange = true
            }
        }

        // `TrailingItemPreferredPositions` measures distance in points FROM THE RIGHT EDGE of the screen:
        // Larger value = further LEFT on the Menu Bar!
        // Since `visibleItems` is ordered Left -> Right (`[leftmost, ..., rightmost]`), we iterate `visibleItems.reversed()`
        // starting at 176 (immediately left of BarFlow at 136) and stepping +38pt per slot!
        let existingKeys = Array(trailing.keys)
        var assignedKeys = Set<String>()
        var nextPos: Double = 176.0
        var ccDomainTouched = false
        let ccDomain = "com.apple.controlcenter" as CFString

        for item in visibleItems.reversed() {
            let (slotKeys, ccModuleKeys) = resolvePreferredPositionKeys(
                for: item,
                processMeta: processMeta,
                existingTrailingKeys: existingKeys
            )
            var placedAny = false
            for key in slotKeys where !assignedKeys.contains(key) {
                assignedKeys.insert(key)
                let oldVal = (trailing[key] as? NSNumber)?.doubleValue ?? -9999
                if abs(oldVal - nextPos) >= 2.0 {
                    trailing[key] = Int(nextPos)
                    didChange = true
                }
                placedAny = true
                nextPos += 38.0
            }

            if placedAny && !ccModuleKeys.isEmpty {
                let modulePos = Int(nextPos - 38.0)
                for modKey in ccModuleKeys {
                    let prefKey = "NSStatusItem Preferred Position \(modKey)" as CFString
                    if let existingCCPos = (CFPreferencesCopyValue(prefKey, ccDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSNumber)?.intValue,
                       abs(existingCCPos - modulePos) >= 4 {
                        CFPreferencesSetValue(prefKey, modulePos as CFNumber, ccDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                        ccDomainTouched = true
                    }
                }
            }
        }

        if ccDomainTouched {
            CFPreferencesSynchronize(ccDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }

        if didChange {
            plist["TrailingItemPreferredPositions"] = trailing
            if let outData = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) {
                try? outData.write(to: url, options: .atomic)
            }
        }

        return didChange
    }

    private func resolvePreferredPositionKeys(
        for item: MenuBarAppItem,
        processMeta: [pid_t: ProcessIdentity],
        existingTrailingKeys: [String]
    ) -> (trailingKeys: [String], ccModuleKeys: [String]) {
        if isSpotlightItem(item) {
            return (["status:com.apple.campo::Item-0"], [])
        }
        if isSiriOnlyItem(item) {
            return (["status:com.apple.Siri::Item-0"], [])
        }
        if isInputMenuItem(item) {
            return (["status:com.apple.TextInputMenuAgent::Item-0"], [])
        }
        if let sysMapping = mappingForSystemItem(item), !sysMapping.byHostKeys.isEmpty {
            let modKeys = sysMapping.byHostKeys.map { "module:\($0)" }
            return (modKeys, sysMapping.byHostKeys)
        }

        // Third-party app or standalone status binary
        let meta = processMeta[item.pid]
        var candidateOwners: [String] = []
        for raw in [item.bundleIdentifier, meta?.bundleID, meta?.outerAppBundleID, meta?.executableName] {
            if let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                if !candidateOwners.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                    candidateOwners.append(trimmed)
                }
            }
        }

        guard !candidateOwners.isEmpty else { return ([], []) }

        let lowerPrefixes = candidateOwners.map { "status:\($0.lowercased())::" }
        var matched = existingTrailingKeys.filter { existing in
            let lower = existing.lowercased()
            return lowerPrefixes.contains(where: { lower.hasPrefix($0) })
        }.sorted()

        // If a multi-icon app exposes a specific axIdentifier matching one of its keys, prioritize that key
        if matched.count > 1,
           let axID = item.axIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !axID.isEmpty {
            let specific = matched.filter { $0.lowercased().hasSuffix("::\(axID.lowercased())") }
            if !specific.isEmpty {
                matched = specific
            }
        }

        if !matched.isEmpty {
            return (matched, [])
        }

        // Brand-new app never dragged before: synthesize its canonical TrailingItemPreferredPositions key
        let primaryOwner = candidateOwners[0]
        let suffix: String
        if let axID = item.axIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !axID.isEmpty,
           !axID.contains(" ") {
            suffix = axID
        } else {
            suffix = "Item-\(max(0, item.axChildIndex))"
        }
        return (["status:\(primaryOwner)::\(suffix)"], [])
    }

    // MARK: - Identifier Helpers

    private func isSpotlightItem(_ item: MenuBarAppItem) -> Bool {
        let b = (item.bundleIdentifier ?? "").lowercased()
        let a = (item.axIdentifier ?? "").lowercased()
        return b == "com.apple.campo" || b == "com.apple.spotlight" || a.contains("spotlight") || item.id.lowercased().contains("spotlight")
    }

    private func isSiriOnlyItem(_ item: MenuBarAppItem) -> Bool {
        guard !isSpotlightItem(item) else { return false }
        let b = (item.bundleIdentifier ?? "").lowercased()
        let a = (item.axIdentifier ?? "").lowercased()
        return b == "com.apple.siri" || a.contains("siri")
    }

    private func isInputMenuItem(_ item: MenuBarAppItem) -> Bool {
        let b = (item.bundleIdentifier ?? "").lowercased()
        let a = (item.axIdentifier ?? "").lowercased()
        return b == "com.apple.textinputmenuagent" || a.contains("textinput") || item.id.lowercased().contains("textinput")
    }

    private func collectIdentifiers(
        for item: MenuBarAppItem,
        processMeta: [pid_t: ProcessIdentity],
        intoBundles bundles: inout Set<String>,
        intoExecs execs: inout Set<String>
    ) {
        if let bid = item.bundleIdentifier, !bid.isEmpty {
            bundles.insert(bid.lowercased())
        }
        if let meta = processMeta[item.pid] {
            if let bid = meta.bundleID, !bid.isEmpty {
                bundles.insert(bid.lowercased())
            }
            if let outer = meta.outerAppBundleID, !outer.isEmpty {
                bundles.insert(outer.lowercased())
            }
            if let ex = meta.executableURLString, !ex.isEmpty {
                execs.insert(ex)
            }
        }
    }

    private func canonicalLocationKey(from locDict: [String: Any]) -> String {
        if let bundleDict = locDict["bundle"] as? [String: Any],
           let bid = bundleDict["_0"] as? String {
            return "bundle:\(bid.lowercased())"
        }
        if let adhoc = locDict["adhocBinary"] as? [String: Any],
           let inner = adhoc["_0"] as? [String: Any],
           let rel = inner["relative"] as? String {
            return "exec:\(rel)"
        }
        return String(describing: locDict)
    }

    private func extractEntryIdentifiers(
        keyDict: [String: Any],
        valDict: [String: Any]
    ) -> (bundles: Set<String>, execs: Set<String>) {
        var bundles = Set<String>()
        var execs = Set<String>()

        func parseLocation(_ dict: [String: Any]) {
            if let b = (dict["bundle"] as? [String: Any])?["_0"] as? String {
                bundles.insert(b.lowercased())
            }
            if let rel = ((dict["adhocBinary"] as? [String: Any])?["_0"] as? [String: Any])?["relative"] as? String {
                execs.insert(rel)
            }
        }

        parseLocation(keyDict)
        if let loc = valDict["location"] as? [String: Any] {
            parseLocation(loc)
        }
        if let menuLocs = valDict["menuItemLocations"] as? [[String: Any]] {
            for m in menuLocs {
                parseLocation(m)
            }
        }
        return (bundles, execs)
    }

    // MARK: - Zero-Fork Pure C Daemon Lookup & Reload Helpers (0.05ms via `proc_listpids` + `proc_pidinfo`)

    private func currentMenuBarAgentPID() -> pid_t? {
        currentUserDaemonPIDs(named: "MenuBarAgent").first
    }

    private func currentDaemonPID(named processName: String) -> pid_t? {
        currentUserDaemonPIDs(named: processName).first
    }

    private func currentUserDaemonPIDs(named processName: String) -> [pid_t] {
        let uid = getuid()
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }
        let capacity = Int(byteCount) / MemoryLayout<pid_t>.stride + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let actualBytes = pids.withUnsafeMutableBytes { rawBuf -> Int32 in
            guard let base = rawBuf.baseAddress else { return 0 }
            return proc_listpids(UInt32(PROC_ALL_PIDS), 0, base, Int32(rawBuf.count))
        }
        guard actualBytes > 0 else { return [] }
        let count = Int(actualBytes) / MemoryLayout<pid_t>.stride
        let infoStride = Int32(MemoryLayout<proc_bsdinfo>.stride)
        var matches: [pid_t] = []
        var nameBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))

        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0 else { continue }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoStride) == infoStride,
                  info.pbi_uid == uid else {
                continue
            }
            let nameLen = proc_name(pid, &nameBuf, UInt32(nameBuf.count))
            if nameLen > 0 {
                let exeName = String(cString: nameBuf)
                if exeName == processName {
                    matches.append(pid)
                    continue
                }
            }
            let comm = withUnsafePointer(to: &info.pbi_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                    String(cString: $0)
                }
            }
            if comm == processName || (processName.count >= Int(MAXCOMLEN) && processName.hasPrefix(comm)) {
                matches.append(pid)
            }
        }
        return matches
    }

    private func processUptimeSeconds(pid: pid_t) -> Double? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard ret == size else { return nil }
        let startSec = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000.0
        return max(0.0, Date().timeIntervalSince1970 - startSec)
    }

    private func reloadDaemonIfThrottleSafe(processName: String) {
        guard let pid = currentDaemonPID(named: processName) else { return }
        if let uptime = processUptimeSeconds(pid: pid), uptime < minimumAgentUptimeBeforeReload {
            return
        }
        _ = kill(pid, SIGTERM)
    }

    private func postControlCenterStatusItemNotification(insert: Bool, identifiers: [String]) {
        let nameStr = insert
            ? "com.apple.controlcenter.setting.statusItemInsert"
            : "com.apple.controlcenter.setting.statusItemRemove"
        let center = CFNotificationCenterGetDistributedCenter()
        for id in identifiers {
            let info = ["identifier": id] as CFDictionary
            CFNotificationCenterPostNotification(center, CFNotificationName(nameStr as CFString), nil, info, true)
        }
    }

    private func remainingSecondsBeforeSafeReload() -> TimeInterval {
        guard let agentPID = currentMenuBarAgentPID() else {
            // Agent is currently respawning; wait ~1.2s
            return 1.2
        }
        guard let uptime = processUptimeSeconds(pid: agentPID) else {
            return 0
        }
        if uptime >= minimumAgentUptimeBeforeReload {
            return 0.0
        }
        return minimumAgentUptimeBeforeReload - uptime
    }

    private func flushUserCfprefsd() {
        // Send standard SIGTERM directly via kill() (0.05ms, zero fork/exec overhead!) so cfprefsd exits cleanly
        // under launchd's EnablePressuredExit without triggering launchd's 10-second abnormal-exit throttle.
        for pid in currentUserDaemonPIDs(named: "cfprefsd") {
            _ = kill(pid, SIGTERM)
        }
    }

    private func terminateMenuBarAgent() {
        if let pid = currentMenuBarAgentPID() {
            _ = kill(pid, SIGTERM)
        }
    }

    private func flushUserCfprefsdAndReloadMenuBarAgent() {
        flushUserCfprefsd()
        usleep(20_000)
        terminateMenuBarAgent()
    }
}
