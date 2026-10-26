import Foundation
import AppKit
import SwiftUI

final class NonActivatingBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SecondaryBarController: ObservableObject {
    static let shared = SecondaryBarController()

    @Published private(set) var isVisible: Bool = false
    /// Countdown progress from 1.0 (full time remaining) down to 0.0 (auto-hide).
    @Published private(set) var countdownProgress: Double = 1.0
    @Published var isHoveringBar: Bool = false {
        didSet {
            if isHoveringBar {
                // Pause & reset timer while user's mouse is inside the bar
                lastInteractionDate = Date()
                countdownProgress = 1.0
            } else {
                lastInteractionDate = Date()
            }
        }
    }
    @Published var hoveredAppName: String? = nil
    @Published var hoveredItemID: String? = nil
    @Published var hoveredUtilityID: String? = nil

    private var panel: NonActivatingBarPanel?
    private var hostingView: NSHostingView<SecondaryBarView>?
    private var autoHideTimer: Timer?
    private var outsideClickMonitor: Any?
    private var lastInteractionDate: Date = Date()

    private init() {
        setupPanel()
    }

    private func setupPanel() {
        let initialRect = NSRect(x: 0, y: 0, width: 520, height: 64)
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

        let rootView = SecondaryBarView(
            barController: self,
            menuController: MenuBarController.shared
        )
        let host = NSHostingView(rootView: rootView)
        host.translatesAutoresizingMaskIntoConstraints = false
        p.contentView = host

        self.panel = p
        self.hostingView = host
    }

    // MARK: - Toggle / Show / Hide

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let panel = panel, let hostingView = hostingView else { return }

        // Refresh running apps so the bar always reflects live state
        MenuBarController.shared.refreshRunningApps()

        let screen = MenuBarScanner.screenContainingMouse()
        let hiddenCount = max(MenuBarController.shared.secondaryBarApps.count, 1)

        // Calculate ideal columns & size so it sits sleekly right below the Menu Bar
        let maxPerRow = min(max(Int((screen.frame.width - 140) / 42), 6), 14)
        let columns = min(hiddenCount, maxPerRow)
        let rows = Int(ceil(Double(hiddenCount) / Double(maxPerRow)))

        // Let SwiftUI compute exact fitting size
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        let computedWidth = max(fitting.width, CGFloat(columns) * 40 + 110)
        let finalWidth = min(computedWidth, screen.frame.width - 28)
        let finalHeight = max(fitting.height, rows > 1 ? 98 : 58)

        // Compute Menu Bar height on this screen
        let menuBarThickness = max(screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness, 28)
        let targetY = screen.frame.maxY - menuBarThickness - finalHeight - 4

        // Anchor below BarFlow's status item if it sits on this screen; otherwise align cleanly toward top-right of screen
        var targetX: CGFloat
        if let statusRect = MenuBarController.shared.mainStatusItemFrameAppKit(),
           NSIntersectsRect(statusRect, screen.frame) {
            targetX = statusRect.midX - (finalWidth * 0.65)
        } else {
            targetX = screen.frame.maxX - finalWidth - 18
        }
        // Clamp strictly within screen horizontal bounds
        targetX = max(screen.frame.minX + 14, min(targetX, screen.frame.maxX - finalWidth - 14))

        let startFrame = NSRect(x: targetX, y: targetY + 8, width: finalWidth, height: finalHeight)
        let targetFrame = NSRect(x: targetX, y: targetY, width: finalWidth, height: finalHeight)

        panel.setFrame(startFrame, display: true)
        panel.alphaValue = 0.0
        panel.orderFrontRegardless()

        isVisible = true
        hoveredAppName = nil
        MenuBarController.shared.updateMainButtonAppearance(isSecondaryOpen: true)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = 1.0
        }

        startAutoHideMonitoring()
        installOutsideClickMonitor()
    }

    func hide() {
        guard isVisible, let panel = panel else { return }

        stopAutoHideMonitoring()
        removeOutsideClickMonitor()
        isVisible = false
        isHoveringBar = false
        hoveredAppName = nil
        MenuBarController.shared.updateMainButtonAppearance(isSecondaryOpen: false)

        let endFrame = panel.frame.offsetBy(dx: 0, dy: 6)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.13
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(endFrame, display: false)
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                if self?.isVisible == false {
                    panel.orderOut(nil)
                }
            }
        })
    }

    // MARK: - Auto-Hide Countdown & Outside Click Monitors

    private func startAutoHideMonitoring() {
        stopAutoHideMonitoring()
        lastInteractionDate = Date()
        countdownProgress = 1.0

        let durationSeconds = Double(MenuBarController.shared.autoHideDuration.rawValue)
        guard durationSeconds > 0 else {
            countdownProgress = 1.0
            return
        }

        autoHideTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self, self.isVisible else {
                    timer.invalidate()
                    return
                }

                let total = Double(MenuBarController.shared.autoHideDuration.rawValue)
                guard total > 0 else {
                    self.countdownProgress = 1.0
                    return
                }

                // Also check physical mouse rect so hover detection is 100% reliable even without key focus
                if let p = self.panel, NSMouseInRect(NSEvent.mouseLocation, p.frame.insetBy(dx: -4, dy: -4), false) {
                    self.lastInteractionDate = Date()
                    self.countdownProgress = 1.0
                    return
                }

                let elapsed = Date().timeIntervalSince(self.lastInteractionDate)
                let remaining = max(0.0, 1.0 - (elapsed / total))
                self.countdownProgress = remaining

                if elapsed >= total {
                    timer.invalidate()
                    self.hide()
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
                // Ignore clicks directly on BarFlow's main status item button (it handles its own toggle)
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
    }
}
