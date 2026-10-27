import Foundation
import AppKit
@preconcurrency import ApplicationServices

/// Bridges a hidden status item's Accessibility `AXMenu` (`kAXMenuRole`) — or synthesizes a native
/// Application Menu (with Settings / Lock / Quit) — anchored directly underneath the clicked icon in `Ctrl + B`.
final class AXStatusMenuBridge: @unchecked Sendable {
    static let shared = AXStatusMenuBridge()

    struct MirroredMenuSnapshot: Sendable {
        let items: [MirroredMenuItem]
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
        let submenuItems: [MirroredMenuItem]
    }

    enum SynthesizedMenuChoice: Sendable {
        case axNode(Int, String, MirroredMenuSnapshot)
        case openAppUI
        case openCloudFolder(URL)
        case pinToMainBar
        case quitApp
    }

    fileprivate final class AXElementTable: @unchecked Sendable {
        private var storage: [Int: AXUIElement] = [:]
        private var nextID: Int = 1

        func register(_ element: AXUIElement) -> Int {
            let id = nextID
            nextID += 1
            storage[id] = element
            return id
        }

        func element(for id: Int) -> AXUIElement? {
            storage[id]
        }
    }

    private static let skippedBoilerplateTitles: Set<String> = [
        "services", "dịch vụ",
        "hide others", "ẩn các ứng dụng khác",
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

    // MARK: - 1. Off-MainActor Status Item `AXMenu` Extraction

    /// Inspects `statusElement` (and any direct child button) for an attached `AXMenu` (`kAXMenuRole`).
    func captureMenuSnapshot(
        from statusElement: AXUIElement,
        cancelSourceMenuAfterRead: Bool = false
    ) -> MirroredMenuSnapshot? {
        AXUIElementSetMessagingTimeout(statusElement, 0.16)
        guard let axMenu = findAXMenuElement(in: statusElement) else {
            return nil
        }

        AXUIElementSetMessagingTimeout(axMenu, 0.16)
        let table = AXElementTable()
        let items = readMenuItems(from: axMenu, table: table, depth: 0, filterAppBoilerplate: false)
        if cancelSourceMenuAfterRead {
            _ = AXUIElementPerformAction(axMenu, kAXCancelAction as CFString)
        }
        guard !items.isEmpty else { return nil }
        return MirroredMenuSnapshot(items: items, elementTable: table)
    }

    /// Reads the target process's native macOS Application Menu (`kAXMenuBarAttribute` -> `children[1]`,
    /// e.g. `About`, `Settings… / Preferences…`, `Lock`, `Check for Updates…`, `Quit <App>`) for apps
    /// like `1Password 7`, `OneDrive`, `Google Drive`, `Caffeine`, `Maccy`, etc. whose status item uses a custom popover.
    func captureApplicationMenuSnapshot(forPID pid: pid_t) -> MirroredMenuSnapshot? {
        guard pid > 0 else { return nil }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.18)

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
        AXUIElementSetMessagingTimeout(appMenuBarItem, 0.15)
        guard let appAXMenu = findAXMenuElement(in: appMenuBarItem) else {
            return nil
        }

        let table = AXElementTable()
        let items = readMenuItems(from: appAXMenu, table: table, depth: 0, filterAppBoilerplate: true)
        guard !items.isEmpty else { return nil }
        return MirroredMenuSnapshot(items: items, elementTable: table)
    }

    private func findAXMenuElement(in element: AXUIElement) -> AXUIElement? {
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement], !children.isEmpty else {
            return nil
        }

        for child in children {
            AXUIElementSetMessagingTimeout(child, 0.12)
            if axRole(of: child) == (kAXMenuRole as String) {
                return child
            }
        }

        for child in children {
            var grandRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &grandRef) == .success,
               let grandChildren = grandRef as? [AXUIElement] {
                for grand in grandChildren {
                    AXUIElementSetMessagingTimeout(grand, 0.12)
                    if axRole(of: grand) == (kAXMenuRole as String) {
                        return grand
                    }
                }
            }
        }
        return nil
    }

    private func readMenuItems(
        from axMenu: AXUIElement,
        table: AXElementTable,
        depth: Int,
        filterAppBoilerplate: Bool
    ) -> [MirroredMenuItem] {
        guard depth <= 4 else { return [] }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axMenu, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement], !children.isEmpty else {
            return []
        }

        var result: [MirroredMenuItem] = []
        result.reserveCapacity(children.count)

        for itemEl in children {
            AXUIElementSetMessagingTimeout(itemEl, 0.12)
            let subrole = axString(itemEl, kAXSubroleAttribute as CFString) ?? ""
            let title = axString(itemEl, kAXTitleAttribute as CFString) ?? ""
            let enabled = axBool(itemEl, kAXEnabledAttribute as CFString, defaultValue: true)

            if filterAppBoilerplate && depth == 0 && !title.isEmpty {
                let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if Self.skippedBoilerplateTitles.contains(normalized) {
                    continue
                }
            }

            var submenuItems: [MirroredMenuItem] = []
            var subRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(itemEl, kAXChildrenAttribute as CFString, &subRef) == .success,
               let subs = subRef as? [AXUIElement] {
                for sub in subs {
                    AXUIElementSetMessagingTimeout(sub, 0.12)
                    if axRole(of: sub) == (kAXMenuRole as String) {
                        submenuItems = readMenuItems(
                            from: sub,
                            table: table,
                            depth: depth + 1,
                            filterAppBoilerplate: false
                        )
                        break
                    }
                }
            }

            let isSeparator = (subrole == "AXSeparatorMenuItem") ||
                (title.isEmpty && !enabled && submenuItems.isEmpty)

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
                        submenuItems: []
                    )
                )
                continue
            }

            if title.isEmpty && submenuItems.isEmpty {
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
                    submenuItems: submenuItems
                )
            )
        }

        return normalizeSeparators(in: result)
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
        anchorView: NSView?,
        anchorScreenRectAppKit: NSRect?
    ) -> Int? {
        let actionHandler = MenuSelectionBox()
        let nsMenu = buildNSMenu(from: snapshot.items, handler: actionHandler)
        nsMenu.minimumWidth = 170

        popUpMenu(nsMenu, anchorView: anchorView, anchorScreenRectAppKit: anchorScreenRectAppKit)
        return actionHandler.selectedNodeID
    }

    /// Presents a native right-click Application Menu for popover-based or `WindowMenuBarExtraStyle` apps
    /// (`1Password 7`, `OneDrive`, `Google Drive`, `Caffeine`, `Maccy`, `AdGuard`, `Itsycal`, etc.)
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
            appendMirroredItems(snap.items, into: menu, handler: handler)
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
        if let view = anchorView, view.window != nil {
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
    private func buildNSMenu(from items: [MirroredMenuItem], handler: MenuSelectionBox) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        appendMirroredItems(items, into: menu, handler: handler)
        return menu
    }

    @MainActor
    private func appendMirroredItems(_ items: [MirroredMenuItem], into menu: NSMenu, handler: MenuSelectionBox) {
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

            if !node.submenuItems.isEmpty {
                nsItem.submenu = buildNSMenu(from: node.submenuItems, handler: handler)
            } else if node.isEnabled && node.nodeID > 0 {
                nsItem.tag = node.nodeID
                nsItem.target = handler
                nsItem.action = #selector(MenuSelectionBox.handleMenuItemSelected(_:))
            }

            menu.addItem(nsItem)
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
        guard AXUIElementCopyAttributeValue(el, attr, &ref) == .success, let num = ref as? NSNumber else {
            return nil
        }
        return num.intValue
    }
}

@MainActor
private final class MenuSelectionBox: NSObject {
    var selectedNodeID: Int? = nil
    var selectedNodeTitle: String = ""
    var synthesizedChoice: AXStatusMenuBridge.SynthesizedMenuChoice? = nil
    var cloudFolderURL: URL? = nil

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
