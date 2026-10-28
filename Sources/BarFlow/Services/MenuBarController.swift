import Foundation
import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Combine
import Darwin
import ServiceManagement

/// Off-MainActor JSON state snapshot (`~/Library/Application Support/BarFlow/layout_state.json`)
/// so toggling & reordering NEVER block `@MainActor` on `cfprefsd` / `NSUserDefaults` XPC!
private struct PersistedLayoutState: Codable, Sendable {
    var initialized: Bool = false
    var selectedMainBarIDs: [String] = []
    var mainBarOrderIDs: [String] = []
    var secondaryBarOrderIDs: [String] = []
    var allAppsOrderIDs: [String] = []
    var hidingEnabled: Bool = true
    var autoHideSeconds: Int = AutoHideDuration.fiveSeconds.rawValue
    var showSelectionOnLaunch: Bool = true
    var hideFromDock: Bool = false
    var hotKeyBinding: HotKeyBinding? = nil
    var hoverToOpenEnabled: Bool? = nil
    var launchAtLogin: Bool? = nil
}

@MainActor
final class MenuBarController: ObservableObject {
    static let shared = MenuBarController()

    // MARK: - Published State

    /// All currently running menu bar applications discovered by the background scanner.
    @Published private(set) var allRunningApps: [MenuBarAppItem] = []

    /// Stable-ordered list for the "Tất cả" tab (never jumps up/down when toggling an app!).
    @Published private(set) var stableAllApps: [MenuBarAppItem] = []

    /// Apps chosen to stay on the Main Menu Bar, ordered strictly Left -> Right per user preference.
    @Published private(set) var mainBarApps: [MenuBarAppItem] = []

    /// Apps shown in the `Ctrl + B` Secondary Bar, ordered strictly Left -> Right per user preference.
    @Published private(set) var secondaryBarApps: [MenuBarAppItem] = []

    /// IDs of applications chosen by the user to stay visible on the Main Menu Bar.
    @Published private(set) var selectedMainBarIDs: Set<String>

    /// Ordered IDs (Left -> Right) for Main Menu Bar & Secondary Bar (`Ctrl + B`).
    private(set) var mainBarOrderIDs: [String] = []
    private(set) var secondaryBarOrderIDs: [String] = []
    private var allAppsOrderIDs: [String] = []

    /// Active item ID currently being dragged during Drag & Drop reordering (avoids @State macro).
    @Published var draggingItemID: String? = nil

    /// Whether BarFlow actively hides unselected apps from the Main Menu Bar.
    @Published var isMainBarHidingEnabled: Bool {
        didSet {
            guard isMainBarHidingEnabled != oldValue else { return }
            markUserInteraction()
            scheduleSaveState()
            applySpacersVisibilityState()
            if !allRunningApps.isEmpty {
                scheduleNativeMenuBarSync(delay: 0.16)
            }
        }
    }

    /// Auto-hide duration for the `Ctrl + B` floating secondary bar.
    @Published var autoHideDuration: AutoHideDuration {
        didSet {
            guard autoHideDuration != oldValue else { return }
            scheduleSaveState()
        }
    }

    /// Whether to open the App Selection window automatically when BarFlow launches.
    @Published var showSelectionOnLaunch: Bool {
        didSet {
            guard showSelectionOnLaunch != oldValue else { return }
            scheduleSaveState()
        }
    }

    /// Whether to hide BarFlow's icon from the macOS Dock.
    @Published var hideFromDock: Bool {
        didSet {
            guard hideFromDock != oldValue else { return }
            scheduleSaveState()
            applyDockPolicy()
        }
    }

    /// Customizable global keyboard shortcut to toggle the Secondary Bar (default: `Ctrl + B`).
    @Published var hotKeyBinding: HotKeyBinding {
        didSet {
            guard hotKeyBinding != oldValue else { return }
            scheduleSaveState()
            HotKeyService.shared.updateBinding(hotKeyBinding)
            refreshMainStatusItemToolTip()
        }
    }

    /// Whether hovering the mouse over `•••` on the Menu Bar opens the Secondary Bar automatically.
    @Published var hoverToOpenEnabled: Bool {
        didSet {
            guard hoverToOpenEnabled != oldValue else { return }
            scheduleSaveState()
            refreshMainStatusItemToolTip()
        }
    }

    /// Whether BarFlow launches automatically when logging into macOS (`SMAppService.mainApp`).
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue, !isUpdatingLaunchAtLoginInternally else { return }
            applyLaunchAtLoginChange()
            scheduleSaveState()
        }
    }

    /// Whether the user explicitly triggered a manual arrangement/sync (used only for the header button spinner).
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
        qos: .userInteractive,
        attributes: .concurrent
    )
    private let persistenceQueue = DispatchQueue(
        label: "com.hunglx.BarFlow.persistence",
        qos: .utility
    )
    private let stateFileURL: URL

    private var mainStatusItem: NSStatusItem?
    private var spacerItems: [NSStatusItem] = []
    private let spacerCount = 36
    private let singleSpacerWidth: CGFloat = 44.0

    private var areSpacersCurrentlyExpanded: Bool = false
    private var isTemporarilyRevealedForClick: Bool = false
    private var isMenuCurrentlyTracking: Bool = false
    private var isScanningInBackground: Bool = false
    private var isPerformingHIDSequence: Bool = false
    private var activeProbeStartedAt: CFAbsoluteTime = 0

    private var rehideMonitorTimer: Timer?
    private var backgroundMonitorTimer: Timer?
    private var nativeSyncDebounceWorkItem: DispatchWorkItem?
    private var deferredReloadTimer: Timer?
    private var isExecutingNativeSync: Bool = false
    private var hasQueuedFollowUpNativeSync: Bool = false
    private var hasPerformedStartupVisibilitySync: Bool = false
    private var hasInitializedSelectionFlag: Bool = false
    private var knownDiscoveredAppIDs = Set<String>()
    private var lastBackgroundScanTime: CFAbsoluteTime = 0
    private var lastUserInteractionTime: CFAbsoluteTime = 0
    private var pendingSaveWorkItem: DispatchWorkItem?
    private var dragEndWatchdogTimer: Timer?
    private var needsNativeSyncAfterDragEnd: Bool = false
    private var isUpdatingLaunchAtLoginInternally: Bool = false
    private var statusItemScrollMonitor: Any?
    private var lastScrollTriggerTime: CFAbsoluteTime = 0

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dirURL = appSupport.appendingPathComponent("BarFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let fileURL = dirURL.appendingPathComponent("layout_state.json")
        self.stateFileURL = fileURL

        let systemLaunchEnabled = (SMAppService.mainApp.status == .enabled)

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(PersistedLayoutState.self, from: data) {
            self.hasInitializedSelectionFlag = decoded.initialized
            self.selectedMainBarIDs = Set(decoded.selectedMainBarIDs)
            self.mainBarOrderIDs = decoded.mainBarOrderIDs
            self.secondaryBarOrderIDs = decoded.secondaryBarOrderIDs
            self.allAppsOrderIDs = decoded.allAppsOrderIDs
            self.isMainBarHidingEnabled = decoded.hidingEnabled
            self.autoHideDuration = AutoHideDuration(rawValue: decoded.autoHideSeconds) ?? .fiveSeconds
            self.showSelectionOnLaunch = decoded.showSelectionOnLaunch
            self.hideFromDock = decoded.hideFromDock
            self.hotKeyBinding = decoded.hotKeyBinding ?? .defaultCtrlB
            self.hoverToOpenEnabled = decoded.hoverToOpenEnabled ?? false
            self.launchAtLogin = systemLaunchEnabled || (decoded.launchAtLogin ?? false)
        } else {
            // Seamless migration from v1.0–v1.4 UserDefaults
            let savedArray = UserDefaults.standard.stringArray(forKey: Keys.selectedIDs) ?? []
            self.hasInitializedSelectionFlag = UserDefaults.standard.bool(forKey: Keys.initialized)
            self.selectedMainBarIDs = Set(savedArray)
            self.mainBarOrderIDs = savedArray
            self.secondaryBarOrderIDs = []
            self.allAppsOrderIDs = []
            self.hotKeyBinding = .defaultCtrlB
            self.hoverToOpenEnabled = false
            self.launchAtLogin = systemLaunchEnabled

            if UserDefaults.standard.object(forKey: Keys.hidingEnabled) == nil {
                self.isMainBarHidingEnabled = true
            } else {
                self.isMainBarHidingEnabled = UserDefaults.standard.bool(forKey: Keys.hidingEnabled)
            }

            if UserDefaults.standard.object(forKey: Keys.autoHideSeconds) == nil {
                self.autoHideDuration = .fiveSeconds
            } else {
                let raw = UserDefaults.standard.integer(forKey: Keys.autoHideSeconds)
                self.autoHideDuration = AutoHideDuration(rawValue: raw) ?? .fiveSeconds
            }

            if UserDefaults.standard.object(forKey: Keys.showSelectionOnLaunch) == nil {
                self.showSelectionOnLaunch = true
            } else {
                self.showSelectionOnLaunch = UserDefaults.standard.bool(forKey: Keys.showSelectionOnLaunch)
            }

            if UserDefaults.standard.object(forKey: Keys.hideFromDock) == nil {
                self.hideFromDock = false
            } else {
                self.hideFromDock = UserDefaults.standard.bool(forKey: Keys.hideFromDock)
            }

            let initialSnapshot = makePersistedSnapshot()
            persistenceQueue.async {
                if let encoded = try? JSONEncoder().encode(initialSnapshot) {
                    try? encoded.write(to: fileURL, options: .atomic)
                }
            }
        }
    }

    // MARK: - Lifecycle Setup

    func start() {
        syncLaunchAtLoginStatusFromSystem()
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

                guard trusted, !self.isPerformingHIDSequence, !self.isArrangingMenuBar, !self.isExecutingNativeSync else { return }
                let now = CFAbsoluteTimeGetCurrent()
                // Never run background AX polling within 4s of user clicks/drags so UI stays 120fps smooth
                guard (now - self.lastUserInteractionTime) >= 4.0 else { return }
                if (now - self.lastBackgroundScanTime) >= 12.0 {
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
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        if let mon = statusItemScrollMonitor {
            NSEvent.removeMonitor(mon)
            statusItemScrollMonitor = nil
        }
        let finalSnapshot = makePersistedSnapshot()
        let url = stateFileURL
        persistenceQueue.sync {
            if let encoded = try? JSONEncoder().encode(finalSnapshot) {
                try? encoded.write(to: url, options: .atomic)
            }
        }
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

    // MARK: - Launch at Login (`SMAppService.mainApp`)

    private func syncLaunchAtLoginStatusFromSystem() {
        let currentStatus = SMAppService.mainApp.status
        let actualEnabled = (currentStatus == .enabled)
        if launchAtLogin != actualEnabled {
            if launchAtLogin && currentStatus == .notRegistered {
                try? SMAppService.mainApp.register()
            }
            let refreshed = (SMAppService.mainApp.status == .enabled)
            isUpdatingLaunchAtLoginInternally = true
            launchAtLogin = refreshed
            isUpdatingLaunchAtLoginInternally = false
        }
    }

    private func applyLaunchAtLoginChange() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    statusMessage = "Hãy bật cho phép BarFlow trong System Settings → General → Login Items."
                    SMAppService.openSystemSettingsLoginItems()
                } else {
                    statusMessage = "Đã bật Tự động khởi động cùng macOS!"
                }
            } else {
                try SMAppService.mainApp.unregister()
                statusMessage = "Đã tắt Tự động khởi động cùng macOS."
            }
        } catch {
            statusMessage = "Không thể cập nhật Khởi động cùng macOS: \(error.localizedDescription)"
            isUpdatingLaunchAtLoginInternally = true
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
            isUpdatingLaunchAtLoginInternally = false
        }
    }

    // MARK: - Status Items (Main Toggle + Hover/Scroll Triggers + Invisible Multi-Spacers)

    private func setupStatusItems() {
        guard mainStatusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "BarFlow.MainToggle"
        if let button = item.button {
            button.setAccessibilityIdentifier("BarFlow.MainToggle")
            updateMainButtonAppearance(isSecondaryOpen: false)
            button.target = self
            button.action = #selector(handleMainStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            let hoverOverlay = StatusButtonHoverOverlayView(frame: button.bounds)
            hoverOverlay.autoresizingMask = [.width, .height]
            button.addSubview(hoverOverlay)
        }
        self.mainStatusItem = item
        refreshMainStatusItemToolTip()
        installStatusItemScrollMonitorIfNeeded()

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

    func refreshMainStatusItemToolTip() {
        guard let button = mainStatusItem?.button else { return }
        let hoverNote = hoverToOpenEnabled ? " • Rê chuột / cuộn để mở nhanh" : " • Cuộn chuột để mở/đóng nhanh"
        button.toolTip = "BarFlow — Click trái (hoặc \(hotKeyBinding.readableDisplay)) để hiện/ẩn thanh phụ\(hoverNote) • Click phải để mở tuỳ chọn"
    }

    private func installStatusItemScrollMonitorIfNeeded() {
        guard statusItemScrollMonitor == nil else { return }
        statusItemScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self,
                  let btnWin = self.mainStatusItem?.button?.window,
                  event.window === btnWin else {
                return event
            }
            let now = CFAbsoluteTimeGetCurrent()
            guard (now - self.lastScrollTriggerTime) >= 0.22 else { return event }

            let dy = event.scrollingDeltaY
            let dx = event.scrollingDeltaX
            if dy < -1.2 || abs(dx) > 2.5 {
                if !SecondaryBarController.shared.isVisible {
                    self.lastScrollTriggerTime = now
                    SecondaryBarController.shared.show()
                }
            } else if dy > 1.2 {
                if SecondaryBarController.shared.isVisible {
                    self.lastScrollTriggerTime = now
                    SecondaryBarController.shared.hide()
                }
            }
            return event
        }
    }

    @objc private func handleMainStatusItemClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            SecondaryBarController.shared.handleStatusIconToggleClick()
            return
        }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showQuickContextMenu(from: sender)
        } else {
            SecondaryBarController.shared.handleStatusIconToggleClick()
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
        let ver = UpdateCheckerService.shared.currentVersion

        let header = NSMenuItem(title: "BarFlow v\(ver) — Quản lý Menu Bar", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let toggleBar = NSMenuItem(
            title: "Hiện / Ẩn thanh ứng dụng phụ (\(hotKeyBinding.readableDisplay))",
            action: #selector(menuToggleSecondaryBar),
            keyEquivalent: hotKeyBinding.menuKeyEquivalent
        )
        if !hotKeyBinding.menuKeyEquivalent.isEmpty {
            toggleBar.keyEquivalentModifierMask = hotKeyBinding.appKitModifierFlags
        }
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

        let hoverToggle = NSMenuItem(
            title: "Rê chuột vào ••• để mở thanh phụ",
            action: #selector(menuToggleHoverToOpen),
            keyEquivalent: ""
        )
        hoverToggle.state = hoverToOpenEnabled ? .on : .off
        hoverToggle.target = self
        menu.addItem(hoverToggle)

        let loginToggle = NSMenuItem(
            title: "Khởi động cùng macOS",
            action: #selector(menuToggleLaunchAtLogin),
            keyEquivalent: ""
        )
        loginToggle.state = launchAtLogin ? .on : .off
        loginToggle.target = self
        menu.addItem(loginToggle)

        menu.addItem(.separator())

        if case let .available(newVer, _, _) = UpdateCheckerService.shared.state {
            let installUpdate = NSMenuItem(
                title: "Cập nhật ngay lên BarFlow v\(newVer)...",
                action: #selector(menuInstallAvailableUpdate),
                keyEquivalent: ""
            )
            installUpdate.target = self
            menu.addItem(installUpdate)
        } else {
            let checkUpdate = NSMenuItem(
                title: "Kiểm tra cập nhật...",
                action: #selector(menuCheckForUpdates),
                keyEquivalent: ""
            )
            checkUpdate.target = self
            menu.addItem(checkUpdate)
        }

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

    @objc private func menuToggleHoverToOpen() {
        hoverToOpenEnabled.toggle()
    }

    @objc private func menuToggleLaunchAtLogin() {
        launchAtLogin.toggle()
    }

    @objc private func menuCheckForUpdates() {
        onOpenSelectionWindowRequested?()
        UpdateCheckerService.shared.checkForUpdatesManually()
    }

    @objc private func menuInstallAvailableUpdate() {
        UpdateCheckerService.shared.installAvailableUpdate()
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

    // MARK: - Non-Blocking Scanning, Instant Selection & Custom Ordering (Main + Secondary Bars)

    func markUserInteraction() {
        lastUserInteractionTime = CFAbsoluteTimeGetCurrent()
    }

    private func makePersistedSnapshot() -> PersistedLayoutState {
        PersistedLayoutState(
            initialized: hasInitializedSelectionFlag,
            selectedMainBarIDs: Array(selectedMainBarIDs),
            mainBarOrderIDs: mainBarOrderIDs,
            secondaryBarOrderIDs: secondaryBarOrderIDs,
            allAppsOrderIDs: allAppsOrderIDs,
            hidingEnabled: isMainBarHidingEnabled,
            autoHideSeconds: autoHideDuration.rawValue,
            showSelectionOnLaunch: showSelectionOnLaunch,
            hideFromDock: hideFromDock,
            hotKeyBinding: hotKeyBinding,
            hoverToOpenEnabled: hoverToOpenEnabled,
            launchAtLogin: launchAtLogin
        )
    }

    private func scheduleSaveState() {
        pendingSaveWorkItem?.cancel()
        let snapshot = makePersistedSnapshot()
        let url = stateFileURL
        let work = DispatchWorkItem {
            if let encoded = try? JSONEncoder().encode(snapshot) {
                try? encoded.write(to: url, options: .atomic)
            }
        }
        pendingSaveWorkItem = work
        persistenceQueue.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Recomputes `mainBarApps`, `secondaryBarApps`, and `stableAllApps` in a single O(N) pass (< 0.02ms)
    /// while preserving exact Left -> Right user ordering across toggles and app restarts.
    private func rebuildDerivedLists() {
        var byID: [String: MenuBarAppItem] = [:]
        byID.reserveCapacity(allRunningApps.count)
        for app in allRunningApps where byID[app.id] == nil {
            byID[app.id] = app
        }

        // 1. Ensure newly discovered apps are appended into order lists without disturbing existing custom order
        var mainSet = Set(mainBarOrderIDs)
        var secSet = Set(secondaryBarOrderIDs)
        var allSet = Set(allAppsOrderIDs)
        var ordersMutated = false

        for app in allRunningApps {
            if allSet.insert(app.id).inserted {
                allAppsOrderIDs.append(app.id)
                ordersMutated = true
            }
            if selectedMainBarIDs.contains(app.id) {
                if mainSet.insert(app.id).inserted {
                    mainBarOrderIDs.append(app.id)
                    ordersMutated = true
                }
            } else {
                if secSet.insert(app.id).inserted {
                    secondaryBarOrderIDs.append(app.id)
                    ordersMutated = true
                }
            }
        }

        // 2. Build ordered Main Bar list (Left -> Right)
        var newMain: [MenuBarAppItem] = []
        newMain.reserveCapacity(selectedMainBarIDs.count)
        var seenMain = Set<String>()
        for id in mainBarOrderIDs where selectedMainBarIDs.contains(id) {
            if let item = byID[id], seenMain.insert(id).inserted {
                newMain.append(item)
            }
        }

        // 3. Build ordered Secondary Bar list (Left -> Right)
        var newSecondary: [MenuBarAppItem] = []
        newSecondary.reserveCapacity(max(0, allRunningApps.count - newMain.count))
        var seenSec = Set<String>()
        for id in secondaryBarOrderIDs where !selectedMainBarIDs.contains(id) {
            if let item = byID[id], seenSec.insert(id).inserted {
                newSecondary.append(item)
            }
        }

        // 4. Build stable "Tất cả" list (never jumps when toggling switches!)
        var newStableAll: [MenuBarAppItem] = []
        newStableAll.reserveCapacity(allRunningApps.count)
        var seenAll = Set<String>()
        for id in allAppsOrderIDs {
            if let item = byID[id], seenAll.insert(id).inserted {
                newStableAll.append(item)
            }
        }

        if mainBarApps != newMain {
            mainBarApps = newMain
        }
        if secondaryBarApps != newSecondary {
            secondaryBarApps = newSecondary
        }
        if stableAllApps != newStableAll {
            stableAllApps = newStableAll
        }
        if ordersMutated {
            scheduleSaveState()
        }
    }

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

            if initializeDefaultsIfNeeded && !self.hasInitializedSelectionFlag && !scannedApps.isEmpty {
                var initialIDs = Set<String>()
                var initialMainOrder: [String] = []
                var initialSecOrder: [String] = []
                var nonSystemCount = 0
                for app in scannedApps {
                    if app.isSystemItem {
                        initialIDs.insert(app.id)
                        initialMainOrder.append(app.id)
                    } else if nonSystemCount < 5 {
                        initialIDs.insert(app.id)
                        initialMainOrder.append(app.id)
                        nonSystemCount += 1
                    } else {
                        initialSecOrder.append(app.id)
                    }
                }
                self.hasInitializedSelectionFlag = true
                self.hasPerformedStartupVisibilitySync = true
                self.mainBarOrderIDs = initialMainOrder
                self.secondaryBarOrderIDs = initialSecOrder
                self.selectedMainBarIDs = initialIDs
                self.rebuildDerivedLists()
                self.scheduleSaveState()
                if self.isMainBarHidingEnabled {
                    self.scheduleNativeMenuBarSync(delay: 0.25)
                }
            } else {
                self.rebuildDerivedLists()
                if !self.hasPerformedStartupVisibilitySync && !scannedApps.isEmpty {
                    self.hasPerformedStartupVisibilitySync = true
                    if self.isMainBarHidingEnabled {
                        self.scheduleNativeMenuBarSync(delay: 0.30)
                    }
                } else if newUnselectedLaunched && self.isMainBarHidingEnabled {
                    self.scheduleNativeMenuBarSync(delay: 0.45)
                }
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
        setAppSelection(item, visibleOnMainBar: !selectedMainBarIDs.contains(item.id))
    }

    func setAppSelection(_ item: MenuBarAppItem, visibleOnMainBar: Bool, insertBeforeID: String? = nil) {
        let currentlySelected = selectedMainBarIDs.contains(item.id)
        if visibleOnMainBar {
            guard !currentlySelected || insertBeforeID != nil else { return }
            selectedMainBarIDs.insert(item.id)
            mainBarOrderIDs.removeAll { $0 == item.id }
            if let beforeID = insertBeforeID, let idx = mainBarOrderIDs.firstIndex(of: beforeID) {
                mainBarOrderIDs.insert(item.id, at: idx)
            } else {
                mainBarOrderIDs.append(item.id)
            }
        } else {
            guard currentlySelected || insertBeforeID != nil else { return }
            selectedMainBarIDs.remove(item.id)
            secondaryBarOrderIDs.removeAll { $0 == item.id }
            if let beforeID = insertBeforeID, let idx = secondaryBarOrderIDs.firstIndex(of: beforeID) {
                secondaryBarOrderIDs.insert(item.id, at: idx)
            } else {
                secondaryBarOrderIDs.insert(item.id, at: 0)
            }
        }

        markUserInteraction()
        rebuildDerivedLists()
        scheduleSaveState()
        onSecondaryAppsChanged?()
        if !allRunningApps.isEmpty {
            scheduleNativeMenuBarSync(delay: 0.16)
        }
    }

    func selectAllForMainBar() {
        let allIDs = allRunningApps.map(\.id)
        guard selectedMainBarIDs.count != allIDs.count else { return }
        for item in secondaryBarApps where !mainBarOrderIDs.contains(item.id) {
            mainBarOrderIDs.append(item.id)
        }
        selectedMainBarIDs = Set(allIDs)
        markUserInteraction()
        rebuildDerivedLists()
        scheduleSaveState()
        onSecondaryAppsChanged?()
        if !allRunningApps.isEmpty {
            scheduleNativeMenuBarSync(delay: 0.16)
        }
    }

    func moveAllToSecondaryBar() {
        guard !selectedMainBarIDs.isEmpty else { return }
        for item in mainBarApps.reversed() {
            secondaryBarOrderIDs.removeAll { $0 == item.id }
            secondaryBarOrderIDs.insert(item.id, at: 0)
        }
        selectedMainBarIDs = []
        markUserInteraction()
        rebuildDerivedLists()
        scheduleSaveState()
        onSecondaryAppsChanged?()
        if !allRunningApps.isEmpty {
            scheduleNativeMenuBarSync(delay: 0.16)
        }
    }

    func deselectAllNonSystemForMainBar() {
        selectedMainBarIDs = Set(allRunningApps.filter(\.isSystemItem).map(\.id))
        markUserInteraction()
        rebuildDerivedLists()
        scheduleSaveState()
        onSecondaryAppsChanged?()
        if !allRunningApps.isEmpty {
            scheduleNativeMenuBarSync(delay: 0.16)
        }
    }

    // MARK: - Live Custom Reordering (Main Menu Bar & Secondary `Ctrl + B` Bar)

    func beginDraggingItem(_ id: String) {
        markUserInteraction()
        if draggingItemID != id {
            draggingItemID = id
        }
        dragEndWatchdogTimer?.invalidate()
        dragEndWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self else {
                    timer.invalidate()
                    return
                }
                if (NSEvent.pressedMouseButtons & 1) == 0 {
                    timer.invalidate()
                    self.endDraggingSession()
                }
            }
        }
    }

    func endDraggingSession() {
        dragEndWatchdogTimer?.invalidate()
        dragEndWatchdogTimer = nil
        if draggingItemID != nil {
            draggingItemID = nil
        }
        if needsNativeSyncAfterDragEnd {
            needsNativeSyncAfterDragEnd = false
            scheduleNativeMenuBarSync(delay: 0.08)
        }
    }

    /// Reorders an item on the Main Menu Bar (or transfers a Secondary Bar item directly onto a Main Bar slot).
    func reorderMainBarItem(draggedID: String, targetID: String) {
        guard draggedID != targetID else { return }
        var activeIDs = mainBarApps.map(\.id)
        let wasCrossZone = !selectedMainBarIDs.contains(draggedID)

        if wasCrossZone {
            selectedMainBarIDs.insert(draggedID)
            if let targetIdx = activeIDs.firstIndex(of: targetID) {
                activeIDs.insert(draggedID, at: targetIdx)
            } else {
                activeIDs.append(draggedID)
            }
        } else {
            guard let fromIdx = activeIDs.firstIndex(of: draggedID),
                  let toIdx = activeIDs.firstIndex(of: targetID),
                  fromIdx != toIdx else { return }
            let moved = activeIDs.remove(at: fromIdx)
            activeIDs.insert(moved, at: toIdx)
        }

        // Preserve non-running saved IDs after active running IDs
        let activeSet = Set(activeIDs)
        let offlineSaved = mainBarOrderIDs.filter { !activeSet.contains($0) }
        mainBarOrderIDs = activeIDs + offlineSaved

        markUserInteraction()
        rebuildDerivedLists()
        scheduleSaveState()
        if wasCrossZone {
            onSecondaryAppsChanged?()
        }
        scheduleNativeMenuBarSync(delay: 0.22)
    }

    /// Moves a Main Menu Bar item one step Left (`direction = -1`) or Right (`direction = +1`).
    func moveMainBarItem(id: String, direction: Int) {
        var activeIDs = mainBarApps.map(\.id)
        guard let idx = activeIDs.firstIndex(of: id) else { return }
        let newIdx = idx + direction
        guard newIdx >= 0 && newIdx < activeIDs.count else { return }
        activeIDs.swapAt(idx, newIdx)

        let activeSet = Set(activeIDs)
        mainBarOrderIDs = activeIDs + mainBarOrderIDs.filter { !activeSet.contains($0) }

        markUserInteraction()
        rebuildDerivedLists()
        scheduleSaveState()
        scheduleNativeMenuBarSync(delay: 0.20)
    }

    /// Moves a Main Menu Bar item to the far Left (`toStart = true`) or far Right (`toStart = false`).
    func moveMainBarItemToEdge(id: String, toStart: Bool) {
        var activeIDs = mainBarApps.map(\.id)
        guard let idx = activeIDs.firstIndex(of: id) else { return }
        let targetIdx = toStart ? 0 : (activeIDs.count - 1)
        guard idx != targetIdx else { return }
        let moved = activeIDs.remove(at: idx)
        activeIDs.insert(moved, at: targetIdx)

        let activeSet = Set(activeIDs)
        mainBarOrderIDs = activeIDs + mainBarOrderIDs.filter { !activeSet.contains($0) }

        markUserInteraction()
        rebuildDerivedLists()
        scheduleSaveState()
        scheduleNativeMenuBarSync(delay: 0.20)
    }

    /// Reorders an item in the `Ctrl + B` Secondary Bar (0ms instant update — zero MenuBarAgent reload unless cross-zone!).
    func reorderSecondaryBarItem(draggedID: String, targetID: String) {
        guard draggedID != targetID else { return }
        var activeIDs = secondaryBarApps.map(\.id)
        let wasCrossZone = selectedMainBarIDs.contains(draggedID)

        if wasCrossZone {
            selectedMainBarIDs.remove(draggedID)
            if let targetIdx = activeIDs.firstIndex(of: targetID) {
                activeIDs.insert(draggedID, at: targetIdx)
            } else {
                activeIDs.append(draggedID)
            }
        } else {
            guard let fromIdx = activeIDs.firstIndex(of: draggedID),
                  let toIdx = activeIDs.firstIndex(of: targetID),
                  fromIdx != toIdx else { return }
            let moved = activeIDs.remove(at: fromIdx)
            activeIDs.insert(moved, at: toIdx)
        }

        let activeSet = Set(activeIDs)
        let offlineSaved = secondaryBarOrderIDs.filter { !activeSet.contains($0) }
        secondaryBarOrderIDs = activeIDs + offlineSaved

        markUserInteraction()
        rebuildDerivedLists()
        scheduleSaveState()
        if wasCrossZone {
            onSecondaryAppsChanged?()
            scheduleNativeMenuBarSync(delay: 0.18)
        }
    }

    /// Moves a Secondary Bar (`Ctrl + B`) item one step Left (`direction = -1`) or Right (`direction = +1`) in 0ms!
    func moveSecondaryBarItem(id: String, direction: Int) {
        var activeIDs = secondaryBarApps.map(\.id)
        guard let idx = activeIDs.firstIndex(of: id) else { return }
        let newIdx = idx + direction
        guard newIdx >= 0 && newIdx < activeIDs.count else { return }
        activeIDs.swapAt(idx, newIdx)

        let activeSet = Set(activeIDs)
        secondaryBarOrderIDs = activeIDs + secondaryBarOrderIDs.filter { !activeSet.contains($0) }

        markUserInteraction()
        rebuildDerivedLists()
        scheduleSaveState()
    }

    /// Moves a Secondary Bar (`Ctrl + B`) item to the far Left (`toStart = true`) or far Right (`toStart = false`) in 0ms!
    func moveSecondaryBarItemToEdge(id: String, toStart: Bool) {
        var activeIDs = secondaryBarApps.map(\.id)
        guard let idx = activeIDs.firstIndex(of: id) else { return }
        let targetIdx = toStart ? 0 : (activeIDs.count - 1)
        guard idx != targetIdx else { return }
        let moved = activeIDs.remove(at: idx)
        activeIDs.insert(moved, at: targetIdx)

        let activeSet = Set(activeIDs)
        secondaryBarOrderIDs = activeIDs + secondaryBarOrderIDs.filter { !activeSet.contains($0) }

        markUserInteraction()
        rebuildDerivedLists()
        scheduleSaveState()
    }

    /// Handles dropping an item onto an empty zone (Zone A = Main Bar, Zone B = Secondary Bar).
    func dropItemIntoZone(draggedID: String, toMainBar: Bool) {
        guard let item = allRunningApps.first(where: { $0.id == draggedID }) else { return }
        if toMainBar && !selectedMainBarIDs.contains(draggedID) {
            setAppSelection(item, visibleOnMainBar: true)
        } else if !toMainBar && selectedMainBarIDs.contains(draggedID) {
            setAppSelection(item, visibleOnMainBar: false)
        }
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
            self.rebuildDerivedLists()
            self.onSecondaryAppsChanged?()

            if self.requiresFullDiskAccess && !self.isFullDiskAccessGranted {
                self.statusMessage = "Đã quét \(scanned.count) biểu tượng. Hãy cấp thêm quyền Full Disk Access ở khung phía trên để ẩn khỏi Menu Bar chính."
                return
            }

            if self.isMainBarHidingEnabled && self.requiresFullDiskAccess {
                let anyUnselectedStillVisible = self.secondaryBarApps.contains(where: \.isCurrentlyOnBar)
                if anyUnselectedStillVisible {
                    await self.executeNativeMenuBarSync(forceReload: true, isManualTrigger: true)
                    return
                }
            }
            self.statusMessage = "Đã làm mới danh sách (\(scanned.count) biểu tượng đang chạy)."
        }
    }

    // MARK: - Native MenuBarAgent Visibility & Order Sync (macOS 26/27+) & Legacy ⌘-Drag Fallback

    private func scheduleNativeMenuBarSync(delay: TimeInterval) {
        guard MenuBarVisibilityEngine.shared.usesMenuBarAgentArchitecture else { return }
        guard MenuBarVisibilityEngine.shared.hasFullDiskAccess else {
            isFullDiskAccessGranted = false
            return
        }
        nativeSyncDebounceWorkItem?.cancel()
        if draggingItemID != nil {
            needsNativeSyncAfterDragEnd = true
            return
        }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                await self?.executeNativeMenuBarSync(forceReload: false, isManualTrigger: false)
            }
        }
        nativeSyncDebounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Updates `isCurrentlyOnBar` optimistically in memory (0.02ms) so UI never stalls or jumps waiting for an AX rescan!
    private func applyOptimisticBarResidency(selectedIDs: Set<String>, hidingEnabled: Bool) {
        var changed = false
        var updated = allRunningApps
        for i in updated.indices {
            let shouldBeOnBar = !hidingEnabled || selectedIDs.contains(updated[i].id)
            if updated[i].isCurrentlyOnBar != shouldBeOnBar {
                updated[i].isCurrentlyOnBar = shouldBeOnBar
                changed = true
            }
        }
        if changed {
            allRunningApps = updated
            rebuildDerivedLists()
        }
    }

    private func executeNativeMenuBarSync(forceReload: Bool = false, isManualTrigger: Bool = false) async {
        guard MenuBarVisibilityEngine.shared.usesMenuBarAgentArchitecture else { return }
        refreshPermissionsState()

        guard isAccessibilityGranted else {
            if isManualTrigger {
                statusMessage = "Vui lòng cấp quyền Trợ năng (Accessibility) ở khung phía trên trước khi áp dụng."
            }
            return
        }
        guard isFullDiskAccessGranted else {
            if isManualTrigger {
                statusMessage = "Chưa có quyền Full Disk Access — hãy bấm nút 'Cấp quyền Full Disk Access' ở khung hướng dẫn phía trên."
            }
            return
        }
        guard !allRunningApps.isEmpty else { return }

        if isExecutingNativeSync {
            hasQueuedFollowUpNativeSync = true
            return
        }

        isExecutingNativeSync = true
        if isManualTrigger {
            isArrangingMenuBar = true
        }
        deferredReloadTimer?.invalidate()
        deferredReloadTimer = nil

        let appsSnapshot = allRunningApps
        let selectedSnapshot = selectedMainBarIDs
        let orderedMainSnapshot = mainBarApps.map(\.id)
        let hidingSnapshot = isMainBarHidingEnabled

        let outcome = await MenuBarVisibilityEngine.shared.syncMenuBarState(
            allApps: appsSnapshot,
            selectedMainBarIDs: selectedSnapshot,
            orderedMainBarIDs: orderedMainSnapshot,
            hidingEnabled: hidingSnapshot,
            forceReload: forceReload
        )

        isExecutingNativeSync = false

        if hasQueuedFollowUpNativeSync {
            hasQueuedFollowUpNativeSync = false
            await executeNativeMenuBarSync(forceReload: forceReload, isManualTrigger: isManualTrigger)
            return
        }

        if let err = outcome.errorReason {
            if isArrangingMenuBar { isArrangingMenuBar = false }
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
            if isArrangingMenuBar { isArrangingMenuBar = false }
            let secs = max(1, Int(ceil(waitSec)))
            statusMessage = "Đã lưu thứ tự & chọn lọc — Menu Bar cập nhật sau ~\(secs)s (tránh trễ tiến trình hệ thống)..."
            scheduleDeferredMenuBarAgentReload(after: waitSec + 0.10, hiddenCount: outcome.hiddenCount)
            return
        }

        if isArrangingMenuBar {
            isArrangingMenuBar = false
        }
        if outcome.didReloadAgent || outcome.didModifyPreferences {
            applyOptimisticBarResidency(selectedIDs: selectedSnapshot, hidingEnabled: hidingSnapshot)
            if hidingSnapshot {
                let nextMsg = outcome.hiddenCount > 0
                    ? "Đã đồng bộ Menu Bar chính (giữ \(outcome.visibleCount) • ẩn \(outcome.hiddenCount) vào Ctrl + B)"
                    : "Đã đồng bộ thứ tự trên Menu Bar chính!"
                if statusMessage != nextMsg { statusMessage = nextMsg }
            } else {
                let nextMsg = "Đã tạm tắt ẩn — toàn bộ ứng dụng đang hiện trên Menu Bar chính."
                if statusMessage != nextMsg { statusMessage = nextMsg }
            }
        } else if forceReload {
            let countNow = secondaryBarApps.count
            statusMessage = (hidingSnapshot && countNow > 0)
                ? "Menu Bar chính đã khớp thứ tự & đang ẩn \(countNow) ứng dụng vào Ctrl + B!"
                : "Menu Bar chính đã khớp thứ tự chọn lọc!"
        }
    }

    private func scheduleDeferredMenuBarAgentReload(after delay: TimeInterval, hiddenCount: Int) {
        deferredReloadTimer?.invalidate()
        deferredReloadTimer = Timer.scheduledTimer(withTimeInterval: max(0.2, delay), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if let stillRemaining = await MenuBarVisibilityEngine.shared.performDeferredReloadIfReady() {
                    self.scheduleDeferredMenuBarAgentReload(after: stillRemaining + 0.12, hiddenCount: hiddenCount)
                    return
                }
                if self.isArrangingMenuBar {
                    self.isArrangingMenuBar = false
                }
                self.applyOptimisticBarResidency(selectedIDs: self.selectedMainBarIDs, hidingEnabled: self.isMainBarHidingEnabled)
                if self.isMainBarHidingEnabled {
                    let countNow = self.secondaryBarApps.count
                    self.statusMessage = countNow > 0
                        ? "Đã đồng bộ Menu Bar chính (giữ \(self.mainBarApps.count) • ẩn \(countNow) vào Ctrl + B)"
                        : "Đã đồng bộ thứ tự trên Menu Bar chính!"
                } else {
                    self.statusMessage = "Đã hiển thị toàn bộ ứng dụng lên Menu Bar chính!"
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
            statusMessage = "Đang áp dụng chọn lọc & thứ tự lên Menu Bar chính..."
            await executeNativeMenuBarSync(forceReload: true, isManualTrigger: true)
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

    // MARK: - Instant App Activation from `Ctrl + B` Secondary Bar (Anchored Right Under Clicked Icon!)

    private enum HiddenInteractionResult: Sendable {
        case mirroredMenu(AXStatusMenuBridge.MirroredMenuSnapshot)
        case synthesizedAppMenu(AXStatusMenuBridge.MirroredMenuSnapshot?)
        case openedPopoverWindow
        case needsReopenOrMenuFallback(AXStatusMenuBridge.MirroredMenuSnapshot?)
        case triggeredActionOnly
        case fallbackSystemItem
    }

    private final class OnceContinuationGate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?

        init(_ continuation: CheckedContinuation<T, Never>) {
            self.continuation = continuation
        }

        func resume(returning value: T) {
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(returning: value)
        }
    }

    /// Invoked when the user left-clicks or right-clicks an app icon inside the floating `Ctrl + B` Secondary Bar.
    func activateAppFromSecondaryBar(
        _ item: MenuBarAppItem,
        rightClick: Bool = false,
        anchorScreenRectAppKit: NSRect? = nil,
        anchorView: NSView? = nil
    ) {
        markUserInteraction()
        SecondaryBarController.shared.notifyUserInteraction()
        Task { @MainActor in
            await performHiddenAppInteraction(
                item,
                rightClick: rightClick,
                anchorScreenRectAppKit: anchorScreenRectAppKit,
                anchorView: anchorView
            )
        }
    }

    private func performHiddenAppInteraction(
        _ item: MenuBarAppItem,
        rightClick: Bool,
        anchorScreenRectAppKit: NSRect?,
        anchorView: NSView?
    ) async {
        let now = CFAbsoluteTimeGetCurrent()
        if isPerformingHIDSequence && (now - activeProbeStartedAt) < 0.85 {
            return
        }

        // Pure system modules hosted inside ControlCenter (`pid == 0`, e.g. Wi-Fi, Battery, Screen Mirroring, Spotlight)
        if MenuBarVisibilityEngine.shared.usesMenuBarAgentArchitecture && item.pid == 0 {
            onHideSecondaryBarRequested?()
            MenuBarVisibilityEngine.shared.triggerHiddenSystemItem(item, rightClick: rightClick)
            return
        }

        isPerformingHIDSequence = true
        activeProbeStartedAt = now

        let displays = MenuBarScanner.captureDisplayGeometries()
        let windowsBefore = currentOnScreenWindows(for: item.pid)
        var collapsedSpacersTemporarily = false

        // Legacy macOS 14/15 spacer collapse fallback
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
                onHideSecondaryBarRequested?()
                isTemporarilyRevealedForClick = true
                collapsedSpacersTemporarily = true
                setSpacersExpanded(false)
                try? await Task.sleep(nanoseconds: 75_000_000)
            }
        }

        let targetPID = item.pid
        let savedCursor = currentMouseCGLocation()
        let anchorRectCG: CGRect = {
            if let nsRect = anchorScreenRectAppKit, nsRect.width > 0 {
                return MenuBarScanner.appKitToCGRect(nsRect)
            }
            return CGRect(x: savedCursor.x - 14, y: savedCursor.y - 14, width: 28, height: 28)
        }()
        let anchorDisplay = displays.first(where: {
            $0.cgFrame.insetBy(dx: -4, dy: -4).contains(CGPoint(x: anchorRectCG.midX, y: anchorRectCG.midY))
        }) ?? MenuBarScanner.displayGeometryContainingMouse()
        let anchorDisplayCG = anchorDisplay?.cgFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let usesAgentArch = MenuBarVisibilityEngine.shared.usesMenuBarAgentArchitecture

        let interactionResult = await withCheckedContinuation { (continuation: CheckedContinuation<HiddenInteractionResult, Never>) in
            let gate = OnceContinuationGate(continuation)

            // Hard 0.85s watchdog so a beachballing / hung app can NEVER block BarFlow or subsequent icon clicks!
            interactionQueue.asyncAfter(deadline: .now() + 0.85) {
                let fallback: HiddenInteractionResult = rightClick
                    ? .synthesizedAppMenu(nil)
                    : .needsReopenOrMenuFallback(nil)
                gate.resume(returning: fallback)
            }

            interactionQueue.async { [weak self] in
                guard let self = self else {
                    gate.resume(returning: .triggeredActionOnly)
                    return
                }

                let live = MenuBarScanner.shared.liveStatusElement(
                    for: item,
                    preferredDisplay: anchorDisplay,
                    timeout: 0.20
                )
                guard let axEl = live?.element ?? item.axElement else {
                    if item.isSystemItem && usesAgentArch {
                        gate.resume(returning: .fallbackSystemItem)
                    } else if rightClick {
                        let appMenu = AXStatusMenuBridge.shared.captureApplicationMenuSnapshot(forPID: targetPID)
                        gate.resume(returning: .synthesizedAppMenu(appMenu))
                    } else {
                        let appMenu = AXStatusMenuBridge.shared.captureApplicationMenuSnapshot(forPID: targetPID)
                        gate.resume(returning: .needsReopenOrMenuFallback(appMenu))
                    }
                    return
                }

                AXUIElementSetMessagingTimeout(axEl, 0.16)

                // STEP 1: Fast path — if the status item exposes an attached `AXMenu` (MKey/OpenKey, Alfred, QuickFolder,
                // Moom, AnyDesk, Yoink, Typinator, Default Folder X, TextInputMenuAgent, etc.), mirror & pop its 1st level
                // pixel-perfectly right underneath the clicked icon in < 10ms with lazy on-demand `NSMenuDelegate` submenus!
                if let snapshot = AXStatusMenuBridge.shared.captureMenuSnapshot(from: axEl, cancelSourceMenuAfterRead: false) {
                    gate.resume(returning: .mirroredMenu(snapshot))
                    return
                }

                // STEP 2: Dedicated RIGHT-CLICK path for apps without a status-item `AXMenu`
                // (`1Password 7`, `OneDrive`, `Google Drive`, `Dropbox`, `Caffeine`, `Maccy`, `Claude`, `Itsycal`):
                // Never trigger Left-Click `AXPress` on Right-Click — otherwise 1Password re-opens its vault window instead
                // of showing its Application Menu (`Settings…`, `Lock`, `Quit` / `Thoát`)!
                if rightClick {
                    var actionsRef: CFArray?
                    let actions: [String] = (AXUIElementCopyActionNames(axEl, &actionsRef) == .success)
                        ? ((actionsRef as? [String]) ?? [])
                        : []
                    if let menuAction = actions.first(where: { $0 == "AXShowMenu" || $0 == "AXSecondaryMenu" }) {
                        let rc = AXUIElementPerformAction(axEl, menuAction as CFString)
                        if rc == .success || rc == .cannotComplete {
                            for waitUs: useconds_t in [15_000, 30_000, 45_000] {
                                usleep(waitUs)
                                if let dynMenu = AXStatusMenuBridge.shared.captureMenuSnapshot(from: axEl, cancelSourceMenuAfterRead: true) {
                                    gate.resume(returning: .mirroredMenu(dynMenu))
                                    return
                                }
                            }
                        }
                    }

                    let appMenuSnap = AXStatusMenuBridge.shared.captureApplicationMenuSnapshot(forPID: targetPID)
                    gate.resume(returning: .synthesizedAppMenu(appMenuSnap))
                    return
                }

                // STEP 3: LEFT-CLICK path — snapshot existing AXWindows & status label BEFORE `AXPress`
                let axApp = AXUIElementCreateApplication(targetPID)
                AXUIElementSetMessagingTimeout(axApp, 0.18)
                let baselineAXWins = self.readAXWindows(of: axApp)
                let beforeLabel = self.readStatusElementLabelFingerprint(axEl)

                var actionErr = AXUIElementPerformAction(axEl, kAXPressAction as CFString)
                if actionErr != .success && actionErr != .cannotComplete {
                    var childrenRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(axEl, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                       let children = childrenRef as? [AXUIElement],
                       let childButton = children.first {
                        AXUIElementSetMessagingTimeout(childButton, 0.16)
                        actionErr = AXUIElementPerformAction(childButton, kAXPressAction as CFString)
                    }
                }

                // Legacy macOS 14/15 physical slot click fallback ONLY when item is physically visible on the Menu Bar
                if actionErr != .success && actionErr != .cannotComplete && !usesAgentArch && item.isCurrentlyOnBar,
                   let rect = live?.frame ?? MenuBarScanner.shared.readAXFrame(axEl), rect.width > 0 {
                    self.postWarpedHIDClickSync(
                        at: CGPoint(x: rect.midX, y: rect.midY),
                        button: .left,
                        savedCursor: savedCursor
                    )
                    actionErr = .success
                }

                // STEP 4: Poll briefly (15ms..120ms) to catch either:
                //   (a) a dynamically attached `AXMenu` (close off-corner menu & mirror under icon), OR
                //   (b) a newly opened / revealed popover `AXWindow` -> snap its `AXPosition` right under the icon!
                let delaysMicros: [useconds_t] = [15_000, 25_000, 35_000, 45_000]
                for waitUs in delaysMicros {
                    usleep(waitUs)

                    if let dynMenu = AXStatusMenuBridge.shared.captureMenuSnapshot(from: axEl, cancelSourceMenuAfterRead: true) {
                        gate.resume(returning: .mirroredMenu(dynMenu))
                        return
                    }

                    if self.snapOpenedPopoverWindowIfFound(
                        axApp: axApp,
                        baselineWindows: baselineAXWins,
                        anchorRectCG: anchorRectCG,
                        displayCG: anchorDisplayCG
                    ) {
                        gate.resume(returning: .openedPopoverWindow)
                        return
                    }
                }

                if item.isSystemItem && usesAgentArch && !item.isCurrentlyOnBar {
                    gate.resume(returning: .fallbackSystemItem)
                    return
                }

                // Check if status item was a toggle switch whose title/description changed (e.g. Caffeine)
                let afterLabel = self.readStatusElementLabelFingerprint(axEl)
                if !beforeLabel.isEmpty && afterLabel != beforeLabel {
                    gate.resume(returning: .triggeredActionOnly)
                    return
                }

                // Apps using SwiftUI `WindowMenuBarExtraStyle` / `NSPopover.show(relativeTo:)` (e.g. Microsoft OneDrive)
                // abort `NSPopover` when unhosted by MenuBarAgent (`!item.isCurrentlyOnBar`). Present their native menu right under the icon!
                if !item.isCurrentlyOnBar {
                    let appMenuSnap = AXStatusMenuBridge.shared.captureApplicationMenuSnapshot(forPID: targetPID)
                    gate.resume(returning: .needsReopenOrMenuFallback(appMenuSnap))
                } else {
                    gate.resume(returning: .triggeredActionOnly)
                }
            }
        }

        // Release probe guard BEFORE modal NSMenu tracking so clicking another icon immediately after menu dismissal works 100%!
        isPerformingHIDSequence = false

        // STEP 5: Finalize presentation on MainActor
        switch interactionResult {
        case .mirroredMenu(let snapshot):
            presentMirroredSnapshotOnMain(
                snapshot,
                for: item,
                rightClick: rightClick,
                windowsBefore: windowsBefore,
                anchorView: anchorView,
                anchorScreenRectAppKit: anchorScreenRectAppKit
            )

        case .synthesizedAppMenu(let appMenuSnap):
            await presentSynthesizedMenuAndExecuteChoice(
                for: item,
                appMenuSnap: appMenuSnap,
                includeOpenNoteForMenuBarExtra: false,
                windowsBefore: windowsBefore,
                anchorRectCG: anchorRectCG,
                anchorDisplayCG: anchorDisplayCG,
                anchorView: anchorView,
                anchorScreenRectAppKit: anchorScreenRectAppKit
            )

        case .openedPopoverWindow:
            NSRunningApplication(processIdentifier: targetPID)?.activate()
            if SecondaryBarController.shared.isVisible {
                SecondaryBarController.shared.beginExternalPopoverSession(
                    itemID: item.id,
                    pid: targetPID,
                    baselineWinIDs: windowsBefore
                )
            }

        case .needsReopenOrMenuFallback(let appMenuSnap):
            await presentSynthesizedMenuAndExecuteChoice(
                for: item,
                appMenuSnap: appMenuSnap,
                includeOpenNoteForMenuBarExtra: true,
                windowsBefore: windowsBefore,
                anchorRectCG: anchorRectCG,
                anchorDisplayCG: anchorDisplayCG,
                anchorView: anchorView,
                anchorScreenRectAppKit: anchorScreenRectAppKit
            )

        case .fallbackSystemItem:
            onHideSecondaryBarRequested?()
            MenuBarVisibilityEngine.shared.triggerHiddenSystemItem(item, rightClick: rightClick)

        case .triggeredActionOnly:
            SecondaryBarController.shared.clearExternalPopoverSessionIfIdle()
        }

        if collapsedSpacersTemporarily {
            try? await Task.sleep(nanoseconds: 220_000_000)
            scheduleSmartRehide(targetPID: item.pid, baselineWindows: windowsBefore)
        }
    }

    private func presentMirroredSnapshotOnMain(
        _ snapshot: AXStatusMenuBridge.MirroredMenuSnapshot,
        for item: MenuBarAppItem,
        rightClick: Bool,
        windowsBefore: Set<Int>,
        anchorView: NSView?,
        anchorScreenRectAppKit: NSRect?
    ) {
        let barVisible = SecondaryBarController.shared.isVisible
        if barVisible {
            SecondaryBarController.shared.beginMirroredMenuSession(itemID: item.id)
        }
        let selection = AXStatusMenuBridge.shared.presentMirroredMenu(
            snapshot,
            includeGuaranteedQuitForAppName: rightClick ? item.appName : nil,
            anchorView: anchorView,
            anchorScreenRectAppKit: anchorScreenRectAppKit
        )
        if barVisible {
            SecondaryBarController.shared.endMirroredMenuSession(didSelectAction: selection != nil)
        }

        guard let selection = selection else { return }
        switch selection {
        case .quitAppExplicitly:
            quitTargetApplication(item)

        case .axNode(let nodeID, let selectedTitle):
            let lower = selectedTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let isQuitCommand = lower.hasPrefix("quit") || lower.contains("thoát")
            let opensDialogWindow =
                lower.contains("setting") || lower.contains("preferenc") ||
                lower.contains("cài đặt") || lower.contains("tuỳ chọn") || lower.contains("bảng điều khiển") ||
                lower.contains("about") || lower.contains("giới thiệu") ||
                lower.contains("update") || lower.contains("cập nhật") ||
                lower.contains("quick start") || lower.contains("help") || lower.contains("buy") ||
                lower.contains("license") || lower.contains("registration")

            if opensDialogWindow {
                NSRunningApplication(processIdentifier: item.pid)?.activate()
            }

            interactionQueue.async {
                AXStatusMenuBridge.shared.performSelectedMenuNode(nodeID, in: snapshot)
            }

            if isQuitCommand {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    guard let self = self else { return }
                    if let stillRunning = NSRunningApplication(processIdentifier: item.pid), !stillRunning.isTerminated {
                        let alertOpened = !self.currentOnScreenWindows(for: item.pid).subtracting(windowsBefore).isEmpty
                        if !alertOpened {
                            self.quitTargetApplication(item)
                            return
                        }
                    }
                    self.refreshRunningAppsAsync(forceFullScan: false)
                }
            } else {
                // If clicking the menu item opened a new window in that app, bring it to front automatically
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                    guard let self = self else { return }
                    if !self.currentOnScreenWindows(for: item.pid).subtracting(windowsBefore).isEmpty {
                        NSRunningApplication(processIdentifier: item.pid)?.activate()
                    }
                }
            }
        }
    }

    private func presentSynthesizedMenuAndExecuteChoice(
        for item: MenuBarAppItem,
        appMenuSnap: AXStatusMenuBridge.MirroredMenuSnapshot?,
        includeOpenNoteForMenuBarExtra: Bool,
        windowsBefore: Set<Int>,
        anchorRectCG: CGRect,
        anchorDisplayCG: CGRect,
        anchorView: NSView?,
        anchorScreenRectAppKit: NSRect?
    ) async {
        let cloudFolder = resolveCloudSyncFolderURL(for: item)
        let barVisible = SecondaryBarController.shared.isVisible
        if barVisible {
            SecondaryBarController.shared.beginMirroredMenuSession(itemID: item.id)
        }
        let choice = AXStatusMenuBridge.shared.presentSynthesizedAppMenu(
            for: item,
            appMenuSnapshot: appMenuSnap,
            cloudFolderURL: cloudFolder,
            includeOpenNoteForMenuBarExtra: includeOpenNoteForMenuBarExtra,
            anchorView: anchorView,
            anchorScreenRectAppKit: anchorScreenRectAppKit
        )
        if barVisible {
            SecondaryBarController.shared.endMirroredMenuSession(didSelectAction: choice != nil)
        }

        guard let choice = choice else { return }
        switch choice {
        case .axNode(let nodeID, let selectedTitle, let snap):
            let lower = selectedTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let isCompleteHelperQuit = lower.contains("completely") || lower.contains("hoàn toàn")
            let isQuitCommand = lower.hasPrefix("quit") || lower.contains("thoát")
            let isBackgroundAction = isQuitCommand ||
                lower.hasPrefix("hide") || lower.contains("ẩn") ||
                lower.hasPrefix("lock") || lower.contains("khoá")

            if !isBackgroundAction {
                NSRunningApplication(processIdentifier: item.pid)?.activate()
            }

            interactionQueue.async {
                AXStatusMenuBridge.shared.performSelectedMenuNode(nodeID, in: snap)
            }

            if isQuitCommand && !isCompleteHelperQuit {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) { [weak self] in
                    guard let self = self else { return }
                    if let stillRunning = NSRunningApplication(processIdentifier: item.pid), !stillRunning.isTerminated {
                        let alertOpened = !self.currentOnScreenWindows(for: item.pid).subtracting(windowsBefore).isEmpty
                        if !alertOpened {
                            self.quitTargetApplication(item)
                            return
                        }
                    }
                    self.refreshRunningAppsAsync(forceFullScan: false)
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
                    self?.refreshRunningAppsAsync(forceFullScan: false)
                }
            }

        case .openAppUI:
            await openAppPrimaryInterfaceExplicitly(
                item: item,
                cloudFolderURL: cloudFolder,
                windowsBefore: windowsBefore,
                anchorRectCG: anchorRectCG,
                anchorDisplayCG: anchorDisplayCG
            )

        case .openCloudFolder(let url):
            NSWorkspace.shared.open(url)

        case .pinToMainBar:
            setAppSelection(item, visibleOnMainBar: true)

        case .quitApp:
            quitTargetApplication(item)
        }
    }

    private func attemptReopenForUnhostedMenuBarExtra(
        item: MenuBarAppItem,
        windowsBefore: Set<Int>,
        anchorRectCG: CGRect,
        anchorDisplayCG: CGRect
    ) async -> Bool {
        let targetPID = item.pid
        let finderPID = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.finder" })?.processIdentifier ?? 0
        let finderWinsBefore = finderPID > 0 ? currentOnScreenWindows(for: finderPID) : Set<Int>()

        guard let appURL = resolveAppBundleURL(for: item) else { return false }

        let axApp = AXUIElementCreateApplication(targetPID)
        let baselineAXWins = readAXWindows(of: axApp)

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, _ in
                cont.resume()
            }
        }

        try? await Task.sleep(nanoseconds: 180_000_000)

        let snapped = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            interactionQueue.async { [weak self] in
                guard let self = self else {
                    cont.resume(returning: false)
                    return
                }
                let ok = self.snapOpenedPopoverWindowIfFound(
                    axApp: axApp,
                    baselineWindows: baselineAXWins,
                    anchorRectCG: anchorRectCG,
                    displayCG: anchorDisplayCG
                )
                cont.resume(returning: ok)
            }
        }
        if snapped {
            NSRunningApplication(processIdentifier: targetPID)?.activate()
            if SecondaryBarController.shared.isVisible {
                SecondaryBarController.shared.beginExternalPopoverSession(
                    itemID: item.id,
                    pid: targetPID,
                    baselineWinIDs: windowsBefore
                )
            }
            return true
        }

        let newAppWins = currentOnScreenWindows(for: targetPID).subtracting(windowsBefore)
        if !newAppWins.isEmpty {
            onHideSecondaryBarRequested?()
            NSRunningApplication(processIdentifier: targetPID)?.activate()
            return true
        }

        // OneDrive's `handleApplicationReOpenEvent:` opens the user's OneDrive folder in Finder when configured
        if finderPID > 0 && !currentOnScreenWindows(for: finderPID).subtracting(finderWinsBefore).isEmpty {
            onHideSecondaryBarRequested?()
            return true
        }

        return false
    }

    private func openAppPrimaryInterfaceExplicitly(
        item: MenuBarAppItem,
        cloudFolderURL: URL?,
        windowsBefore: Set<Int>,
        anchorRectCG: CGRect,
        anchorDisplayCG: CGRect
    ) async {
        // First try direct Left-Click `AXPress` (e.g. opens 1Password Vault / Maccy / AdGuard / Itsycal right under icon)
        let targetPID = item.pid
        let axOpened = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            interactionQueue.async { [weak self] in
                guard let self = self,
                      let axEl = MenuBarScanner.shared.liveStatusElement(for: item, preferredDisplay: nil, timeout: 0.18)?.element ?? item.axElement else {
                    cont.resume(returning: false)
                    return
                }
                let axApp = AXUIElementCreateApplication(targetPID)
                let baselineAXWins = self.readAXWindows(of: axApp)
                _ = AXUIElementPerformAction(axEl, kAXPressAction as CFString)
                for waitUs: useconds_t in [20_000, 40_000, 65_000] {
                    usleep(waitUs)
                    if self.snapOpenedPopoverWindowIfFound(
                        axApp: axApp,
                        baselineWindows: baselineAXWins,
                        anchorRectCG: anchorRectCG,
                        displayCG: anchorDisplayCG
                    ) {
                        cont.resume(returning: true)
                        return
                    }
                }
                cont.resume(returning: false)
            }
        }
        if axOpened {
            NSRunningApplication(processIdentifier: targetPID)?.activate()
            return
        }

        let reopened = await attemptReopenForUnhostedMenuBarExtra(
            item: item,
            windowsBefore: windowsBefore,
            anchorRectCG: anchorRectCG,
            anchorDisplayCG: anchorDisplayCG
        )
        if reopened { return }

        if let folderURL = cloudFolderURL {
            NSWorkspace.shared.open(folderURL)
            return
        }

        if let running = NSRunningApplication(processIdentifier: targetPID) {
            running.activate()
        }
    }

    private func quitTargetApplication(_ item: MenuBarAppItem) {
        if let running = NSRunningApplication(processIdentifier: item.pid) {
            if !running.terminate() {
                kill(item.pid, SIGTERM)
            }
        } else if item.pid > 100 {
            kill(item.pid, SIGTERM)
        }

        // If quitting OneDrive or its embedded OneDrive Sync Service helper, cleanly terminate both companion user processes
        let bid = (item.bundleIdentifier ?? "").lowercased()
        if bid == "com.microsoft.onedrive" || bid == "com.microsoft.sharepoint-mac" {
            for companion in NSWorkspace.shared.runningApplications where companion.processIdentifier != item.pid {
                let cbid = (companion.bundleIdentifier ?? "").lowercased()
                if cbid == "com.microsoft.onedrive" || cbid == "com.microsoft.sharepoint-mac" {
                    if !companion.terminate() {
                        kill(companion.processIdentifier, SIGTERM)
                    }
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            self?.refreshRunningAppsAsync(forceFullScan: false)
        }
    }

    private func resolveAppBundleURL(for item: MenuBarAppItem) -> URL? {
        if let url = NSRunningApplication(processIdentifier: item.pid)?.bundleURL {
            let p = url.path
            if let outerRange = p.range(of: ".app/") {
                let outerPath = String(p[..<outerRange.upperBound].dropLast())
                return URL(fileURLWithPath: outerPath)
            }
            if url.pathExtension == "app" {
                return url
            }
        }
        if item.pid > 0 {
            var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if proc_pidpath(item.pid, &pathBuf, UInt32(MAXPATHLEN)) > 0 {
                let fullPath = String(cString: pathBuf)
                if let r = fullPath.range(of: ".app/") {
                    let appPath = String(fullPath[..<r.upperBound].dropLast())
                    return URL(fileURLWithPath: appPath)
                }
            }
        }
        if let bundleID = item.bundleIdentifier, !bundleID.isEmpty {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        }
        return nil
    }

    private func resolveCloudSyncFolderURL(for item: MenuBarAppItem) -> URL? {
        let fingerprint = ((item.bundleIdentifier ?? "") + " " + item.appName).lowercased()
        let cloudPrefix: String?
        if fingerprint.contains("onedrive") {
            cloudPrefix = "onedrive"
        } else if fingerprint.contains("googledrive") || fingerprint.contains("google drive") {
            cloudPrefix = "googledrive"
        } else if fingerprint.contains("dropbox") {
            cloudPrefix = "dropbox"
        } else {
            cloudPrefix = nil
        }
        guard let prefix = cloudPrefix else { return nil }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let cloudStorageDir = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: cloudStorageDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            if let match = entries.first(where: { $0.lastPathComponent.lowercased().hasPrefix(prefix) }) {
                return match
            }
        }

        if prefix == "onedrive" {
            let legacy = home.appendingPathComponent("OneDrive", isDirectory: true)
            if FileManager.default.fileExists(atPath: legacy.path) {
                return legacy
            }
        }
        return nil
    }

    nonisolated private func readStatusElementLabelFingerprint(_ axEl: AXUIElement) -> String {
        var tRef: CFTypeRef?
        var dRef: CFTypeRef?
        let t = (AXUIElementCopyAttributeValue(axEl, kAXTitleAttribute as CFString, &tRef) == .success) ? ((tRef as? String) ?? "") : ""
        let d = (AXUIElementCopyAttributeValue(axEl, kAXDescriptionAttribute as CFString, &dRef) == .success) ? ((dRef as? String) ?? "") : ""
        return "\(t)|\(d)"
    }

    nonisolated private func readAXWindows(of axApp: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let wins = ref as? [AXUIElement] else {
            return []
        }
        return wins
    }

    nonisolated private func snapOpenedPopoverWindowIfFound(
        axApp: AXUIElement,
        baselineWindows: [AXUIElement],
        anchorRectCG: CGRect,
        displayCG: CGRect
    ) -> Bool {
        let currentWins = readAXWindows(of: axApp)
        guard !currentWins.isEmpty else { return false }

        var chosenWin: AXUIElement? = nil
        var chosenSize = CGSize.zero

        for w in currentWins {
            AXUIElementSetMessagingTimeout(w, 0.12)
            guard let sz = readAXWindowSize(w), sz.width >= 40, sz.height >= 28 else { continue }
            var settable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(w, kAXPositionAttribute as CFString, &settable) == .success,
                  settable.boolValue else { continue }

            let isBrandNew = !baselineWindows.contains(where: { CFEqual($0, w) })
            if isBrandNew {
                chosenWin = w
                chosenSize = sz
                break
            }

            // Also catch reusable pre-allocated popovers/panels (e.g. Itsycal / custom NSPanel) that were ordered in
            var subroleRef: CFTypeRef?
            let subrole = (AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &subroleRef) == .success)
                ? ((subroleRef as? String) ?? "")
                : ""
            if sz.width <= 820 && sz.height <= 960 && subrole != "AXStandardWindow" {
                chosenWin = w
                chosenSize = sz
                break
            }
        }

        guard let targetWin = chosenWin else { return false }

        func computeTargetOrigin(for size: CGSize) -> CGPoint {
            let minX = displayCG.minX + 8.0
            let maxX = max(minX, displayCG.maxX - size.width - 8.0)
            let centeredX = min(max(anchorRectCG.midX - size.width * 0.5, minX), maxX)

            let minY = displayCG.minY + 30.0
            let maxY = max(minY, displayCG.maxY - min(size.height, displayCG.height - 40.0) - 8.0)
            let anchoredY = min(max(anchorRectCG.maxY + 4.0, minY), maxY)
            return CGPoint(x: round(centeredX), y: round(anchoredY))
        }

        var firstPt = computeTargetOrigin(for: chosenSize)
        if let val = AXValueCreate(.cgPoint, &firstPt) {
            _ = AXUIElementSetAttributeValue(targetWin, kAXPositionAttribute as CFString, val)
        }

        // Re-verify 38ms later in case the app ran an initial frame animation right after orderFront
        usleep(38_000)
        let updatedSize = readAXWindowSize(targetWin) ?? chosenSize
        var finalPt = computeTargetOrigin(for: updatedSize)
        if let curPos = readAXWindowPosition(targetWin),
           hypot(curPos.x - finalPt.x, curPos.y - finalPt.y) > 4.0,
           let val2 = AXValueCreate(.cgPoint, &finalPt) {
            _ = AXUIElementSetAttributeValue(targetWin, kAXPositionAttribute as CFString, val2)
        }

        return true
    }

    nonisolated private func readAXWindowSize(_ win: AXUIElement) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &ref) == .success,
              let val = ref else { return nil }
        var sz = CGSize.zero
        return AXValueGetValue(val as! AXValue, .cgSize, &sz) ? sz : nil
    }

    nonisolated private func readAXWindowPosition(_ win: AXUIElement) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &ref) == .success,
              let val = ref else { return nil }
        var pt = CGPoint.zero
        return AXValueGetValue(val as! AXValue, .cgPoint, &pt) ? pt : nil
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
        let ignoreBundles: Set<String> = [
            "com.apple.MenuBarAgent",
            "com.apple.TextInputMenuAgent",
            "com.apple.campo",
            "com.apple.controlcenter"
        ]
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let launchedBundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier ?? ""
            guard !ignoreBundles.contains(launchedBundle) else { return }
            Task { @MainActor in
                MenuBarScanner.shared.handleAppLaunched()
                try? await Task.sleep(nanoseconds: 900_000_000)
                self?.refreshRunningAppsAsync(forceFullScan: true)
            }
        }
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundle = app?.bundleIdentifier ?? ""
            let terminatedPID = app?.processIdentifier ?? 0
            Task { @MainActor in
                MenuBarVisibilityEngine.shared.invalidateProcessCache(pid: terminatedPID)
                guard !ignoreBundles.contains(bundle) else { return }
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

/// Zero-overhead hover tracker attached inside `BarFlow`'s `•••` `NSStatusBarButton`.
/// Passes 100% of clicks & drags straight through (`hitTest` returns `nil`) while opening
/// the Secondary Bar after a `0.22s` dwell when `hoverToOpenEnabled` is active.
@MainActor
private final class StatusButtonHoverOverlayView: NSView {
    private var trackingAreaRef: NSTrackingArea?
    private var hoverDwellWorkItem: DispatchWorkItem?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        hoverDwellWorkItem?.cancel()
        guard MenuBarController.shared.hoverToOpenEnabled,
              !SecondaryBarController.shared.isVisible else { return }

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self = self,
                      let win = self.window,
                      MenuBarController.shared.hoverToOpenEnabled,
                      !SecondaryBarController.shared.isVisible else { return }
                if NSMouseInRect(NSEvent.mouseLocation, win.frame.insetBy(dx: -4, dy: -4), false) {
                    SecondaryBarController.shared.showFromHover()
                }
            }
        }
        hoverDwellWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        hoverDwellWorkItem?.cancel()
        hoverDwellWorkItem = nil
    }
}
