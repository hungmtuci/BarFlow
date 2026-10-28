import Foundation
import AppKit
import CoreGraphics
import SwiftUI

final class NonActivatingBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Isolated observable model for the 1.5pt bottom countdown hairline so app icons never re-render on timer ticks.
@MainActor
final class SecondaryBarCountdownModel: ObservableObject {
    @Published var progress: Double = 1.0
}

@MainActor
final class SecondaryBarController: ObservableObject {
    static let shared = SecondaryBarController()

    @Published private(set) var isVisible: Bool = false
    @Published private(set) var activeOpenedItemID: String? = nil
    let countdown = SecondaryBarCountdownModel()

    private var panel: NonActivatingBarPanel?
    private var autoHideTimer: Timer?
    private var outsideClickMonitor: Any?
    private var lastInteractionDate: Date = Date()
    private var lastWarmScanTimestamp: CFAbsoluteTime = 0
    private var lastHoverOpenedTimestamp: CFAbsoluteTime = 0

    /// Tracks an active native `NSMenu` or repositioned app popover anchored underneath `Ctrl + B`.
    private(set) var isPresentingMirroredMenu: Bool = false
    private var trackedPopoverPID: pid_t = 0
    private var trackedPopoverBaselineWinIDs = Set<Int>()
    private var trackedPopoverOpenedAt: CFAbsoluteTime = 0

    /// Layout constants matching `SecondaryBarView` single-row metrics
    static let panelHeight: CGFloat = 38.0
    static let iconSlotSize: CGFloat = 28.0
    static let iconSpacing: CGFloat = 3.0
    static let trailingChromeWidth: CGFloat = 52.0

    private init() {
        setupPanel()
    }

    private func setupPanel() {
        let initialRect = NSRect(x: 0, y: 0, width: 320, height: Self.panelHeight)
        let p = NonActivatingBarPanel(
            contentRect: initialRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.animationBehavior = .none

        let rootView = SecondaryBarView(
            barController: self,
            menuController: MenuBarController.shared
        )
        let host = NSHostingView(rootView: rootView)
        host.sizingOptions = []
        p.contentView = host

        self.panel = p
    }

    // MARK: - Instant Toggle / Show / Hide

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    /// Invoked on Left-Click of `•••`: ignores accidental immediate close if hover-to-open just revealed the bar `< 0.65s` ago.
    func handleStatusIconToggleClick() {
        if isVisible {
            if (CFAbsoluteTimeGetCurrent() - lastHoverOpenedTimestamp) < 0.65 {
                lastInteractionDate = Date()
                return
            }
            hide()
        } else {
            show()
        }
    }

    func showFromHover() {
        guard !isVisible else { return }
        lastHoverOpenedTimestamp = CFAbsoluteTimeGetCurrent()
        show()
    }

    func show() {
        guard let panel = panel else { return }

        let screen = MenuBarScanner.screenContainingMouse()
        let targetFrame = calculateTargetFrame(on: screen)

        panel.setFrame(targetFrame, display: true)
        panel.alphaValue = 1.0
        panel.orderFrontRegardless()

        if !isVisible {
            isVisible = true
            MenuBarController.shared.updateMainButtonAppearance(isSecondaryOpen: true)
        }

        startAutoHideMonitoring()
        installOutsideClickMonitor()

        // Non-blocking warm background refresh at most once every 8s AFTER the bar is already visible on screen
        let now = CFAbsoluteTimeGetCurrent()
        if (now - lastWarmScanTimestamp) >= 8.0 {
            lastWarmScanTimestamp = now
            MenuBarController.shared.refreshRunningAppsAsync(forceFullScan: false)
        }
    }

    func hide() {
        guard isVisible || (panel?.isVisible == true) else { return }

        stopAutoHideMonitoring()
        removeOutsideClickMonitor()
        isPresentingMirroredMenu = false
        trackedPopoverPID = 0
        trackedPopoverBaselineWinIDs.removeAll()
        if activeOpenedItemID != nil {
            activeOpenedItemID = nil
        }
        isVisible = false
        MenuBarController.shared.updateMainButtonAppearance(isSecondaryOpen: false)
        panel?.orderOut(nil)
    }

    /// Adjusts width in-place at the top-right corner if the secondary app count changes while visible.
    func repositionIfVisible() {
        guard isVisible, let panel = panel else { return }
        let screen = panel.screen ?? MenuBarScanner.screenContainingMouse()
        let newFrame = calculateTargetFrame(on: screen)
        if abs(panel.frame.width - newFrame.width) > 1 || abs(panel.frame.origin.x - newFrame.origin.x) > 1 {
            panel.setFrame(newFrame, display: true)
        }
    }

    // MARK: - Anchored App Menu / Popover Lifecycle

    func notifyUserInteraction() {
        lastInteractionDate = Date()
        if countdown.progress != 1.0 {
            countdown.progress = 1.0
        }
    }

    func beginMirroredMenuSession(itemID: String) {
        isPresentingMirroredMenu = true
        trackedPopoverPID = 0
        activeOpenedItemID = itemID
        lastInteractionDate = Date()
        if countdown.progress != 1.0 {
            countdown.progress = 1.0
        }
    }

    func endMirroredMenuSession(didSelectAction: Bool) {
        isPresentingMirroredMenu = false
        activeOpenedItemID = nil

        if didSelectAction {
            hide()
            return
        }

        // If user clicked another icon inside `Ctrl + B`, keep the bar open; otherwise close cleanly.
        if let panel = panel, NSMouseInRect(NSEvent.mouseLocation, panel.frame.insetBy(dx: -4, dy: -4), false) {
            lastInteractionDate = Date()
            countdown.progress = 1.0
        } else {
            hide()
        }
    }

    func beginExternalPopoverSession(itemID: String, pid: pid_t, baselineWinIDs: Set<Int>) {
        isPresentingMirroredMenu = false
        activeOpenedItemID = itemID
        trackedPopoverPID = pid
        trackedPopoverBaselineWinIDs = baselineWinIDs
        trackedPopoverOpenedAt = CFAbsoluteTimeGetCurrent()
        lastInteractionDate = Date()
        if countdown.progress != 1.0 {
            countdown.progress = 1.0
        }
    }

    func clearExternalPopoverSessionIfIdle() {
        trackedPopoverPID = 0
        trackedPopoverBaselineWinIDs.removeAll()
        if activeOpenedItemID != nil {
            activeOpenedItemID = nil
        }
    }

    // MARK: - Single-Row Top-Right Frame Calculation

    private func calculateTargetFrame(on screen: NSScreen) -> NSRect {
        let menuController = MenuBarController.shared
        let idealWidth: CGFloat

        if !menuController.isAccessibilityGranted {
            idealWidth = 316.0
        } else {
            let count = menuController.secondaryBarApps.count
            if count == 0 {
                idealWidth = 236.0
            } else {
                let iconsWidth = CGFloat(count) * Self.iconSlotSize + CGFloat(max(count - 1, 0)) * Self.iconSpacing
                idealWidth = iconsWidth + Self.trailingChromeWidth
            }
        }

        let maxAllowedWidth = max(160.0, screen.frame.width - 12.0)
        let finalWidth = min(max(idealWidth, 86.0), maxAllowedWidth)
        let finalHeight = Self.panelHeight

        // Always anchor on the RIGHT side of the active screen, immediately underneath the native macOS Menu Bar
        let menuBarThickness = MenuBarScanner.effectiveMenuBarThickness(for: screen)
        let targetX = max(screen.frame.minX + 6.0, screen.frame.maxX - finalWidth - 6.0)
        let targetY = screen.frame.maxY - menuBarThickness - finalHeight - 2.0

        return NSRect(x: targetX, y: targetY, width: finalWidth, height: finalHeight)
    }

    // MARK: - Auto-Hide Countdown & Outside Click Monitors

    private func startAutoHideMonitoring() {
        stopAutoHideMonitoring()
        lastInteractionDate = Date()
        countdown.progress = 1.0

        autoHideTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self, self.isVisible else {
                    timer.invalidate()
                    return
                }

                // 1. Keep bar pinned while a mirrored NSMenu or drag-reorder is active
                if self.isPresentingMirroredMenu || MenuBarController.shared.draggingItemID != nil {
                    self.lastInteractionDate = Date()
                    if self.countdown.progress != 1.0 {
                        self.countdown.progress = 1.0
                    }
                    return
                }

                // 2. Keep bar anchored while the opened app's popover/panel window is still visible
                if self.trackedPopoverPID > 0 {
                    let age = CFAbsoluteTimeGetCurrent() - self.trackedPopoverOpenedAt
                    if age < 0.85 || self.hasOpenPopupWindow(for: self.trackedPopoverPID, baseline: self.trackedPopoverBaselineWinIDs) {
                        self.lastInteractionDate = Date()
                        if self.countdown.progress != 1.0 {
                            self.countdown.progress = 1.0
                        }
                        return
                    } else {
                        // Popover closed -> dismiss Ctrl + B cleanly as well
                        timer.invalidate()
                        self.hide()
                        return
                    }
                }

                let total = Double(MenuBarController.shared.autoHideDuration.rawValue)
                guard total > 0 else {
                    if self.countdown.progress != 1.0 {
                        self.countdown.progress = 1.0
                    }
                    return
                }

                // 3. Pause & reset countdown whenever cursor hovers inside the bar or over the ••• status icon
                let mousePt = NSEvent.mouseLocation
                let onPanel = (self.panel.map { NSMouseInRect(mousePt, $0.frame.insetBy(dx: -4, dy: -4), false) }) ?? false
                let onStatusIcon = (MenuBarController.shared.mainStatusItemFrameAppKit().map { NSMouseInRect(mousePt, $0.insetBy(dx: -4, dy: -4), false) }) ?? false
                if onPanel || onStatusIcon {
                    self.lastInteractionDate = Date()
                    if self.countdown.progress != 1.0 {
                        self.countdown.progress = 1.0
                    }
                    return
                }

                let elapsed = Date().timeIntervalSince(self.lastInteractionDate)
                if elapsed >= total {
                    timer.invalidate()
                    self.hide()
                    return
                }

                let remaining = max(0.0, 1.0 - (elapsed / total))
                if abs(self.countdown.progress - remaining) >= 0.015 {
                    self.countdown.progress = remaining
                }
            }
        }
    }

    private func stopAutoHideMonitoring() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isVisible, let panel = self.panel else { return }
                guard !self.isPresentingMirroredMenu else { return }

                let mouseLoc = NSEvent.mouseLocation
                if let statusRect = MenuBarController.shared.mainStatusItemFrameAppKit(),
                   NSMouseInRect(mouseLoc, statusRect.insetBy(dx: -2, dy: -2), false) {
                    return
                }
                if NSMouseInRect(mouseLoc, panel.frame, false) {
                    return
                }
                if self.trackedPopoverPID > 0, self.isMouseInsideWindow(ofPID: self.trackedPopoverPID, mouseAppKit: mouseLoc) {
                    return
                }
                self.hide()
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    private func hasOpenPopupWindow(for pid: pid_t, baseline: Set<Int>) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for w in list {
            let ownerPID = pid_t(w[kCGWindowOwnerPID as String] as? Int ?? 0)
            guard ownerPID == pid else { continue }
            let alpha = w[kCGWindowAlpha as String] as? Double ?? 1.0
            guard alpha > 0.05 else { continue }
            let wid = w[kCGWindowNumber as String] as? Int ?? 0
            if !baseline.contains(wid) {
                return true
            }
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            if layer > 0 && layer != 25 {
                return true
            }
        }
        return false
    }

    private func isMouseInsideWindow(ofPID pid: pid_t, mouseAppKit: NSPoint) -> Bool {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1440
        let mouseCG = CGPoint(x: mouseAppKit.x, y: primaryHeight - mouseAppKit.y)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for w in list {
            let ownerPID = pid_t(w[kCGWindowOwnerPID as String] as? Int ?? 0)
            guard ownerPID == pid else { continue }
            if let b = w[kCGWindowBounds as String] as? [String: Any],
               let x = b["X"] as? CGFloat,
               let y = b["Y"] as? CGFloat,
               let width = b["Width"] as? CGFloat,
               let height = b["Height"] as? CGFloat {
                let rect = CGRect(x: x, y: y, width: width, height: height).insetBy(dx: -8, dy: -8)
                if rect.contains(mouseCG) {
                    return true
                }
            }
        }
        return false
    }
}
