import Foundation
import AppKit
@preconcurrency import ApplicationServices

/// Bridges a hidden status item's Accessibility `AXMenu` (`kAXMenuRole`) — using instant 1-level snapshots
/// and lazy on-demand `NSMenuDelegate` submenus so apps with huge folder trees (e.g. Default Folder X) open in < 10ms —
/// or synthesizes a native Application Menu anchored directly underneath the clicked icon in `Ctrl + B`.
final class AXStatusMenuBridge: @unchecked Sendable {
    static let shared = AXStatusMenuBridge()

    struct MirroredMenuSnapshot: Sendable {
        let items: [MirroredMenuItem]
        let wasTruncated: Bool
        fileprivate let elementTable: AXElementTable
    }

    struct MirroredMenuItem: Sendable {
        let nodeID: Int
        let isSeparator: Bool
        let title: String
        let isEnabled: Bool
        let stateRaw: Int // 1 = on, -1 = mixed, 0 = off
        let keyEquivalent: String
        let modifierMaskRaw: UInt
        /// Non-zero when this item owns a child `AXMenu` (`kAXMenuRole`) to be expanded lazily on hover.
        let submenuAXID: Int
    }

    enum MirroredMenuSelection: Sendable {
        case axNode(Int, String)
        case quitAppExplicitly
    }

    enum SynthesizedMenuChoice: Sendable {
        case axNode(Int, String, MirroredMenuSnapshot)
        case openAppUI
        case openCloudFolder(URL)
        case pinToMainBar
        case quitApp
    }

    fileprivate final class AXElementTable: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Int: AXUIElement] = [:]
        private var nextID: Int = 1

        func register(_ element: AXUIElement) -> Int {
            lock.lock()
            defer { lock.unlock() }
            let id = nextID
            nextID += 1
            storage[id] = element
            return id
        }

        func element(for id: Int) -> AXUIElement? {
            lock.lock()
            defer { lock.unlock() }
            return storage[id]
        }
    }

    private static let skippedBoilerplateTitles: Set<String> = [
        "services", "dịch vụ",
        "hide others", "ẩn các ứng dụng khác", "ẩn các mục khác",
        "show all", "hiển thị tất cả",
        "undo", "hoàn tác",
        "redo", "làm lại",
        "cut", "cắt",
        "copy", "sao chép",
        "paste", "dán",
        "paste and match style",
        "delete", "xoá",
        "select all", "chọn tất cả",
        "close", "close all", "đóng",
        "autofill", "tự động điền",
        "start dictation", "bắt đầu đọc chính tả",
        "emoji & symbols", "biểu tượng & ký tự"
    ]

    private init() {}

    // MARK: - 1. Instant 1-Level `AXMenu` Extraction (Lazy Submenus Expanded Only on Hover!)

    /// Inspects `statusElement` (and any direct child button) for an attached `AXMenu` (`kAXMenuRole`).
    /// Reads ONLY the top-level menu items (~1–12ms), deferring all nested submenus (`Computer ▸`, `Favorites ▸`, etc.)
    /// to lazy `NSMenuDelegate` expansion when hovered.
    func captureMenuSnapshot(
        from statusElement: AXUIElement,
        cancelSourceMenuAfterRead: Bool = false
    ) -> MirroredMenuSnapshot? {
        AXUIElementSetMessagingTimeout(statusElement, 0.14)
        guard let axMenu = findAXMenuElement(in: statusElement) else {
            return nil
        }

        let table = AXElementTable()
        let loaded = readSingleMenuLevel(
            from: axMenu,
            table: table,
            filterAppBoilerplate: false,
            maxItems: 120,
            wallClockBudget: 0.35
        )
        if cancelSourceMenuAfterRead {
            _ = AXUIElementPerformAction(axMenu, kAXCancelAction as CFString)
        }
        guard !loaded.items.isEmpty else { return nil }
        return MirroredMenuSnapshot(items: loaded.items, wasTruncated: loaded.wasTruncated, elementTable: table)
    }

    /// Reads the target process's native macOS Application Menu (`kAXMenuBarAttribute` -> `children[1]`,
    /// e.g. `About`, `Settings… / Preferences…`, `Lock`, `Check for Updates…`, `Quit <App>`) for apps
    /// like `1Password 7`, `OneDrive`, `Google Drive`, `Dropbox`, `Caffeine`, `Maccy`, `Claude`, etc.
    func captureApplicationMenuSnapshot(forPID pid: pid_t) -> MirroredMenuSnapshot? {
        guard pid > 0 else { return nil }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.16)

        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBar = menuBarRef else {
            return nil
        }

        var topItemsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar as! AXUIElement, kAXChildrenAttribute as CFString, &topItemsRef) == .success,
              let topItems = topItemsRef as? [AXUIElement],
              topItems.count >= 2 else {
            return nil
        }

        let appMenuBarItem = topItems[1]
        AXUIElementSetMessagingTimeout(appMenuBarItem, 0.14)
        guard let appAXMenu = findAXMenuElement(in: appMenuBarItem) else {
            return nil
        }

        let table = AXElementTable()
        let loaded = readSingleMenuLevel(
            from: appAXMenu,
            table: table,
            filterAppBoilerplate: true,
            maxItems: 80,
            wallClockBudget: 0.30
        )
        guard !loaded.items.isEmpty else { return nil }
        return MirroredMenuSnapshot(items: loaded.items, wasTruncated: loaded.wasTruncated, elementTable: table)
    }

    private func findAXMenuElement(in element: AXUIElement) -> AXUIElement? {
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement], !children.isEmpty else {
            return nil
        }

        for child in children {
            AXUIElementSetMessagingTimeout(child, 0.10)
            if axRole(of: child) == (kAXMenuRole as String) {
                return child
            }
        }

        for child in children {
            var grandRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &grandRef) == .success,
               let grandChildren = grandRef as? [AXUIElement] {
                for grand in grandChildren {
                    AXUIElementSetMessagingTimeout(grand, 0.10)
                    if axRole(of: grand) == (kAXMenuRole as String) {
                        return grand
                    }
                }
            }
        }
        return nil
    }

    private func findDirectChildAXMenu(of itemEl: AXUIElement) -> AXUIElement? {
        var subRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(itemEl, kAXChildrenAttribute as CFString, &subRef) == .success,
              let subs = subRef as? [AXUIElement], !subs.isEmpty else {
            return nil
        }
        for sub in subs {
            AXUIElementSetMessagingTimeout(sub, 0.08)
            if axRole(of: sub) == (kAXMenuRole as String) {
                return sub
            }
        }
        return nil
    }

    /// Reads ONLY one `AXMenu` level with strict item count & wall-clock limits so large filesystem/cloud menus
    /// never stall `BarFlow` or lock out other icons.
    fileprivate func readSingleMenuLevel(
        from axMenu: AXUIElement,
        table: AXElementTable,
        filterAppBoilerplate: Bool,
        maxItems: Int,
        wallClockBudget: CFAbsoluteTime
    ) -> (items: [MirroredMenuItem], wasTruncated: Bool) {
        let deadline = CFAbsoluteTimeGetCurrent() + wallClockBudget
        AXUIElementSetMessagingTimeout(axMenu, min(0.16, Float(wallClockBudget)))

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axMenu, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement], !children.isEmpty else {
            return ([], false)
        }

        var result: [MirroredMenuItem] = []
        result.reserveCapacity(min(children.count, maxItems))
        var wasTruncated = false

        for (idx, itemEl) in children.enumerated() {
            if result.count >= maxItems || (idx > 0 && CFAbsoluteTimeGetCurrent() >= deadline) {
                wasTruncated = true
                break
            }

            AXUIElementSetMessagingTimeout(itemEl, 0.08)
            let subrole = axString(itemEl, kAXSubroleAttribute as CFString) ?? ""
            let title = axString(itemEl, kAXTitleAttribute as CFString) ?? ""
            let enabled = axBool(itemEl, kAXEnabledAttribute as CFString, defaultValue: true)

            if filterAppBoilerplate && !title.isEmpty {
                let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if Self.skippedBoilerplateTitles.contains(normalized) {
                    continue
                }
            }

            let childSubmenu = findDirectChildAXMenu(of: itemEl)
            let submenuAXID = childSubmenu.map { table.register($0) } ?? 0

            let isSeparator = (subrole == "AXSeparatorMenuItem") ||
                (title.isEmpty && !enabled && submenuAXID == 0)

            if isSeparator {
                result.append(
                    MirroredMenuItem(
                        nodeID: 0,
                        isSeparator: true,
                        title: "",
                        isEnabled: false,
                        stateRaw: 0,
                        keyEquivalent: "",
                        modifierMaskRaw: 0,
                        submenuAXID: 0
                    )
                )
                continue
            }

            if title.isEmpty && submenuAXID == 0 {
                continue
            }

            let mark = axString(itemEl, kAXMenuItemMarkCharAttribute as CFString) ?? ""
            let stateRaw: Int
            if mark == "✓" || mark == "✔" || mark == "•" {
                stateRaw = 1
            } else if mark == "-" || mark == "—" {
                stateRaw = -1
            } else {
                stateRaw = 0
            }

            let rawCmd = axString(itemEl, kAXMenuItemCmdCharAttribute as CFString) ?? ""
            let cmdMods = axInt(itemEl, kAXMenuItemCmdModifiersAttribute as CFString) ?? 0
            let (keyEq, modMask) = decodeShortcut(cmdChar: rawCmd, carbonModifiers: cmdMods)

            let nodeID = table.register(itemEl)
            result.append(
                MirroredMenuItem(
                    nodeID: nodeID,
                    isSeparator: false,
                    title: title,
                    isEnabled: enabled,
                    stateRaw: stateRaw,
                    keyEquivalent: keyEq,
                    modifierMaskRaw: modMask.rawValue,
                    submenuAXID: submenuAXID
                )
            )
        }

        return (normalizeSeparators(in: result), wasTruncated)
    }

    private func normalizeSeparators(in raw: [MirroredMenuItem]) -> [MirroredMenuItem] {
        var cleaned: [MirroredMenuItem] = []
        cleaned.reserveCapacity(raw.count)
        for item in raw {
            if item.isSeparator {
                if cleaned.isEmpty || cleaned.last?.isSeparator == true {
                    continue
                }
            }
            cleaned.append(item)
        }
        if cleaned.last?.isSeparator == true {
            cleaned.removeLast()
        }
        return cleaned
    }

    private func decodeShortcut(cmdChar: String, carbonModifiers: Int) -> (String, NSEvent.ModifierFlags) {
        let trimmed = cmdChar.trimmingCharacters(in: .newlines)
        guard trimmed.count == 1 else { return ("", []) }

        var mask: NSEvent.ModifierFlags = (carbonModifiers & 8) == 0 ? [.command] : []
        if (carbonModifiers & 1) != 0 { mask.insert(.shift) }
        if (carbonModifiers & 2) != 0 { mask.insert(.option) }
        if (carbonModifiers & 4) != 0 { mask.insert(.control) }
        return (trimmed.lowercased(), mask)
    }

    // MARK: - 2. MainActor Native NSMenu Presentation Right Under Clicked Icon

    @MainActor
    func presentMirroredMenu(
        _ snapshot: MirroredMenuSnapshot,
        includeGuaranteedQuitForAppName: String? = nil,
        anchorView: NSView?,
        anchorScreenRectAppKit: NSRect?
    ) -> MirroredMenuSelection? {
        let actionHandler = MenuSelectionBox()
        let nsMenu = NSMenu()
        nsMenu.autoenablesItems = false
        nsMenu.minimumWidth = 170

        appendMirroredItems(
            snapshot.items,
            wasTruncated: snapshot.wasTruncated,
            depth: 0,
            table: snapshot.elementTable,
            into: nsMenu,
            handler: actionHandler
        )

        if let appName = includeGuaranteedQuitForAppName {
            let hasTopLevelQuit = snapshot.items.contains { node in
                guard node.isEnabled else { return false }
                let lower = node.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return lower.hasPrefix("quit") || lower.contains("thoát")
            }
            if !hasTopLevelQuit {
                nsMenu.addItem(.separator())
                let quitItem = NSMenuItem(
                    title: "Thoát \(appName)",
                    action: #selector(MenuSelectionBox.handleQuitApp),
                    keyEquivalent: "q"
                )
                quitItem.keyEquivalentModifierMask = [.command]
                quitItem.target = actionHandler
                nsMenu.addItem(quitItem)
            }
        }

        popUpMenu(nsMenu, anchorView: anchorView, anchorScreenRectAppKit: anchorScreenRectAppKit)

        if let nodeID = actionHandler.selectedNodeID {
            return .axNode(nodeID, actionHandler.selectedNodeTitle)
        }
        if actionHandler.synthesizedChoice != nil {
            return .quitAppExplicitly
        }
        return nil
    }

    /// Presents a native right-click Application Menu for popover-based or `WindowMenuBarExtraStyle` apps
    /// (`1Password 7`, `OneDrive`, `Google Drive`, `Dropbox`, `Caffeine`, `Maccy`, `Claude`, `Itsycal`, etc.)
    /// so Right-Click ALWAYS shows Open / Preferences / Lock / Quit (`Thoát`) right under the icon!
    @MainActor
    func presentSynthesizedAppMenu(
        for item: MenuBarAppItem,
        appMenuSnapshot: MirroredMenuSnapshot?,
        cloudFolderURL: URL?,
        includeOpenNoteForMenuBarExtra: Bool = false,
        anchorView: NSView?,
        anchorScreenRectAppKit: NSRect?
    ) -> SynthesizedMenuChoice? {
        let handler = MenuSelectionBox()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = 195

        // 1. Cloud sync folder shortcut first if applicable (OneDrive / Google Drive / Dropbox), plus Open App UI
        if let folderURL = cloudFolderURL {
            handler.cloudFolderURL = folderURL
            let folderItem = NSMenuItem(
                title: "Mở thư mục \(item.appName) trong Finder",
                action: #selector(MenuSelectionBox.handleOpenCloudFolder),
                keyEquivalent: ""
            )
            folderItem.target = handler
            menu.addItem(folderItem)
        }

        let openItem = NSMenuItem(
            title: "Mở \(item.appName)",
            action: #selector(MenuSelectionBox.handleOpenAppUI),
            keyEquivalent: ""
        )
        openItem.target = handler
        menu.addItem(openItem)

        // 2. App's native Application Menu items (About, Settings…/Preferences…, Lock, Check for Updates…, Quit)
        var hasEnabledNativeQuit = false
        if let snap = appMenuSnapshot, !snap.items.isEmpty {
            menu.addItem(.separator())
            appendMirroredItems(
                snap.items,
                wasTruncated: snap.wasTruncated,
                depth: 0,
                table: snap.elementTable,
                into: menu,
                handler: handler
            )
            hasEnabledNativeQuit = snap.items.contains { node in
                guard node.isEnabled else { return false }
                let lower = node.title.lowercased()
                return lower.hasPrefix("quit") || lower.contains("thoát")
            }
        }

        // 3. Quick Pin to Main Menu Bar
        menu.addItem(.separator())
        let pinTitle = includeOpenNoteForMenuBarExtra
            ? "Đưa \(item.appName) lên Menu Bar chính (để mở Popover gốc)"
            : "Đưa \(item.appName) lên Menu Bar chính"
        let pinItem = NSMenuItem(
            title: pinTitle,
            action: #selector(MenuSelectionBox.handlePinToMainBar),
            keyEquivalent: ""
        )
        pinItem.target = handler
        menu.addItem(pinItem)

        // 4. Guaranteed Quit (`Thoát <App>`) item so user can ALWAYS quit any hidden app
        if !hasEnabledNativeQuit {
            menu.addItem(.separator())
            let quitItem = NSMenuItem(
                title: "Thoát \(item.appName)",
                action: #selector(MenuSelectionBox.handleQuitApp),
                keyEquivalent: "q"
            )
            quitItem.keyEquivalentModifierMask = [.command]
            quitItem.target = handler
            menu.addItem(quitItem)
        }

        popUpMenu(menu, anchorView: anchorView, anchorScreenRectAppKit: anchorScreenRectAppKit)

        if let nodeID = handler.selectedNodeID, let snap = appMenuSnapshot {
            return .axNode(nodeID, handler.selectedNodeTitle, snap)
        }
        return handler.synthesizedChoice
    }

    @MainActor
    private func popUpMenu(_ nsMenu: NSMenu, anchorView: NSView?, anchorScreenRectAppKit: NSRect?) {
        if let view = anchorView, let win = view.window, win.isVisible {
            let anchorPt = NSPoint(x: 0, y: -4)
            _ = nsMenu.popUp(positioning: nil, at: anchorPt, in: view)
        } else {
            let screenPt: NSPoint
            if let rect = anchorScreenRectAppKit, rect.width > 0 {
                screenPt = NSPoint(x: rect.minX, y: rect.minY - 4)
            } else {
                screenPt = NSEvent.mouseLocation
            }
            _ = nsMenu.popUp(positioning: nil, at: screenPt, in: nil)
        }
    }

    /// Executes `AXPress` (`kAXPressAction` or `kAXPickAction`) on the user's chosen `AXMenuItem`.
    func performSelectedMenuNode(_ nodeID: Int, in snapshot: MirroredMenuSnapshot) {
        guard let element = snapshot.elementTable.element(for: nodeID) else { return }
        AXUIElementSetMessagingTimeout(element, 0.35)
        let rc = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if rc != .success && rc != .cannotComplete {
            _ = AXUIElementPerformAction(element, kAXPickAction as CFString)
        }
    }

    @MainActor
    fileprivate func appendMirroredItems(
        _ items: [MirroredMenuItem],
        wasTruncated: Bool,
        depth: Int,
        table: AXElementTable,
        into menu: NSMenu,
        handler: MenuSelectionBox
    ) {
        for node in items {
            if node.isSeparator {
                menu.addItem(.separator())
                continue
            }

            let nsItem = NSMenuItem(
                title: node.title,
                action: nil,
                keyEquivalent: node.keyEquivalent
            )
            if !node.keyEquivalent.isEmpty {
                nsItem.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: node.modifierMaskRaw)
            }
            if node.stateRaw > 0 {
                nsItem.state = .on
            } else if node.stateRaw < 0 {
                nsItem.state = .mixed
            } else {
                nsItem.state = .off
            }
            nsItem.isEnabled = node.isEnabled

            if node.submenuAXID > 0 && depth < 12 {
                let subMenu = NSMenu(title: node.title)
                subMenu.autoenablesItems = false
                let delegate = LazyAXSubmenuDelegate(
                    submenuAXID: node.submenuAXID,
                    depth: depth + 1,
                    table: table,
                    handler: handler
                )
                handler.retainedDelegates.append(delegate)
                subMenu.delegate = delegate
                nsItem.submenu = subMenu

                // Inside cascading folder menus (depth >= 1, e.g. Default Folder X's Favorites/Recent Folders),
                // allow clicking directly on a folder item itself while hovering still opens its subfolders!
                if depth >= 1 && node.isEnabled && node.nodeID > 0 {
                    nsItem.tag = node.nodeID
                    nsItem.target = handler
                    nsItem.action = #selector(MenuSelectionBox.handleMenuItemSelected(_:))
                }
            } else if node.isEnabled && node.nodeID > 0 {
                nsItem.tag = node.nodeID
                nsItem.target = handler
                nsItem.action = #selector(MenuSelectionBox.handleMenuItemSelected(_:))
            }

            menu.addItem(nsItem)
        }

        if wasTruncated {
            menu.addItem(.separator())
            let moreItem = NSMenuItem(
                title: "… (Đã rút gọn danh sách lớn)",
                action: nil,
                keyEquivalent: ""
            )
            moreItem.isEnabled = false
            menu.addItem(moreItem)
        }
    }

    // MARK: - Low-Level AX Attribute Readers

    private func axRole(of el: AXUIElement) -> String? {
        axString(el, kAXRoleAttribute as CFString)
    }

    private func axString(_ el: AXUIElement, _ attr: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr, &ref) == .success else { return nil }
        return ref as? String
    }

    private func axBool(_ el: AXUIElement, _ attr: CFString, defaultValue: Bool) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr, &ref) == .success, let val = ref else {
            return defaultValue
        }
        if CFGetTypeID(val) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((val as! CFBoolean))
        }
        return (val as? NSNumber)?.boolValue ?? defaultValue
    }

    private func axInt(_ el: AXUIElement, _ attr: CFString) -> Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr, &ref) == .success, let num = ref else {
            return nil
        }
        return num.intValue
    }
}

@MainActor
private final class LazyAXSubmenuDelegate: NSObject, NSMenuDelegate {
    private let submenuAXID: Int
    private let depth: Int
    private let table: AXStatusMenuBridge.AXElementTable
    private weak var handler: MenuSelectionBox?
    private var didPopulate = false

    init(
        submenuAXID: Int,
        depth: Int,
        table: AXStatusMenuBridge.AXElementTable,
        handler: MenuSelectionBox
    ) {
        self.submenuAXID = submenuAXID
        self.depth = depth
        self.table = table
        self.handler = handler
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard !didPopulate else { return }
        didPopulate = true
        menu.removeAllItems()

        guard let handler = handler,
              let axMenu = table.element(for: submenuAXID) else {
            let empty = NSMenuItem(title: "(Trống)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        let loaded = AXStatusMenuBridge.shared.readSingleMenuLevel(
            from: axMenu,
            table: table,
            filterAppBoilerplate: false,
            maxItems: 90,
            wallClockBudget: 0.28
        )

        if loaded.items.isEmpty {
            let empty = NSMenuItem(title: "(Trống)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        AXStatusMenuBridge.shared.appendMirroredItems(
            loaded.items,
            wasTruncated: loaded.wasTruncated,
            depth: depth,
            table: table,
            into: menu,
            handler: handler
        )
    }
}

@MainActor
private final class MenuSelectionBox: NSObject {
    var selectedNodeID: Int? = nil
    var selectedNodeTitle: String = ""
    var synthesizedChoice: AXStatusMenuBridge.SynthesizedMenuChoice? = nil
    var cloudFolderURL: URL? = nil
    var retainedDelegates: [LazyAXSubmenuDelegate] = []

    @objc func handleMenuItemSelected(_ sender: NSMenuItem) {
        selectedNodeID = sender.tag
        selectedNodeTitle = sender.title
    }

    @objc func handleOpenAppUI() {
        synthesizedChoice = .openAppUI
    }

    @objc func handleOpenCloudFolder() {
        if let url = cloudFolderURL {
            synthesizedChoice = .openCloudFolder(url)
        }
    }

    @objc func handlePinToMainBar() {
        synthesizedChoice = .pinToMainBar
    }

    @objc func handleQuitApp() {
        synthesizedChoice = .quitApp
    }
}
