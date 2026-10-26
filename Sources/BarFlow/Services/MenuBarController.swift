import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import Combine

@MainActor
final class MenuBarController: ObservableObject {
    static let shared = MenuBarController()

    // MARK: - Published State

    /// All currently running menu bar applications discovered by the scanner.
    @Published private(set) var allRunningApps: [MenuBarAppItem] = []

    /// IDs of applications chosen by the user to stay visible on the Main Menu Bar.
    @Published var selectedMainBarIDs: Set<String> {
        didSet {
            saveSelection()
        }
    }

    /// Whether BarFlow actively hides unselected apps from the Main Menu Bar using its spacer divider.
    @Published var isMainBarHidingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isMainBarHidingEnabled, forKey: Keys.hidingEnabled)
            applySpacersVisibilityState()
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

    /// UI state for AppSelectionView (avoids SwiftUIMacros @State dependency under CommandLineTools).
    @Published var searchText: String = ""
    @Published var filterModeRaw: String = "all"
    @Published var hoveredPreviewID: String? = nil
    @Published var hoveredRowID: String? = nil

    /// Whether Accessibility permission is currently granted.
    @Published private(set) var isAccessibilityGranted: Bool = AXIsProcessTrusted()

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

    // MARK: - Internal Properties

    private enum Keys {
        static let selectedIDs = "BarFlow.SelectedMainBarIDs"
        static let initialized = "BarFlow.HasInitializedSelection"
        static let hidingEnabled = "BarFlow.MainBarHidingEnabled"
        static let autoHideSeconds = "BarFlow.AutoHideSeconds"
        static let showSelectionOnLaunch = "BarFlow.ShowSelectionOnLaunch"
        static let hideFromDock = "BarFlow.HideFromDock"
    }

    private var mainStatusItem: NSStatusItem?
    private var spacerItems: [NSStatusItem] = []
    private let spacerCount = 36
    private let singleSpacerWidth: CGFloat = 44.0

    private var areSpacersCurrentlyExpanded: Bool = false
    private var isTemporarilyRevealedForClick: Bool = false
    private var isMenuCurrentlyTracking: Bool = false
    private var rehideMonitorTimer: Timer?
    private var refreshTimer: Timer?
    private var isPerformingHIDSequence: Bool = false

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
        refreshRunningApps(initializeDefaultsIfNeeded: true)

        // Apply spacer state after initial scan settles
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.applySpacersVisibilityState()
        }

        // Periodic lightweight refresh (fast 1.2s while waiting for Accessibility grant, 4.0s once granted)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let trusted = AXIsProcessTrusted()
                let changedTrust = (trusted != self.isAccessibilityGranted)
                self.isAccessibilityGranted = trusted
                if changedTrust {
                    self.applySpacersVisibilityState()
                }
                if trusted && !self.isPerformingHIDSequence && !self.isArrangingMenuBar {
                    self.refreshRunningApps(initializeDefaultsIfNeeded: changedTrust)
                }
            }
        }
    }

    func prepareForTermination() {
        refreshTimer?.invalidate()
        rehideMonitorTimer?.invalidate()
        // Always collapse spacers on quit so all hidden icons reappear cleanly on the user's Menu Bar
        for spacer in spacerItems {
            spacer.isVisible = false
            spacer.length = 0
        }
    }

    func applyDockPolicy() {
        NSApp.setActivationPolicy(hideFromDock ? .accessory : .regular)
    }

    // MARK: - Status Items (Main Toggle + Invisible Multi-Spacers)

    private func setupStatusItems() {
        guard mainStatusItem == nil else { return }

        // 1. Create Main Toggle Status Item FIRST so it sits to the RIGHT of all spacers
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

        // 2. Create pool of compact invisible spacers to the LEFT of MainToggle
        // Using multiple 44pt spacers avoids macOS 27 MenuBarAgent discarding oversized single 10,000pt items.
        var createdSpacers: [NSStatusItem] = []
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

    /// Returns the CG-coordinate frame of BarFlow's main status item if currently available.
    func mainStatusItemFrameCG() -> CGRect? {
        guard let win = mainStatusItem?.button?.window else { return nil }
        let rect = MenuBarScanner.appKitToCGRect(win.frame)
        return rect.width > 0 ? rect : nil
    }

    /// Returns the AppKit frame of BarFlow's main status item for anchoring the Secondary Bar right below it.
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

    // MARK: - Scanning & Selection Management

    func refreshRunningApps(initializeDefaultsIfNeeded: Bool = false) {
        isAccessibilityGranted = AXIsProcessTrusted()
        guard isAccessibilityGranted else { return }

        let snapshot = MenuBarScanner.shared.scanMenuBar(ownMainToggleFrameCG: mainStatusItemFrameCG())
        self.allRunningApps = snapshot.apps

        let hasInitialized = UserDefaults.standard.bool(forKey: Keys.initialized)
        if initializeDefaultsIfNeeded && !hasInitialized && !snapshot.apps.isEmpty {
            // Pre-select the rightmost ~6 apps (plus system items) so the user immediately has a clean Main Bar
            // and a populated Secondary Bar (Ctrl+B), ready to customize!
            var initialIDs = Set<String>()
            var nonSystemCount = 0
            for app in snapshot.apps {
                if app.isSystemItem {
                    initialIDs.insert(app.id)
                } else if nonSystemCount < 5 {
                    initialIDs.insert(app.id)
                    nonSystemCount += 1
                }
            }
            self.selectedMainBarIDs = initialIDs
            UserDefaults.standard.set(true, forKey: Keys.initialized)
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
            selectedMainBarIDs.insert(item.id)
        } else {
            selectedMainBarIDs.remove(item.id)
        }
    }

    func selectAllForMainBar() {
        selectedMainBarIDs = Set(allRunningApps.map(\.id))
    }

    func deselectAllNonSystemForMainBar() {
        selectedMainBarIDs = Set(allRunningApps.filter(\.isSystemItem).map(\.id))
    }

    private func saveSelection() {
        UserDefaults.standard.set(Array(selectedMainBarIDs), forKey: Keys.selectedIDs)
        UserDefaults.standard.set(true, forKey: Keys.initialized)
    }

    // MARK: - Physical Menu Bar Reordering (⌘-Drag across BarFlow Divider)

    /// Physically moves Checked apps to the RIGHT of BarFlow's icon (visible on Main Menu Bar)
    /// and Unchecked apps to the LEFT of BarFlow's spacers (hidden from Main Menu Bar).
    func arrangeMenuBarAccordingToSelection() async {
        guard AXIsProcessTrusted() else {
            MenuBarScanner.shared.promptForAccessibilityPermission()
            statusMessage = "Vui lòng cấp quyền Trợ năng (Accessibility) để sắp xếp Menu Bar."
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
            refreshRunningApps()
        }

        // 1. Collapse spacers first so maximum items get real on-screen slots on the widest display
        let wasExpanded = areSpacersCurrentlyExpanded
        if wasExpanded {
            setSpacersExpanded(false)
            try? await Task.sleep(nanoseconds: 350_000_000)
        }

        guard let targetDisplayID = MenuBarScanner.widestDisplayID() else {
            statusMessage = "Không tìm thấy màn hình để sắp xếp."
            return
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var movedCount = 0

        // Perform up to 28 individual ⌘-drag operations so items settle cleanly one by one
        for _ in 0..<28 {
            let (slotsByDisplay, _) = MenuBarScanner.shared.readHostedSlotsByDisplay(
                ownPID: ownPID,
                ownMainToggleFrameCG: mainStatusItemFrameCG()
            )
            guard let slots = slotsByDisplay[targetDisplayID], !slots.isEmpty else { break }

            // Locate BarFlow's own divider bounds on this display
            let ownSlots = slots.filter { $0.sourcePID == ownPID }
            guard let mainToggleSlot = ownSlots.first(where: { $0.identifier == "BarFlow.MainToggle" }) ?? ownSlots.last else {
                break
            }
            let leftmostOwnMinX = ownSlots.map(\.frame.minX).min() ?? mainToggleSlot.frame.minX
            let rightmostOwnMaxX = mainToggleSlot.frame.maxX

            // Refresh PID -> ID map
            let idByPID: [pid_t: MenuBarAppItem] = Dictionary(
                uniqueKeysWithValues: allRunningApps.map { ($0.pid, $0) }
            )

            // Case A: Find a SELECTED app sitting to the LEFT of BarFlow -> move it to the RIGHT of MainToggle
            if let wrongLeftSlot = slots.first(where: { slot in
                guard slot.sourcePID > 0, slot.sourcePID != ownPID,
                      slot.frame.maxX <= leftmostOwnMinX + 2,
                      let item = idByPID[slot.sourcePID], item.isMovable else { return false }
                return selectedMainBarIDs.contains(item.id)
            }) {
                let targetPoint = CGPoint(x: min(rightmostOwnMaxX + 14, wrongLeftSlot.hostWindowFrame.maxX - 24), y: mainToggleSlot.frame.midY)
                await performCommandDrag(from: wrongLeftSlot.center, to: targetPoint)
                movedCount += 1
                try? await Task.sleep(nanoseconds: 220_000_000)
                continue
            }

            // Case B: Find an UNSELECTED app sitting to the RIGHT of MainToggle -> move it to the LEFT of BarFlow
            if let wrongRightSlot = slots.first(where: { slot in
                guard slot.sourcePID > 0, slot.sourcePID != ownPID,
                      slot.frame.minX >= rightmostOwnMaxX - 2,
                      let item = idByPID[slot.sourcePID], item.isMovable else { return false }
                return !selectedMainBarIDs.contains(item.id)
            }) {
                let targetPoint = CGPoint(x: max(leftmostOwnMinX - 14, wrongRightSlot.hostWindowFrame.minX + 400), y: mainToggleSlot.frame.midY)
                await performCommandDrag(from: wrongRightSlot.center, to: targetPoint)
                movedCount += 1
                try? await Task.sleep(nanoseconds: 220_000_000)
                continue
            }

            // All visible slots are on the correct side of BarFlow!
            break
        }

        if isMainBarHidingEnabled {
            setSpacersExpanded(true)
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        statusMessage = movedCount > 0
            ? "Đã sắp xếp xong \(movedCount) biểu tượng và ẩn các app còn lại xuống Ctrl + B!"
            : "Menu Bar chính đã khớp danh sách chọn lọc!"
    }

    // MARK: - Clicking & Interacting with Hidden Apps from `Ctrl + B` Secondary Bar

    /// Invoked when the user clicks (or right-clicks) an app inside the floating `Ctrl + B` Secondary Bar.
    func activateAppFromSecondaryBar(_ item: MenuBarAppItem, rightClick: Bool = false) {
        onHideSecondaryBarRequested?()

        Task { @MainActor in
            await performHiddenAppInteraction(item, rightClick: rightClick)
        }
    }

    private func performHiddenAppInteraction(_ item: MenuBarAppItem, rightClick: Bool) async {
        guard !isPerformingHIDSequence else { return }
        isPerformingHIDSequence = true

        let mouseScreen = MenuBarScanner.screenContainingMouse()
        let targetDisplayID = MenuBarScanner.displayID(for: mouseScreen) ?? MenuBarScanner.widestDisplayID() ?? CGMainDisplayID()

        // Capture existing windows of target PID so we can detect any newly opened popover/panel
        let windowsBefore = currentOnScreenWindows(for: item.pid)

        // 1. Check if item ALREADY has a visible slot on the mouse display
        var liveSlot = MenuBarScanner.shared.findSlot(
            forPID: item.pid,
            on: targetDisplayID,
            ownMainToggleFrameCG: mainStatusItemFrameCG()
        )

        var collapsedSpacersTemporarily = false
        var expandedSystemChevron = false

        // 2. If hidden behind our spacers, temporarily collapse spacers so it gets a real on-bar slot
        if liveSlot == nil && areSpacersCurrentlyExpanded {
            isTemporarilyRevealedForClick = true
            collapsedSpacersTemporarily = true
            setSpacersExpanded(false)

            for _ in 0..<8 {
                try? await Task.sleep(nanoseconds: 55_000_000)
                if let found = MenuBarScanner.shared.findSlot(
                    forPID: item.pid,
                    on: targetDisplayID,
                    ownMainToggleFrameCG: mainStatusItemFrameCG()
                ) {
                    liveSlot = found
                    break
                }
            }
        }

        // 3. If still in macOS 27's native `«` overflow on a narrow display, click the `«` chevron to reveal slots
        if liveSlot == nil {
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let (_, chevrons) = MenuBarScanner.shared.readHostedSlotsByDisplay(
                ownPID: ownPID,
                ownMainToggleFrameCG: mainStatusItemFrameCG()
            )
            if let chevronRect = chevrons[targetDisplayID] {
                expandedSystemChevron = true
                await postHIDClick(
                    at: CGPoint(x: chevronRect.midX, y: chevronRect.midY),
                    button: .left,
                    restoreCursor: false
                )
                for _ in 0..<8 {
                    try? await Task.sleep(nanoseconds: 55_000_000)
                    if let found = MenuBarScanner.shared.findSlot(
                        forPID: item.pid,
                        on: targetDisplayID,
                        ownMainToggleFrameCG: mainStatusItemFrameCG()
                    ) {
                        liveSlot = found
                        break
                    }
                }
            }
        }

        // 4. Also check widest display if still nil
        if liveSlot == nil, let widest = MenuBarScanner.widestDisplayID(), widest != targetDisplayID {
            liveSlot = MenuBarScanner.shared.findSlot(
                forPID: item.pid,
                on: widest,
                ownMainToggleFrameCG: mainStatusItemFrameCG()
            )
        }

        // 5. Perform the actual click on the status item!
        if let slot = liveSlot {
            await postHIDClick(
                at: slot.center,
                button: rightClick ? .right : .left,
                restoreCursor: !expandedSystemChevron
            )
        } else if !rightClick, let axEl = item.axElement ?? MenuBarScanner.shared.readExtrasMenuBarChildren(for: item.pid).first {
            // Direct Accessibility AXPress fallback
            let err = AXUIElementPerformAction(axEl, kAXPressAction as CFString)
            if err != .success {
                if let runningApp = NSRunningApplication(processIdentifier: item.pid) {
                    runningApp.activate()
                }
            }
        } else if let runningApp = NSRunningApplication(processIdentifier: item.pid) {
            runningApp.activate()
        }

        isPerformingHIDSequence = false

        // 6. Schedule smart auto-rehide once the target app's menu or popover closes!
        if collapsedSpacersTemporarily {
            try? await Task.sleep(nanoseconds: 280_000_000)
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
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                self?.refreshRunningApps()
            }
        }
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refreshRunningApps()
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

                // Wait while an NSMenu is still open
                if self.isMenuCurrentlyTracking && Date().timeIntervalSince(startedAt) < 25 {
                    return
                }

                // Wait while the target app still has a newly opened popover/panel onscreen
                let currentWins = self.currentOnScreenWindows(for: targetPID)
                let newPopupWindows = currentWins.subtracting(baselineWindows)
                if !newPopupWindows.isEmpty && Date().timeIntervalSince(startedAt) < 25 {
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

    // MARK: - Low-Level Quartz HID Click & Command-Drag Helpers

    private func configureNonSuppressingEventSources() -> CGEventSource? {
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

    private func postHIDClick(at point: CGPoint, button: CGMouseButton, restoreCursor: Bool) async {
        let savedCursor = currentMouseCGLocation()
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
            if restoreCursor {
                CGWarpMouseCursorPosition(savedCursor)
            }
            CGDisplayShowCursor(CGMainDisplayID())
        }

        down.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 45_000_000)
        up.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 45_000_000)
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

        var sequence: [CGEvent] = []
        if let down = makeDragEvent(.leftMouseDown, at: start) {
            sequence.append(down)
        }
        let steps = 12
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            if let drag = makeDragEvent(.leftMouseDragged, at: p) {
                sequence.append(drag)
            }
        }
        if let up = makeDragEvent(.leftMouseUp, at: end) {
            sequence.append(up)
        }

        CGDisplayHideCursor(CGMainDisplayID())
        defer {
            CGWarpMouseCursorPosition(savedCursor)
            CGDisplayShowCursor(CGMainDisplayID())
        }

        for ev in sequence {
            ev.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 28_000_000)
        }
    }
}
