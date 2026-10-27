import SwiftUI
import AppKit

/// Native AppKit frosted glass backdrop matching the macOS Menu Bar material.
struct FrostedBarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Lightweight per-button hover state box (avoids @State macro & avoids re-rendering parent views).
final class LocalHoverBox: ObservableObject {
    @Published var isHovered: Bool = false
}

struct SecondaryBarView: View {
    @ObservedObject var barController: SecondaryBarController
    @ObservedObject var menuController: MenuBarController

    var body: some View {
        if !barController.isVisible {
            // Zero layout & rendering overhead while the Ctrl + B panel is hidden
            Color.clear
                .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)
        } else {
            visibleBarContent
        }
    }

    private var visibleBarContent: some View {
        let apps = menuController.secondaryBarApps
        let activeID = barController.activeOpenedItemID
        let draggingID = menuController.draggingItemID

        return HStack(spacing: 5) {
            if !menuController.isAccessibilityGranted {
                Button {
                    barController.hide()
                    MenuBarScanner.shared.promptForAccessibilityPermission(openSystemSettings: true)
                    menuController.onOpenSelectionWindowRequested?()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                        Text("Cấp quyền Accessibility để hiện app")
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 26)
                }
                .buttonStyle(.plain)
            } else if apps.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                    Text("Không có ứng dụng ẩn")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .frame(height: 26)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: SecondaryBarController.iconSpacing) {
                        ForEach(Array(apps.enumerated()), id: \.element.id) { index, item in
                            SecondaryBarIconSlotRepresentable(
                                item: item,
                                index: index,
                                totalCount: apps.count,
                                isActiveOpened: activeID == item.id,
                                isBeingDragged: draggingID == item.id,
                                menuController: menuController
                            )
                            .frame(
                                width: SecondaryBarController.iconSlotSize,
                                height: SecondaryBarController.iconSlotSize
                            )
                        }
                    }
                }
                .frame(height: SecondaryBarController.iconSlotSize)
            }

            Divider()
                .frame(height: 16)

            SecondaryBarSettingsButton {
                barController.hide()
                menuController.onOpenSelectionWindowRequested?()
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .trailing)
        .background {
            FrostedBarBackground()
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .overlay(alignment: .bottom) {
            if menuController.autoHideDuration != .never {
                AutoHideHairlineBar(countdown: barController.countdown)
                    .padding(.horizontal, 7)
                    .padding(.bottom, 1.5)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.75)
        }
        .padding(2)
    }
}

private struct AutoHideHairlineBar: View {
    @ObservedObject var countdown: SecondaryBarCountdownModel

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .trailing) {
                Capsule()
                    .fill(Color.primary.opacity(0.06))
                Capsule()
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(width: max(0, geo.size.width * countdown.progress))
            }
        }
        .frame(height: 1.5)
        .allowsHitTesting(false)
    }
}

// MARK: - Native AppKit Icon Slot (Direct Left-Click & Right-Click to App + Live Drag Reordering)

private struct SecondaryBarIconSlotRepresentable: NSViewRepresentable {
    let item: MenuBarAppItem
    let index: Int
    let totalCount: Int
    let isActiveOpened: Bool
    let isBeingDragged: Bool
    let menuController: MenuBarController

    func makeNSView(context: Context) -> SecondaryBarSlotNSView {
        let view = SecondaryBarSlotNSView()
        view.configure(
            item: item,
            index: index,
            totalCount: totalCount,
            isActiveOpened: isActiveOpened,
            isBeingDragged: isBeingDragged,
            menuController: menuController
        )
        return view
    }

    func updateNSView(_ nsView: SecondaryBarSlotNSView, context: Context) {
        nsView.configure(
            item: item,
            index: index,
            totalCount: totalCount,
            isActiveOpened: isActiveOpened,
            isBeingDragged: isBeingDragged,
            menuController: menuController
        )
    }
}

@MainActor
final class SecondaryBarSlotNSView: NSView, NSDraggingSource {
    private var item: MenuBarAppItem?
    private var slotIndex: Int = 0
    private var totalCount: Int = 1
    private var isActiveOpened: Bool = false
    private var isBeingDragged: Bool = false
    private weak var menuController: MenuBarController?

    private let imageView = NSImageView()
    private var trackingAreaRef: NSTrackingArea?
    private var isHovered: Bool = false {
        didSet {
            if isHovered != oldValue {
                needsDisplay = true
            }
        }
    }

    private var mouseDownPoint: NSPoint? = nil
    private var didStartDragSession: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.isEditable = false
        imageView.unregisterDraggedTypes()
        addSubview(imageView)
        registerForDraggedTypes([.string])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func layout() {
        super.layout()
        let iconSize: CGFloat = 20.0
        imageView.frame = NSRect(
            x: (bounds.width - iconSize) * 0.5,
            y: (bounds.height - iconSize) * 0.5,
            width: iconSize,
            height: iconSize
        )
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

    func configure(
        item: MenuBarAppItem,
        index: Int,
        totalCount: Int,
        isActiveOpened: Bool,
        isBeingDragged: Bool,
        menuController: MenuBarController
    ) {
        let iconChanged = self.item?.id != item.id || self.item?.appIcon !== item.appIcon
        let stateChanged = self.isActiveOpened != isActiveOpened || self.isBeingDragged != isBeingDragged

        self.item = item
        self.slotIndex = index
        self.totalCount = totalCount
        self.isActiveOpened = isActiveOpened
        self.isBeingDragged = isBeingDragged
        self.menuController = menuController

        if iconChanged {
            imageView.image = item.appIcon
        }
        alphaValue = isBeingDragged ? 0.42 : 1.0

        let titleBase = item.statusTitle.isEmpty ? item.appName : "\(item.appName) (\(item.statusTitle))"
        let newTip = "\(titleBase) • Click trái/phải: mở menu ứng dụng • Kéo thả: đổi thứ tự • ⌥+Click: tuỳ chọn BarFlow"
        if toolTip != newTip {
            toolTip = newTip
        }

        if stateChanged {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isActiveOpened || isHovered else { return }

        let bgPath = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        if isActiveOpened {
            NSColor.controlAccentColor.withAlphaComponent(0.24).setFill()
        } else {
            NSColor.labelColor.withAlphaComponent(0.14).setFill()
        }
        bgPath.fill()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    // MARK: - Left Click, Right Click & Drag-to-Reorder

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        didStartDragSession = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDragSession,
              let start = mouseDownPoint,
              let item = item else { return }
        let cur = convert(event.locationInWindow, from: nil)
        guard hypot(cur.x - start.x, cur.y - start.y) >= 4.0 else { return }

        didStartDragSession = true
        menuController?.beginDraggingItem(item.id)

        let pbItem = NSPasteboardItem()
        pbItem.setString(item.id, forType: .string)
        let dragItem = NSDraggingItem(pasteboardWriter: pbItem)
        let dragRect = NSRect(
            x: (bounds.width - 20) * 0.5,
            y: (bounds.height - 20) * 0.5,
            width: 20,
            height: 20
        )
        dragItem.setDraggingFrame(dragRect, contents: item.appIcon)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            didStartDragSession = false
        }
        guard !didStartDragSession, let item = item else { return }
        let localPt = convert(event.locationInWindow, from: nil)
        guard bounds.insetBy(dx: -4, dy: -4).contains(localPt) else { return }

        if event.modifierFlags.contains(.option) {
            presentBarFlowQuickOptionsMenu(for: item)
            return
        }

        let isCtrlClick = event.modifierFlags.contains(.control)
        let screenRect = currentScreenRect()
        menuController?.activateAppFromSecondaryBar(
            item,
            rightClick: isCtrlClick,
            anchorScreenRectAppKit: screenRect,
            anchorView: self
        )
    }

    override func rightMouseDown(with event: NSEvent) {
        // Consume rightMouseDown so SwiftUI/AppKit never shows a fallback context menu
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let item = item else { return }
        let localPt = convert(event.locationInWindow, from: nil)
        guard bounds.insetBy(dx: -4, dy: -4).contains(localPt) else { return }

        if event.modifierFlags.contains(.option) {
            presentBarFlowQuickOptionsMenu(for: item)
            return
        }

        // Right-click directly opens THIS app's menu right underneath its icon!
        let screenRect = currentScreenRect()
        menuController?.activateAppFromSecondaryBar(
            item,
            rightClick: true,
            anchorScreenRectAppKit: screenRect,
            anchorView: self
        )
    }

    private func currentScreenRect() -> NSRect? {
        guard let win = window else { return nil }
        let rectInWin = convert(bounds, to: nil)
        return win.convertToScreen(rectInWin)
    }

    // MARK: - NSDraggingSource & NSDraggingDestination

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        menuController?.endDraggingSession()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let targetID = item?.id,
              let menuController = menuController else { return [] }
        let draggedID = menuController.draggingItemID
            ?? sender.draggingPasteboard.string(forType: .string)
        if let draggedID, draggedID != targetID {
            withAnimation(.interactiveSpring(response: 0.20, dampingFraction: 0.84)) {
                menuController.reorderSecondaryBarItem(draggedID: draggedID, targetID: targetID)
            }
        }
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let targetID = item?.id,
           let menuController = menuController {
            let draggedID = menuController.draggingItemID
                ?? sender.draggingPasteboard.string(forType: .string)
            if let draggedID, draggedID != targetID {
                menuController.reorderSecondaryBarItem(draggedID: draggedID, targetID: targetID)
            }
            menuController.endDraggingSession()
        }
        return true
    }

    // MARK: - Optional Power-User BarFlow Menu (`Option + Click` / `Option + Right-Click`)

    private func presentBarFlowQuickOptionsMenu(for item: MenuBarAppItem) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(title: "Tuỳ chọn BarFlow — \(item.appName)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let pinItem = NSMenuItem(title: "Đưa lên Menu Bar chính", action: #selector(handlePinToMainBar), keyEquivalent: "")
        pinItem.target = self
        menu.addItem(pinItem)

        let leftItem = NSMenuItem(title: "Di chuyển sang trái (◀)", action: #selector(handleMoveLeft), keyEquivalent: "")
        leftItem.target = self
        leftItem.isEnabled = slotIndex > 0
        menu.addItem(leftItem)

        let rightItem = NSMenuItem(title: "Di chuyển sang phải (▶)", action: #selector(handleMoveRight), keyEquivalent: "")
        rightItem.target = self
        rightItem.isEnabled = slotIndex < (totalCount - 1)
        menu.addItem(rightItem)

        if NSRunningApplication(processIdentifier: item.pid) != nil {
            menu.addItem(.separator())
            let activateItem = NSMenuItem(title: "Chuyển tới cửa sổ \(item.appName)", action: #selector(handleActivateAppWindow), keyEquivalent: "")
            activateItem.target = self
            menu.addItem(activateItem)
        }

        SecondaryBarController.shared.beginMirroredMenuSession(itemID: item.id)
        _ = menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: self)
        SecondaryBarController.shared.endMirroredMenuSession(didSelectAction: false)
    }

    @objc private func handlePinToMainBar() {
        guard let item = item else { return }
        menuController?.setAppSelection(item, visibleOnMainBar: true)
    }

    @objc private func handleMoveLeft() {
        guard let item = item else { return }
        menuController?.moveSecondaryBarItem(id: item.id, direction: -1)
    }

    @objc private func handleMoveRight() {
        guard let item = item else { return }
        menuController?.moveSecondaryBarItem(id: item.id, direction: 1)
    }

    @objc private func handleActivateAppWindow() {
        guard let item = item else { return }
        SecondaryBarController.shared.hide()
        NSRunningApplication(processIdentifier: item.pid)?.activate()
    }
}

private struct SecondaryBarSettingsButton: View {
    let action: () -> Void
    @StateObject private var hover = LocalHoverBox()

    var body: some View {
        Button(action: action) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hover.isHovered ? .primary : .secondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hover.isHovered ? Color.primary.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if hover.isHovered != inside {
                hover.isHovered = inside
            }
        }
        .help("Chọn lọc & sắp xếp ứng dụng Menu Bar")
    }
}
