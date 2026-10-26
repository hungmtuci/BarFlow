import SwiftUI
import AppKit

@main
enum BarFlowMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Setup minimal Edit/Window menu so Cmd+W / Cmd+Q / Copy-Paste in search field work natively
        MainActor.assumeIsolated {
            delegate.installMainMenu()
        }
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static weak var shared: AppDelegate?
    private var selectionWindow: NSWindow?

    func installMainMenu() {
        let mainMenu = NSMenu()

        // App Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Chọn lọc ứng dụng Menu Bar...",
            action: #selector(openSelectionFromMenu),
            keyEquivalent: ","
        ).target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Ẩn BarFlow",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let quitItem = appMenu.addItem(
            withTitle: "Thoát BarFlow",
            action: #selector(quitFromMenu),
            keyEquivalent: "q"
        )
        quitItem.target = self
        appMenuItem.submenu = appMenu

        // Edit Menu (enables Cmd+A / Cmd+C / Cmd+V in search field)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Chỉnh sửa")
        editMenu.addItem(withTitle: "Hoàn tác", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Làm lại", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cắt", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Sao chép", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Dán", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Chọn tất cả", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        // Window Menu (enables Cmd+W to close selection window cleanly)
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Cửa sổ")
        windowMenu.addItem(withTitle: "Đóng cửa sổ", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Thu nhỏ", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenuItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func openSelectionFromMenu() {
        showSelectionWindow()
    }

    @objc private func quitFromMenu() {
        MenuBarController.shared.prepareForTermination()
        NSApp.terminate(nil)
    }

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
        menuController.onSecondaryAppsChanged = {
            barController.repositionIfVisible()
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

        if !AXIsProcessTrusted() {
            MenuBarScanner.shared.promptForAccessibilityPermission()
        }

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
        MenuBarController.shared.refreshRunningAppsAsync(forceFullScan: false)

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
