import Foundation
import AppKit
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
    let countdown = SecondaryBarCountdownModel()

    private var panel: NonActivatingBarPanel?
    private var autoHideTimer: Timer?
    private var outsideClickMonitor: Any?
    private var localRightClickMonitor: Any?
    private var lastInteractionDate: Date = Date()
    private var lastWarmScanTimestamp: CFAbsoluteTime = 0

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

        let durationSeconds = Double(MenuBarController.shared.autoHideDuration.rawValue)
        guard durationSeconds > 0 else { return }

        autoHideTimer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self, self.isVisible else {
                    timer.invalidate()
                    return
                }

                let total = Double(MenuBarController.shared.autoHideDuration.rawValue)
                guard total > 0 else {
                    if self.countdown.progress != 1.0 {
                        self.countdown.progress = 1.0
                    }
                    return
                }

                // Pause & reset timer whenever cursor hovers inside the bar OR while dragging to reorder icons
                if MenuBarController.shared.draggingItemID != nil ||
                   (self.panel != nil && NSMouseInRect(NSEvent.mouseLocation, self.panel!.frame.insetBy(dx: -4, dy: -4), false)) {
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
                let mouseLoc = NSEvent.mouseLocation
                if let statusRect = MenuBarController.shared.mainStatusItemFrameAppKit(),
                   NSMouseInRect(mouseLoc, statusRect.insetBy(dx: -2, dy: -2), false) {
                    return
                }
                if !NSMouseInRect(mouseLoc, panel.frame, false) {
                    self.hide()
                }
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        if let rightMonitor = localRightClickMonitor {
            NSEvent.removeMonitor(rightMonitor)
            localRightClickMonitor = nil
        }
    }
}
