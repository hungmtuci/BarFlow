import SwiftUI
import AppKit

@main
struct BarFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static weak var shared: AppDelegate?
    private var selectionWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self

        // Prevent duplicate Menu Bar instances if launched twice
        if let bundleID = Bundle.main.bundleIdentifier {
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ownPID }
            if let existing = others.first {
                existing.activate()
                NSApp.terminate(nil)
                return
            }
        }

        let menuController = MenuBarController.shared
        let barController = SecondaryBarController.shared
        let hotKeys = HotKeyService.shared

        menuController.applyDockPolicy()

        // Wire callbacks between MenuBarController, SecondaryBarController, and HotKeyService
        menuController.onToggleSecondaryBarRequested = {
            barController.toggle()
        }
        menuController.onHideSecondaryBarRequested = {
            barController.hide()
        }
        menuController.onOpenSelectionWindowRequested = { [weak self] in
            self?.showSelectionWindow()
        }

        hotKeys.onToggleSecondaryBar = {
            barController.toggle()
        }
        hotKeys.onEscapePressed = {
            barController.hide()
        }
        hotKeys.isSecondaryBarVisible = {
            barController.isVisible
        }
        hotKeys.registerHotKeys()

        menuController.start()

        // Prompt for Accessibility on first run if not trusted yet
        if !AXIsProcessTrusted() {
            MenuBarScanner.shared.promptForAccessibilityPermission()
        }

        // Show App Selection Window on launch ("Khi chạy sẽ cho chọn lọc những app nào đang chạy trên menu bar chính")
        if menuController.showSelectionOnLaunch || !AXIsProcessTrusted() {
            showSelectionWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSelectionWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyService.shared.unregisterHotKeys()
        MenuBarController.shared.prepareForTermination()
    }

    // MARK: - Selection Window Management

    func showSelectionWindow() {
        MenuBarController.shared.refreshRunningApps()

        if selectionWindow == nil {
            let rootView = AppSelectionView(
                menuController: MenuBarController.shared,
                barController: SecondaryBarController.shared
            )
            let hosting = NSHostingController(rootView: rootView)
            let win = NSWindow(contentViewController: hosting)
            win.title = "BarFlow — Chọn lọc ứng dụng Menu Bar"
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            win.titlebarAppearsTransparent = false
            win.isReleasedWhenClosed = false
            win.delegate = self
            win.setContentSize(NSSize(width: 780, height: 660))
            win.center()
            self.selectionWindow = win
        }

        // Temporarily ensure regular activation if hidden from Dock so window can take key focus cleanly
        if MenuBarController.shared.hideFromDock {
            NSApp.setActivationPolicy(.regular)
        }
        selectionWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if let closedWin = notification.object as? NSWindow, closedWin === selectionWindow {
            if MenuBarController.shared.hideFromDock {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    MenuBarController.shared.applyDockPolicy()
                }
            }
        }
    }
}
