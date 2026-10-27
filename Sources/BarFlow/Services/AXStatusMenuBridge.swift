import Foundation
import AppKit
@preconcurrency import ApplicationServices

/// Bridges a hidden status item's Accessibility `AXMenu` (`kAXMenuRole`) into a native `NSMenu`
/// anchored directly underneath the clicked icon inside BarFlow's `Ctrl + B` Secondary Bar.
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

    private init() {}

    // MARK: - 1. Off-MainActor AXMenu Extraction

    /// Inspects `statusElement` (and any direct child button) for an attached `AXMenu` (`kAXMenuRole`).
    /// If `cancelSourceMenuAfterRead` is `true` (used when an app dynamically popped a menu at `(0, 30)`),
    /// sends `kAXCancelAction` to close the off-position native menu immediately after snapshotting its items.
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
        let items = readMenuItems(from: axMenu, table: table, depth: 0)
        if cancelSourceMenuAfterRead {
            _ = AXUIElementPerformAction(axMenu, kAXCancelAction as CFString)
        }
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

        // Check one level deeper (e.g. custom NSStatusBarButton wrapper hosting an AXMenu)
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
        depth: Int
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

            // Extract nested submenu if present
            var submenuItems: [MirroredMenuItem] = []
            var subRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(itemEl, kAXChildrenAttribute as CFString, &subRef) == .success,
               let subs = subRef as? [AXUIElement] {
                for sub in subs {
                    AXUIElementSetMessagingTimeout(sub, 0.12)
                    if axRole(of: sub) == (kAXMenuRole as String) {
                        submenuItems = readMenuItems(from: sub, table: table, depth: depth + 1)
                        break
                    }
                }
            }

            let isSeparator = (subrole == "AXSeparatorMenuItem") ||
                (title.isEmpty && !enabled && submenuItems.isEmpty)

            if isSeparator {
                // Collapse consecutive or leading/trailing redundant separators cleanly later
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

            // Skip completely empty invisible placeholder items
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

        // Trim leading/trailing/duplicate separators
        var cleaned: [MirroredMenuItem] = []
        cleaned.reserveCapacity(result.count)
        for item in result {
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

        // Carbon Menu.h kAXMenuItemCmdModifiersAttribute bitmask:
        // bit 0 (1): Shift, bit 1 (2): Option, bit 2 (4): Control, bit 3 (8): NoCommand
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

        if let view = anchorView, view.window != nil {
            // Pop up directly underneath the clicked icon inside BarFlow's `Ctrl + B` bar!
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

        return actionHandler.selectedNodeID
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
        return menu
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

    @objc func handleMenuItemSelected(_ sender: NSMenuItem) {
        selectedNodeID = sender.tag
    }
}
