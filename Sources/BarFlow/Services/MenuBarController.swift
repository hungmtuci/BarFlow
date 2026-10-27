import Foundation
import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Combine

@MainActor
final class MenuBarController: ObservableObject {
    static let shared = MenuBarController()

    // MARK: - Published State

    /// All currently running menu bar applications discovered by the background scanner.
    @Published private(set) var allRunningApps: [MenuBarAppItem] = []

    /// IDs of applications chosen by the user to stay visible on the Main Menu Bar.
    @Published var selectedMainBarIDs: Set<String> {
        didSet {
            guard selectedMainBarIDs != oldValue else { return }
            scheduleSaveSelection()
            onSecondaryAppsChanged?()
            if !allRunningApps.isEmpty {
                scheduleNativeMenuBarSync(delay: 0.60)
            }
        }
    }

    /// Whether BarFlow actively hides unselected apps from the Main Menu Bar.
    @Published var isMainBarHidingEnabled: Bool {
        didSet {
            guard isMainBarHidingEnabled != oldValue else { return }
            UserDefaults.standard.set(isMainBarHidingEnabled, forKey: Keys.hidingEnabled)
            applySpacersVisibilityState()
            if !allRunningApps.isEmpty {
                scheduleNativeMenuBarSync(delay: 0.35)
            }
        }
    }

    /// Auto-hide duration for the `Ctrl + B` floating secondary bar.
    @Published var autoHideDuration: AutoHideDuration {
        didSet {
            UserDefaults.standard.set(autoHideDuration.rawValue, forKey: Keys.autoHideSeconds)
        }
    }

    /// Whether to open the App Selection window automatically when BarFlow launches.
    @Published var showSelectionOnLaunch: Bool {
        didSet {
            UserDefaults.standard.set(showSelectionOnLaunch, forKey: Keys.showSelectionOnLaunch)
        }
    }

    /// Whether to hide BarFlow's icon from the macOS Dock.
    @Published var hideFromDock: Bool {
        didSet {
            UserDefaults.standard.set(hideFromDock, forKey: Keys.hideFromDock)
            applyDockPolicy()
        }
    }

    /// Whether BarFlow is currently rearranging items on the macOS Menu Bar.
    @Published private(set) var isArrangingMenuBar: Bool = false

    /// Human-readable status banner message for UI feedback.
    @Published var statusMessage: String = ""

    /// Lightweight UI filter state for AppSelectionView (avoids SwiftUIMacros @State dependency).
    @Published var searchText: String = ""
    @Published var filterModeRaw: String = "all"

    /// Whether Accessibility permission is currently granted.
    @Published private(set) var isAccessibilityGranted: Bool = AXIsProcessTrusted()

    /// Whether Full Disk Access (`Privacy_AllFiles`) is currently granted (required on macOS 26/27 `MenuBarAgent`).
    @Published private(set) var isFullDiskAccessGranted: Bool = MenuBarVisibilityEngine.shared.hasFullDiskAccess

    /// Whether the current macOS version uses `MenuBarAgent` (macOS 26 Tahoe / macOS 27+).
    let requiresFullDiskAccess: Bool = MenuBarVisibilityEngine.shared.usesMenuBarAgentArchitecture

    /// Returns `true` when the user launched `BarFlow.app` directly from `~/Downloads`, a mounted `.dmg`, or AppTranslocation.
    var shouldOfferMoveToApplications: Bool {
        let p = Bundle.main.bundlePath
        return p.contains("/Downloads/") || p.hasPrefix("/Volumes/") || p.contains("/AppTranslocation/")
    }

    // MARK: - Computed Filtered Lists

    /// Apps chosen to stay on the Main Menu Bar.
    var mainBarApps: [MenuBarAppItem] {
        allRunningApps.filter { selectedMainBarIDs.contains($0.id) }
    }

    /// Remaining running menu bar apps that appear in the `Ctrl + B` Secondary Bar right below the Menu Bar.
    var secondaryBarApps: [MenuBarAppItem] {
        allRunningApps.filter { !selectedMainBarIDs.contains($0.id) }
    }

    // MARK: - Callbacks to UI Controllers

    var onToggleSecondaryBarRequested: (() -> Void)?
    var onHideSecondaryBarRequested: (() -> Void)?
    var onOpenSelectionWindowRequested: (() -> Void)?
    var onSecondaryAppsChanged: (() -> Void)?

    // MARK: - Internal Properties

    private enum Keys {
        static let selectedIDs = "BarFlow.SelectedMainBarIDs"
        static let initialized = "BarFlow.HasInitializedSelection"
        static let hidingEnabled = "BarFlow.MainBarHidingEnabled"
        static let autoHideSeconds = "BarFlow.AutoHideSeconds"
        static let showSelectionOnLaunch = "BarFlow.ShowSelectionOnLaunch"
        static let hideFromDock = "BarFlow.HideFromDock"
    }

    private let interactionQueue = DispatchQueue(
        label: "com.hunglx.BarFlow.interaction",
        qos: .userInteractive
    )

    private var mainStatusItem: NSStatusItem?
    private var spacerItems: [NSStatusItem] = []
    private let spacerCount = 36
    private let singleSpacerWidth: CGFloat = 44.0

    private var areSpacersCurrentlyExpanded: Bool = false
    private var isTemporarilyRevealedForClick: Bool = false
    private var isMenuCurrentlyTracking: Bool = false
    private var isScanningInBackground: Bool = false
    private var isPerformingHIDSequence: Bool = false

    private var rehideMonitorTimer: Timer?
    private var backgroundMonitorTimer: Timer?
    private var nativeSyncDebounceWorkItem: DispatchWorkItem?
    private var deferredReloadTimer: Timer?
    private var isExecutingNativeSync: Bool = false
    private var hasQueuedFollowUpNativeSync: Bool = false
    private var hasPerformedStartupVisibilitySync: Bool = false
    private var knownDiscoveredAppIDs = Set<String>()
    private var lastBackgroundScanTime: CFAbsoluteTime = 0
    private var pendingSaveWorkItem: DispatchWorkItem?

    private init() {
        let savedArray = UserDefaults.standard.stringArray(forKey: Keys.selectedIDs) ?? []
        self.selectedMainBarIDs = Set(savedArray)

        if UserDefaults.standard.object(forKey: Keys.hidingEnabled) == nil {
            self.isMainBarHidingEnabled = true
            UserDefaults.standard.set(true, forKey: Keys.hidingEnabled)
        } else {
            self.isMainBarHidingEnabled = UserDefaults.standard.bool(forKey: Keys.hidingEnabled)
        }

        if UserDefaults.standard.object(forKey: Keys.autoHideSeconds) == nil {
            self.autoHideDuration = .fiveSeconds
            UserDefaults.standard.set(AutoHideDuration.fiveSeconds.rawValue, forKey: Keys.autoHideSeconds)
        } else {
            let raw = UserDefaults.standard.integer(forKey: Keys.autoHideSeconds)
            self.autoHideDuration = AutoHideDuration(rawValue: raw) ?? .fiveSeconds
        }

        if UserDefaults.standard.object(forKey: Keys.showSelectionOnLaunch) == nil {
            self.showSelectionOnLaunch = true
            UserDefaults.standard.set(true, forKey: Keys.showSelectionOnLaunch)
        } else {
            self.showSelectionOnLaunch = UserDefaults.standard.bool(forKey: Keys.showSelectionOnLaunch)
        }

        if UserDefaults.standard.object(forKey: Keys.hideFromDock) == nil {
            self.hideFromDock = false
            UserDefaults.standard.set(false, forKey: Keys.hideFromDock)
        } else {
            self.hideFromDock = UserDefaults.standard.bool(forKey: Keys.hideFromDock)
        }
    }

    // MARK: - Lifecycle Setup

    func start() {
        setupStatusItems()
        observeMenuTrackingNotifications()
        observeWorkspaceNotifications()

        // Initial non-blocking background scan
        refreshRunningAppsAsync(forceFullScan: true, initializeDefaultsIfNeeded: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.applySpacersVisibilityState()
        }

        // Ultra-lightweight monitor:
        // - Checks AXIsProcessTrusted() (0.01ms) & hasFullDiskAccess (0.005ms) every 2s so granting permissions takes effect immediately
        // - Once trusted, only runs a 11ms warm background scan every 10s without blocking MainActor
        backgroundMonitorTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let trusted = AXIsProcessTrusted()
                let fda = MenuBarVisibilityEngine.shared.hasFullDiskAccess

                let changedTrust = (trusted != self.isAccessibilityGranted)
                let changedFDA = (fda != self.isFullDiskAccessGranted)

                if changedTrust {
                    self.isAccessibilityGranted = trusted
                    self.applySpacersVisibilityState()
                }
                if changedFDA {
                    self.isFullDiskAccessGranted = fda
                }

                if changedTrust && trusted {
                    self.refreshRunningAppsAsync(forceFullScan: true, initializeDefaultsIfNeeded: true)
                    return
                }
                if changedFDA && fda && trusted && self.isMainBarHidingEnabled {
                    self.statusMessage = "Đã nhận quyền Full Disk Access — đang tự động ẩn các ứng dụng không chọn..."
                    self.scheduleNativeMenuBarSync(delay: 0.25)
                    return
                }

                guard trusted, !self.isPerformingHIDSequence, !self.isArrangingMenuBar else { return }
                let now = CFAbsoluteTimeGetCurrent()
                if (now - self.lastBackgroundScanTime) >= 10.0 {
                    self.refreshRunningAppsAsync(forceFullScan: false, initializeDefaultsIfNeeded: false)
                }
            }
        }
    }

    func prepareForTermination() {
        backgroundMonitorTimer?.invalidate()
        rehideMonitorTimer?.invalidate()
        nativeSyncDebounceWorkItem?.cancel()
        nativeSyncDebounceWorkItem = nil
        deferredReloadTimer?.invalidate()
        deferredReloadTimer = nil
        pendingSaveWorkItem?.perform()
        pendingSaveWorkItem = nil
        // Always collapse legacy spacers and restore native MenuBarAgent visibility on quit
        for spacer in spacerItems {
            spacer.isVisible = false
            spacer.length = 0
        }
        MenuBarVisibilityEngine.shared.restoreAllSynchronouslyOnQuit()
    }

    func applyDockPolicy() {
        NSApp.setActivationPolicy(hideFromDock ? .accessory : .regular)
    }

    // MARK: - Status Items (Main Toggle + Invisible Multi-Spacers)

    private func setupStatusItems() {
        guard mainStatusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "BarFlow.MainToggle"
        if let button = item.button {
            button.setAccessibilityIdentifier("BarFlow.MainToggle")
            updateMainButtonAppearance(isSecondaryOpen: false)
            button.toolTip = "BarFlow — Bấm chuột trái (hoặc Ctrl+B) để hiện/ẩn các app còn lại • Chuột phải để mở tuỳ chọn"
            button.target = self
            button.action = #selector(handleMainStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.mainStatusItem = item

        // On macOS 26/27 (`MenuBarAgent`), BarFlow hides unselected items natively without spacer bloat
        // (avoiding macOS's `«` overflow chevron and notch crowding). Legacy spacers are only created on macOS 14/15.
        guard !MenuBarVisibilityEngine.shared.usesMenuBarAgentArchitecture else {
            self.spacerItems = []
            return
        }

        var createdSpacers: [NSStatusItem] = []
        createdSpacers.reserveCapacity(spacerCount)
        for idx in 0..<spacerCount {
            let spacer = NSStatusBar.system.statusItem(withLength: 0)
            spacer.autosaveName = "BarFlow.Spacer.\(idx)"
            spacer.isVisible = false
            if let btn = spacer.button {
                btn.title = ""
                btn.image = nil
                btn.setAccessibilityIdentifier("BarFlow.Spacer.\(idx)")
                btn.target = self
                btn.action = #selector(handleSpacerClicked(_:))
                btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            createdSpacers.append(spacer)
        }
        self.spacerItems = createdSpacers
    }

    func updateMainButtonAppearance(isSecondaryOpen: Bool) {
        guard let button = mainStatusItem?.button else { return }
        let symbolName = isSecondaryOpen ? "chevron.up.circle.fill" : "ellipsis.circle"
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "BarFlow")?.withSymbolConfiguration(config) {
            img.isTemplate = true
            button.image = img
        } else {
            button.title = isSecondaryOpen ? "▴" : "•••"
        }
    }

    func mainStatusItemFrameCG() -> CGRect? {
        guard let win = mainStatusItem?.button?.window else { return nil }
        let rect = MenuBarScanner.appKitToCGRect(win.frame)
        return rect.width > 0 ? rect : nil
    }

    func mainStatusItemFrameAppKit() -> NSRect? {
        guard let win = mainStatusItem?.button?.window, win.frame.width > 0 else { return nil }
        return win.frame
    }

    @objc private func handleMainStatusItemClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            onToggleSecondaryBarRequested?()
            return
        }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showQuickContextMenu(from: sender)
        } else {
            onToggleSecondaryBarRequested?()
        }
    }

    @objc private func handleSpacerClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showQuickContextMenu(from: sender)
        }
    }

    private func showQuickContextMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()

        let header = NSMenuItem(title: "BarFlow — Quản lý Menu Bar", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let toggleBar = NSMenuItem(
            title: "Hiện / Ẩn thanh ứng dụng phụ (Ctrl + B)",
            action: #selector(menuToggleSecondaryBar),
            keyEquivalent: "b"
        )
        toggleBar.keyEquivalentModifierMask = [.control]
        toggleBar.target = self
        menu.addItem(toggleBar)

        let openSelect = NSMenuItem(
            title: "Chọn lọc ứng dụng trên Menu Bar chính...",
            action: #selector(menuOpenSelectionWindow),
            keyEquivalent: ","
        )
        openSelect.keyEquivalentModifierMask = [.command]
        openSelect.target = self
        menu.addItem(openSelect)

        let applyNow = NSMenuItem(
            title: "Áp dụng sắp xếp lên Menu Bar ngay",
            action: #selector(menuApplyArrangementNow),
            keyEquivalent: "r"
        )
        applyNow.keyEquivalentModifierMask = [.command]
        applyNow.target = self
        menu.addItem(applyNow)

        menu.addItem(.separator())

        let hidingToggle = NSMenuItem(
            title: "Tự động ẩn các app không chọn trên Menu Bar chính",
            action: #selector(menuToggleMainBarHiding),
            keyEquivalent: ""
        )
        hidingToggle.state = isMainBarHidingEnabled ? .on : .off
        hidingToggle.target = self
        menu.addItem(hidingToggle)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Thoát BarFlow",
            action: #selector(menuQuitApp),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)

        mainStatusItem?.menu = menu
        button.performClick(nil)
        mainStatusItem?.menu = nil
    }

    @objc private func menuToggleSecondaryBar() {
        onToggleSecondaryBarRequested?()
    }

    @objc private func menuOpenSelectionWindow() {
        onOpenSelectionWindowRequested?()
    }

    @objc private func menuApplyArrangementNow() {
        Task {
            await arrangeMenuBarAccordingToSelection()
        }
    }

    @objc private func menuToggleMainBarHiding() {
        isMainBarHidingEnabled.toggle()
    }

    @objc private func menuQuitApp() {
        prepareForTermination()
        NSApp.terminate(nil)
    }

    // MARK: - Spacer Expansion & Collapsing

    private func applySpacersVisibilityState() {
        guard !MenuBarVisibilityEngine.shared.usesMenuBarAgentArchitecture else { return }
        if isMainBarHidingEnabled && isAccessibilityGranted && !isTemporarilyRevealedForClick {
            setSpacersExpanded(true)
        } else {
            setSpacersExpanded(false)
        }
    }

    func setSpacersExpanded(_ expanded: Bool) {
        guard areSpacersCurrentlyExpanded != expanded else { return }
        areSpacersCurrentlyExpanded = expanded
        for spacer in spacerItems {
            if expanded {
                spacer.length = singleSpacerWidth
                spacer.isVisible = true
            } else {
                spacer.length = 0
                spacer.isVisible = false
            }
        }
    }

    // MARK: - Non-Blocking Scanning & Instant Selection Management

    func refreshRunningAppsAsync(forceFullScan: Bool = false, initializeDefaultsIfNeeded: Bool = false) {
        let trusted = AXIsProcessTrusted()
        if isAccessibilityGranted != trusted {
            isAccessibilityGranted = trusted
        }
        guard trusted, !isScanningInBackground else { return }

        isScanningInBackground = true
        lastBackgroundScanTime = CFAbsoluteTimeGetCurrent()

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let scannedApps = await MenuBarScanner.shared.scanMenuBarAsync(forceFullScan: forceFullScan)
            self.isScanningInBackground = false

            let oldSecondaryCount = self.secondaryBarApps.count
            let discoveredIDs = Set(scannedApps.map(\.id))
            let newUnselectedLaunched = !self.knownDiscoveredAppIDs.isEmpty &&
                discoveredIDs.subtracting(self.knownDiscoveredAppIDs).contains(where: { !self.selectedMainBarIDs.contains($0) })
            self.knownDiscoveredAppIDs.formUnion(discoveredIDs)

            if self.allRunningApps != scannedApps {
                self.allRunningApps = scannedApps
            }

            let hasInitialized = UserDefaults.standard.bool(forKey: Keys.initialized)
            if initializeDefaultsIfNeeded && !hasInitialized && !scannedApps.isEmpty {
                var initialIDs = Set<String>()
                var nonSystemCount = 0
                for app in scannedApps {
                    if app.isSystemItem {
                        initialIDs.insert(app.id)
                    } else if nonSystemCount < 5 {
                        initialIDs.insert(app.id)
                        nonSystemCount += 1
                    }
                }
                self.hasPerformedStartupVisibilitySync = true
                self.selectedMainBarIDs = initialIDs
                UserDefaults.standard.set(true, forKey: Keys.initialized)
            } else if !self.hasPerformedStartupVisibilitySync && !scannedApps.isEmpty {
                self.hasPerformedStartupVisibilitySync = true
                if self.isMainBarHidingEnabled {
                    self.scheduleNativeMenuBarSync(delay: 0.40)
                }
            } else if newUnselectedLaunched && self.isMainBarHidingEnabled {
                self.scheduleNativeMenuBarSync(delay: 0.75)
            }

            if self.secondaryBarApps.count != oldSecondaryCount {
                self.onSecondaryAppsChanged?()
            }
        }
    }

    func isSelectedForMainBar(_ item: MenuBarAppItem) -> Bool {
        selectedMainBarIDs.contains(item.id)
    }

    func toggleAppSelection(_ item: MenuBarAppItem) {
        if selectedMainBarIDs.contains(item.id) {
            selectedMainBarIDs.remove(item.id)
        } else {
            selectedMainBarIDs.insert(item.id)
        }
    }

    func setAppSelection(_ item: MenuBarAppItem, visibleOnMainBar: Bool) {
        if visibleOnMainBar {
            if !selectedMainBarIDs.contains(item.id) {
                selectedMainBarIDs.insert(item.id)
            }
        } else {
            if selectedMainBarIDs.contains(item.id) {
                selectedMainBarIDs.remove(item.id)
            }
        }
    }

    func selectAllForMainBar() {
        selectedMainBarIDs = Set(allRunningApps.map(\.id))
    }

    func moveAllToSecondaryBar() {
        selectedMainBarIDs = []
    }

    func deselectAllNonSystemForMainBar() {
        selectedMainBarIDs = Set(allRunningApps.filter(\.isSystemItem).map(\.id))
    }

    private func scheduleSaveSelection() {
        pendingSaveWorkItem?.cancel()
        let snapshot = Array(selectedMainBarIDs)
        let work = DispatchWorkItem {
            UserDefaults.standard.set(snapshot, forKey: Keys.selectedIDs)
            UserDefaults.standard.set(true, forKey: Keys.initialized)
        }
        pendingSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: - Permission & Installation Helpers

    func refreshPermissionsState() {
        let trusted = AXIsProcessTrusted()
        if isAccessibilityGranted != trusted {
            isAccessibilityGranted = trusted
        }
        let fda = MenuBarVisibilityEngine.shared.hasFullDiskAccess
        if isFullDiskAccessGranted != fda {
            isFullDiskAccessGranted = fda
        }
    }

    func openFullDiskAccessSettings(alsoRevealInFinder: Bool = false) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
        if alsoRevealInFinder {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            }
        }
    }

    func revealRunningAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func installToApplicationsAndRelaunch() {
        let srcPath = Bundle.main.bundlePath
        let dstPath = "/Applications/BarFlow.app"
        guard srcPath != dstPath else { return }

        let copyProc = Process()
        copyProc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        copyProc.arguments = ["--noextattr", srcPath, dstPath]
        do {
            try? FileManager.default.removeItem(atPath: dstPath)
            try copyProc.run()
            copyProc.waitUntilExit()
            guard copyProc.terminationStatus == 0 else {
                statusMessage = "Không thể chép vào /Applications (hãy kéo BarFlow.app vào thư mục Applications thủ công)."
                return
            }
            let xattrProc = Process()
            xattrProc.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattrProc.arguments = ["-cr", dstPath]
            try? xattrProc.run()
            xattrProc.waitUntilExit()

            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: dstPath), configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                Task { @MainActor in
                    NSApp.terminate(nil)
                }
            }
        } catch {
            statusMessage = "Không thể tự động cài vào /Applications: \(error.localizedDescription)"
        }
    }

    func refreshAndSyncManually() {
        refreshPermissionsState()
        guard isAccessibilityGranted else {
            MenuBarScanner.shared.promptForAccessibilityPermission()
            statusMessage = "Vui lòng cấp quyền Trợ năng (Accessibility) ở khung phía trên để quét danh sách Menu Bar."
            return
        }
        statusMessage = "Đang quét lại toàn bộ ứng dụng trên Menu Bar..."
        Task { @MainActor in
            let scanned = await MenuBarScanner.shared.scanMenuBarAsync(forceFullScan: true)
            self.allRunningApps = scanned
            self.onSecondaryAppsChanged?()

            if self.requiresFullDiskAccess && !self.isFullDiskAccessGranted {
                self.statusMessage = "Đã quét \(scanned.count) biểu tượng. Hãy cấp thêm quyền Full Disk Access ở khung phía trên để ẩn khỏi Menu Bar chính."
                return
            }

            if self.isMainBarHidingEnabled && self.requiresFullDiskAccess {
                let anyUnselectedStillVisible = self.secondaryBarApps.contains(where: \.isCurrentlyOnBar)
                if anyUnselectedStillVisible {
                    await self.executeNativeMenuBarSync(forceReload: true)
                    return
                }
            }
            self.statusMessage = "Đã làm mới danh sách (\(scanned.count) biểu tượng đang chạy)."
        }
    }

    // MARK: - Native MenuBarAgent Visibility Sync (macOS 26/27+) & Legacy ⌘-Drag Fallback

    private func scheduleNativeMenuBarSync(delay: TimeInterval) {
        guard MenuBarVisibilityEngine.shared.usesMenuBarAgentArchitecture else { return }
        guard MenuBarVisibilityEngine.shared.hasFullDiskAccess else {
            isFullDiskAccessGranted = false
            return
        }
        nativeSyncDebounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                await self?.executeNativeMenuBarSync(forceReload: false)
            }
        }
        nativeSyncDebounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func executeNativeMenuBarSync(forceReload: Bool = false) async {
        guard MenuBarVisibilityEngine.shared.usesMenuBarAgentArchitecture else { return }
        refreshPermissionsState()

        guard isAccessibilityGranted else {
            statusMessage = "Vui lòng cấp quyền Trợ năng (Accessibility) ở khung phía trên trước khi áp dụng."
            return
        }
        guard isFullDiskAccessGranted else {
            statusMessage = "Chưa có quyền Full Disk Access — hãy bấm nút 'Cấp quyền Full Disk Access' ở khung hướng dẫn phía trên để macOS cho phép ẩn icon khỏi Menu Bar chính."
            return
        }
        guard !allRunningApps.isEmpty else { return }

        if isExecutingNativeSync {
            hasQueuedFollowUpNativeSync = true
            return
        }

        isExecutingNativeSync = true
        isArrangingMenuBar = true
        deferredReloadTimer?.invalidate()
        deferredReloadTimer = nil

        let appsSnapshot = allRunningApps
        let selectedSnapshot = selectedMainBarIDs
        let hidingSnapshot = isMainBarHidingEnabled

        let outcome = await MenuBarVisibilityEngine.shared.syncMenuBarState(
            allApps: appsSnapshot,
            selectedMainBarIDs: selectedSnapshot,
            hidingEnabled: hidingSnapshot,
            forceReload: forceReload
        )

        isExecutingNativeSync = false

        if hasQueuedFollowUpNativeSync {
            hasQueuedFollowUpNativeSync = false
            await executeNativeMenuBarSync(forceReload: forceReload)
            return
        }

        if let err = outcome.errorReason {
            isArrangingMenuBar = false
            switch err {
            case .missingFullDiskAccess:
                isFullDiskAccessGranted = false
                statusMessage = "Cần cấp quyền Full Disk Access (Truy cập Toàn bộ Đĩa) ở khung phía trên để ẩn ứng dụng khỏi Menu Bar chính."
            case .writeFailed(let detail):
                statusMessage = "Không thể ghi cấu hình Menu Bar (\(detail)). Hãy kiểm tra lại quyền Full Disk Access."
            }
            return
        }

        if let waitSec = outcome.deferredReloadDelay {
            let secs = max(1, Int(ceil(waitSec)))
            statusMessage = "Đang đồng bộ Menu Bar chính (cập nhật sau ~\(secs) giây để tránh trễ hệ thống)..."
            scheduleDeferredMenuBarAgentReload(after: waitSec + 0.12, hiddenCount: outcome.hiddenCount)
            return
        }

        isArrangingMenuBar = false
        if outcome.didReloadAgent || outcome.didModifyPreferences {
            if hidingSnapshot {
                statusMessage = outcome.hiddenCount > 0
                    ? "Đã ẩn \(outcome.hiddenCount) ứng dụng khỏi Menu Bar chính (bấm Ctrl + B để mở nhanh)!"
                    : "Đã hiển thị toàn bộ ứng dụng lên Menu Bar chính!"
            } else {
                statusMessage = "Đã tạm tắt ẩn — toàn bộ ứng dụng đang hiện trên Menu Bar chính."
            }
            // Refresh live slot statuses cleanly once MenuBarAgent finishes respawning (~1.1s)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) { [weak self] in
                self?.refreshRunningAppsAsync(forceFullScan: false)
            }
        } else if forceReload {
            let countNow = secondaryBarApps.count
            statusMessage = (hidingSnapshot && countNow > 0)
                ? "Đã xác nhận ẩn \(countNow) ứng dụng khỏi Menu Bar chính (bấm Ctrl + B để mở nhanh)!"
                : "Menu Bar chính đã khớp danh sách chọn lọc!"
        }
    }

    private func scheduleDeferredMenuBarAgentReload(after delay: TimeInterval, hiddenCount: Int) {
        deferredReloadTimer?.invalidate()
        deferredReloadTimer = Timer.scheduledTimer(withTimeInterval: max(0.2, delay), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if let stillRemaining = await MenuBarVisibilityEngine.shared.performDeferredReloadIfReady() {
                    self.scheduleDeferredMenuBarAgentReload(after: stillRemaining + 0.15, hiddenCount: hiddenCount)
                    return
                }
                self.isArrangingMenuBar = false
                if self.isMainBarHidingEnabled {
                    let countNow = self.secondaryBarApps.count
                    self.statusMessage = countNow > 0
                        ? "Đã ẩn \(countNow) ứng dụng khỏi Menu Bar chính (bấm Ctrl + B để mở nhanh)!"
                        : "Đã hiển thị toàn bộ ứng dụng lên Menu Bar chính!"
                } else {
                    self.statusMessage = "Đã hiển thị toàn bộ ứng dụng lên Menu Bar chính!"
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) { [weak self] in
                    self?.refreshRunningAppsAsync(forceFullScan: false)
                }
            }
        }
    }

    func arrangeMenuBarAccordingToSelection() async {
        refreshPermissionsState()
        guard isAccessibilityGranted else {
            MenuBarScanner.shared.promptForAccessibilityPermission()
            statusMessage = "Vui lòng cấp quyền Trợ năng (Accessibility) để sắp xếp Menu Bar."
            return
        }

        // Fast native path for macOS 26/27+ (`MenuBarAgent`)
        if MenuBarVisibilityEngine.shared.usesMenuBarAgentArchitecture {
            guard isFullDiskAccessGranted else {
                openFullDiskAccessSettings(alsoRevealInFinder: true)
                statusMessage = "Đã mở cài đặt Full Disk Access & Finder — hãy kéo BarFlow.app thả vào danh sách Full Disk Access rồi bật công tắc!"
                return
            }
            nativeSyncDebounceWorkItem?.cancel()
            nativeSyncDebounceWorkItem = nil
            statusMessage = "Đang áp dụng danh sách chọn lọc lên Menu Bar chính..."
            await executeNativeMenuBarSync(forceReload: true)
            return
        }

        guard !isArrangingMenuBar, !isPerformingHIDSequence else { return }

        isArrangingMenuBar = true
        isPerformingHIDSequence = true
        statusMessage = "Đang sắp xếp các icon trên Menu Bar chính (giữ nguyên chuột trong giây lát)..."

        defer {
            isPerformingHIDSequence = false
            isArrangingMenuBar = false
            if isMainBarHidingEnabled {
                setSpacersExpanded(true)
            }
            refreshRunningAppsAsync(forceFullScan: true)
        }

        let wasExpanded = areSpacersCurrentlyExpanded
        if wasExpanded {
            setSpacersExpanded(false)
            try? await Task.sleep(nanoseconds: 280_000_000)
        }

        guard let targetDisplay = MenuBarScanner.widestDisplayGeometry() else {
            statusMessage = "Không tìm thấy màn hình để sắp xếp."
            return
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let appsSnapshot = allRunningApps
        let itemByID: [String: MenuBarAppItem] = Dictionary(
            appsSnapshot.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var movedCount = 0
        var dragBlockedBySystem = false

        for _ in 0..<24 {
            let ownFrame = mainStatusItemFrameCG()
            let slots = await withCheckedContinuation { continuation in
                interactionQueue.async {
                    let live = MenuBarScanner.shared.readLiveSlotsForArrangement(
                        apps: appsSnapshot,
                        ownPID: ownPID,
                        ownMainToggleFrameCG: ownFrame,
                        on: targetDisplay
                    )
                    continuation.resume(returning: live)
                }
            }

            guard let mainToggleSlot = slots.first(where: { $0.sourcePID == ownPID }) else {
                break
            }
            let barFlowMinX = mainToggleSlot.frame.minX
            let barFlowMaxX = mainToggleSlot.frame.maxX

            // Case A: Selected app sitting to the LEFT of BarFlow -> move it to the RIGHT of BarFlow
            if let wrongLeftSlot = slots.first(where: { slot in
                guard slot.sourcePID > 0, slot.sourcePID != ownPID,
                      slot.frame.maxX <= barFlowMinX + 2,
                      let slotItemID = slot.itemID,
                      let item = itemByID[slotItemID], item.isMovable else { return false }
                return selectedMainBarIDs.contains(item.id)
            }), let movedID = wrongLeftSlot.itemID, let movedItem = itemByID[movedID] {
                let beforeX = wrongLeftSlot.frame.minX
                let targetPoint = CGPoint(
                    x: min(barFlowMaxX + 16, wrongLeftSlot.hostWindowFrame.maxX - 24),
                    y: mainToggleSlot.frame.midY
                )
                await performCommandDrag(from: wrongLeftSlot.center, to: targetPoint)
                try? await Task.sleep(nanoseconds: 180_000_000)

                let afterFrame = await withCheckedContinuation { continuation in
                    interactionQueue.async {
                        continuation.resume(
                            returning: MenuBarScanner.shared.liveStatusElement(
                                for: movedItem,
                                preferredDisplay: targetDisplay,
                                timeout: 0.18
                            )?.frame
                        )
                    }
                }
                if let afterX = afterFrame?.minX, abs(afterX - beforeX) > 4 {
                    movedCount += 1
                    continue
                } else {
                    dragBlockedBySystem = true
                    break
                }
            }

            // Case B: Unselected app sitting to the RIGHT of BarFlow -> move it to the LEFT of BarFlow
            if let wrongRightSlot = slots.first(where: { slot in
                guard slot.sourcePID > 0, slot.sourcePID != ownPID,
                      slot.frame.minX >= barFlowMaxX - 2,
                      let slotItemID = slot.itemID,
                      let item = itemByID[slotItemID], item.isMovable else { return false }
                return !selectedMainBarIDs.contains(item.id)
            }), let movedID = wrongRightSlot.itemID, let movedItem = itemByID[movedID] {
                let beforeX = wrongRightSlot.frame.minX
                let targetPoint = CGPoint(
                    x: max(barFlowMinX - 18, wrongRightSlot.hostWindowFrame.minX + 360),
                    y: mainToggleSlot.frame.midY
                )
                await performCommandDrag(from: wrongRightSlot.center, to: targetPoint)
                try? await Task.sleep(nanoseconds: 180_000_000)

                let afterFrame = await withCheckedContinuation { continuation in
                    interactionQueue.async {
                        continuation.resume(
                            returning: MenuBarScanner.shared.liveStatusElement(
                                for: movedItem,
                                preferredDisplay: targetDisplay,
                                timeout: 0.18
                            )?.frame
                        )
                    }
                }
                if let afterX = afterFrame?.minX, abs(afterX - beforeX) > 4 {
                    movedCount += 1
                    continue
                } else {
                    dragBlockedBySystem = true
                    break
                }
            }

            break
        }

        if isMainBarHidingEnabled {
            setSpacersExpanded(true)
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        if movedCount > 0 {
            statusMessage = "Đã sắp xếp xong \(movedCount) biểu tượng trên Menu Bar chính!"
        } else if dragBlockedBySystem {
            statusMessage = "Đã cập nhật thanh Ctrl + B! Trên macOS mới, hãy giữ phím ⌘ kéo biểu tượng ••• sang bên phải các app muốn ẩn 1 lần để ẩn khỏi thanh trên."
        } else {
            statusMessage = "Menu Bar chính đã khớp danh sách chọn lọc!"
        }
    }

    // MARK: - Instant App Activation from `Ctrl + B` Secondary Bar

    /// Invoked when the user clicks (or right-clicks) an app icon inside the floating `Ctrl + B` Secondary Bar.
    func activateAppFromSecondaryBar(_ item: MenuBarAppItem, rightClick: Bool = false) {
        // 1. Dismiss the floating Secondary Bar immediately (0ms, no animation delay)
        onHideSecondaryBarRequested?()

        Task { @MainActor in
            await performHiddenAppInteraction(item, rightClick: rightClick)
        }
    }

    private func performHiddenAppInteraction(_ item: MenuBarAppItem, rightClick: Bool) async {
        guard !isPerformingHIDSequence else { return }

        // Handle hidden macOS System Modules (`Spotlight`, `Wi-Fi`, `Battery`, `Screen Mirroring`, `Input Menu`, etc.) instantaneously
        if MenuBarVisibilityEngine.shared.usesMenuBarAgentArchitecture &&
            (item.pid == 0 || (item.isSystemItem && !item.isCurrentlyOnBar)) {
            MenuBarVisibilityEngine.shared.triggerHiddenSystemItem(item, rightClick: rightClick)
            return
        }

        isPerformingHIDSequence = true

        let displays = MenuBarScanner.captureDisplayGeometries()
        let windowsBefore = currentOnScreenWindows(for: item.pid)
        var collapsedSpacersTemporarily = false

        // 2. Legacy macOS 14/15 spacer collapse (skipped on macOS 26/27 where `AXPress` opens menus at top-right directly while hidden!)
        if !MenuBarVisibilityEngine.shared.usesMenuBarAgentArchitecture && areSpacersCurrentlyExpanded {
            let ownFrame = mainStatusItemFrameCG()
            let alreadyVisibleRightOfSpacer: Bool = {
                guard item.isCurrentlyOnBar, let itemFrame = item.slotFrame else { return false }
                if let own = ownFrame, itemFrame.DisplayIntersects(own) {
                    return itemFrame.minX > own.minX
                }
                return MenuBarScanner.isFrameVisiblyOnMenuBar(itemFrame, displays: displays)
            }()

            if !alreadyVisibleRightOfSpacer {
                isTemporarilyRevealedForClick = true
                collapsedSpacersTemporarily = true
                setSpacersExpanded(false)
                // Give MenuBarAgent ~75ms to restore the item's on-bar slot so its menu/popover anchors cleanly
                try? await Task.sleep(nanoseconds: 75_000_000)
            }
        }

        // 3. Trigger the status item directly on the high-priority background interactionQueue (0ms MainActor block!)
        let targetPID = item.pid
        let mouseDisplay = MenuBarScanner.displayGeometryContainingMouse()
        let savedCursor = currentMouseCGLocation()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            interactionQueue.async { [weak self] in
                defer { continuation.resume() }

                let live = MenuBarScanner.shared.liveStatusElement(
                    for: item,
                    preferredDisplay: mouseDisplay,
                    timeout: 0.22
                )
                guard let axEl = live?.element ?? item.axElement else {
                    if let app = NSRunningApplication(processIdentifier: targetPID) {
                        app.activate()
                    }
                    return
                }

                AXUIElementSetMessagingTimeout(axEl, 0.18)

                if rightClick {
                    // Check if status item exposes a dedicated right-click / context menu AX action
                    var actionsRef: CFArray?
                    let actions: [String] = (AXUIElementCopyActionNames(axEl, &actionsRef) == .success)
                        ? ((actionsRef as? [String]) ?? [])
                        : []

                    if let menuAction = actions.first(where: { $0 == "AXShowMenu" || $0 == "AXSecondaryMenu" }) {
                        _ = AXUIElementPerformAction(axEl, menuAction as CFString)
                        return
                    }

                    if let rect = live?.frame ?? MenuBarScanner.shared.readAXFrame(axEl), rect.width > 0 {
                        self?.postWarpedHIDClickSync(
                            at: CGPoint(x: rect.midX, y: rect.midY),
                            button: .right,
                            savedCursor: savedCursor
                        )
                        return
                    }

                    _ = AXUIElementPerformAction(axEl, kAXPressAction as CFString)
                    return
                }

                // Left-click: Direct Accessibility `AXPress`
                // Empirical behavior on macOS 14–27:
                // - Returns `.success` (0) for NSPopover / NSPanel / MenuBarExtra(.window) apps (Itsycal, Maccy, Claude, Caffeine, etc.)
                // - Returns `.cannotComplete` (-25204) when NSMenu opens and enters NSEventTrackingRunLoopMode (QuickFolder, Moom, OpenKey, Yoink, etc.)
                // NEVER call runningApp.activate() on -25204, as stealing focus closes the open NSMenu!
                let err = AXUIElementPerformAction(axEl, kAXPressAction as CFString)
                if err == .success || err == .cannotComplete {
                    return
                }

                // Fallback 1: Custom NSView inside NSStatusItem with a child AXButton
                var childrenRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(axEl, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                   let children = childrenRef as? [AXUIElement],
                   let childButton = children.first {
                    AXUIElementSetMessagingTimeout(childButton, 0.18)
                    let childErr = AXUIElementPerformAction(childButton, kAXPressAction as CFString)
                    if childErr == .success || childErr == .cannotComplete {
                        return
                    }
                }

                // Fallback 2: Legacy warped HID click or app activation
                if let rect = live?.frame ?? MenuBarScanner.shared.readAXFrame(axEl), rect.width > 0 {
                    self?.postWarpedHIDClickSync(
                        at: CGPoint(x: rect.midX, y: rect.midY),
                        button: .left,
                        savedCursor: savedCursor
                    )
                } else if let app = NSRunningApplication(processIdentifier: targetPID) {
                    app.activate()
                }
            }
        }

        isPerformingHIDSequence = false

        // 4. Re-expand spacers cleanly once the user closes the opened NSMenu or NSPopover/NSPanel
        if collapsedSpacersTemporarily {
            try? await Task.sleep(nanoseconds: 220_000_000)
            scheduleSmartRehide(targetPID: item.pid, baselineWindows: windowsBefore)
        }
    }

    // MARK: - Smart Auto-Rehide After Menu/Popover Closes

    private func observeMenuTrackingNotifications() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(
            forName: NSNotification.Name("com.apple.HIToolbox.beginMenuTrackingNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isMenuCurrentlyTracking = true
            }
        }
        dnc.addObserver(
            forName: NSNotification.Name("com.apple.HIToolbox.endMenuTrackingNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isMenuCurrentlyTracking = false
            }
        }
    }

    private func observeWorkspaceNotifications() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let launchedBundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            guard launchedBundle != "com.apple.MenuBarAgent" else { return }
            Task { @MainActor in
                MenuBarScanner.shared.handleAppLaunched()
                try? await Task.sleep(nanoseconds: 900_000_000)
                self?.refreshRunningAppsAsync(forceFullScan: true)
            }
        }
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier != "com.apple.MenuBarAgent" else { return }
            let terminatedPID = app?.processIdentifier ?? 0
            Task { @MainActor in
                MenuBarScanner.shared.handleAppTerminated(pid: terminatedPID)
                self?.refreshRunningAppsAsync(forceFullScan: false)
            }
        }
    }

    private func scheduleSmartRehide(targetPID: pid_t, baselineWindows: Set<Int>) {
        rehideMonitorTimer?.invalidate()
        let startedAt = Date()

        rehideMonitorTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self else {
                    timer.invalidate()
                    return
                }

                if self.isMenuCurrentlyTracking && Date().timeIntervalSince(startedAt) < 30 {
                    return
                }

                let currentWins = self.currentOnScreenWindows(for: targetPID)
                let newPopupWindows = currentWins.subtracting(baselineWindows)
                if !newPopupWindows.isEmpty && Date().timeIntervalSince(startedAt) < 30 {
                    return
                }

                timer.invalidate()
                self.rehideMonitorTimer = nil
                self.isTemporarilyRevealedForClick = false
                if self.isMainBarHidingEnabled {
                    self.setSpacersExpanded(true)
                }
            }
        }
    }

    private func currentOnScreenWindows(for pid: pid_t) -> Set<Int> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var result = Set<Int>()
        for w in list {
            let ownerPID = pid_t(w[kCGWindowOwnerPID as String] as? Int ?? 0)
            guard ownerPID == pid else { continue }
            let alpha = w[kCGWindowAlpha as String] as? Double ?? 1.0
            guard alpha > 0.05 else { continue }
            if let wid = w[kCGWindowNumber as String] as? Int {
                result.insert(wid)
            }
        }
        return result
    }

    // MARK: - Low-Level Quartz HID Helpers

    nonisolated private func configureNonSuppressingEventSources() -> CGEventSource? {
        let allMask: CGEventFilterMask = [
            .permitLocalMouseEvents,
            .permitLocalKeyboardEvents,
            .permitSystemDefinedEvents
        ]
        if let combined = CGEventSource(stateID: .combinedSessionState) {
            combined.setLocalEventsFilterDuringSuppressionState(allMask, state: .eventSuppressionStateRemoteMouseDrag)
            combined.setLocalEventsFilterDuringSuppressionState(allMask, state: .eventSuppressionStateSuppressionInterval)
            combined.localEventsSuppressionInterval = 0
        }
        let hid = CGEventSource(stateID: .hidSystemState)
        hid?.setLocalEventsFilterDuringSuppressionState(allMask, state: .eventSuppressionStateRemoteMouseDrag)
        hid?.setLocalEventsFilterDuringSuppressionState(allMask, state: .eventSuppressionStateSuppressionInterval)
        hid?.localEventsSuppressionInterval = 0
        return hid
    }

    private func currentMouseCGLocation() -> CGPoint {
        let nsLoc = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1440
        return CGPoint(x: nsLoc.x, y: primaryHeight - nsLoc.y)
    }

    nonisolated private func postWarpedHIDClickSync(
        at point: CGPoint,
        button: CGMouseButton,
        savedCursor: CGPoint
    ) {
        guard let src = configureNonSuppressingEventSources() else { return }
        let downType: CGEventType = (button == .right) ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = (button == .right) ? .rightMouseUp : .leftMouseUp

        guard let down = CGEvent(mouseEventSource: src, mouseType: downType, mouseCursorPosition: point, mouseButton: button),
              let up = CGEvent(mouseEventSource: src, mouseType: upType, mouseCursorPosition: point, mouseButton: button) else {
            return
        }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)

        CGDisplayHideCursor(CGMainDisplayID())
        defer {
            CGWarpMouseCursorPosition(savedCursor)
            CGDisplayShowCursor(CGMainDisplayID())
        }

        CGWarpMouseCursorPosition(point)
        usleep(14_000)
        down.post(tap: .cghidEventTap)
        usleep(28_000)
        up.post(tap: .cghidEventTap)
        usleep(20_000)
    }

    private func performCommandDrag(from start: CGPoint, to end: CGPoint) async {
        let savedCursor = currentMouseCGLocation()
        guard let src = configureNonSuppressingEventSources() else { return }

        func makeDragEvent(_ type: CGEventType, at pt: CGPoint) -> CGEvent? {
            guard let ev = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: pt, mouseButton: .left) else {
                return nil
            }
            ev.flags = .maskCommand
            if type == .leftMouseDown || type == .leftMouseUp {
                ev.setIntegerValueField(.mouseEventClickState, value: 1)
            }
            return ev
        }

        CGDisplayHideCursor(CGMainDisplayID())
        defer {
            CGWarpMouseCursorPosition(savedCursor)
            CGDisplayShowCursor(CGMainDisplayID())
        }

        CGWarpMouseCursorPosition(start)
        try? await Task.sleep(nanoseconds: 18_000_000)
        makeDragEvent(.leftMouseDown, at: start)?.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 25_000_000)

        let steps = 10
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            CGWarpMouseCursorPosition(p)
            makeDragEvent(.leftMouseDragged, at: p)?.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 22_000_000)
        }

        CGWarpMouseCursorPosition(end)
        makeDragEvent(.leftMouseUp, at: end)?.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 25_000_000)
    }
}

private extension CGRect {
    func DisplayIntersects(_ other: CGRect) -> Bool {
        abs(self.midY - other.midY) <= 40
    }
}
