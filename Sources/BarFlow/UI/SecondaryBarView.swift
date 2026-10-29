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

/// Shared screen-level floating icon preview panel (`ignoresMouseEvents = true`) used during live drag-to-reorder
/// in `Ctrl + B` and `AppSelectionView` so dragged icons follow the cursor smoothly at 120fps even across bars!
@MainActor
final class FloatingIconDragGhost {
    static let shared = FloatingIconDragGhost()

    private var panel: NSPanel?
    private let hostView = GhostBadgeView(frame: NSRect(x: 0, y: 0, width: 160, height: 34))

    private init() {}

    func showOrUpdate(icon: NSImage, label: String?, screenPoint: NSPoint, showPinBadge: Bool = false) {
        let p: NSPanel
        if let existing = panel {
            p = existing
        } else {
            let created = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 160, height: 34),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            created.isFloatingPanel = true
            created.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 6)
            created.backgroundColor = .clear
            created.isOpaque = false
            created.hasShadow = true
            created.ignoresMouseEvents = true
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            created.contentView = hostView
            self.panel = created
            p = created
        }

        let size = hostView.configure(icon: icon, label: label, showPinBadge: showPinBadge)
        let origin = NSPoint(x: screenPoint.x - size.width * 0.5, y: screenPoint.y - size.height * 0.5 + 6)
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        if !p.isVisible {
            p.orderFrontRegardless()
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private final class GhostBadgeView: NSView {
        private var icon: NSImage?
        private var label: String?
        private var showPinBadge: Bool = false

        func configure(icon: NSImage, label: String?, showPinBadge: Bool) -> NSSize {
            self.icon = icon
            self.label = label
            self.showPinBadge = showPinBadge
            needsDisplay = true

            if let text = label, !text.isEmpty {
                let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
                let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
                let totalWidth = min(max(44, 32 + textWidth + (showPinBadge ? 18 : 0)), 220)
                return NSSize(width: totalWidth, height: 30)
            } else {
                return NSSize(width: showPinBadge ? 42 : 34, height: 34)
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            let pillRect = bounds.insetBy(dx: 1, dy: 1)
            let radius: CGFloat = label == nil ? 9 : 14
            let path = NSBezierPath(roundedRect: pillRect, xRadius: radius, yRadius: radius)

            NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
            path.fill()

            (showPinBadge ? NSColor.systemGreen : NSColor.controlAccentColor).withAlphaComponent(0.85).setStroke()
            path.lineWidth = 1.5
            path.stroke()

            if let img = icon {
                let iconSize: CGFloat = label == nil ? 21 : 17
                let iconX: CGFloat = label == nil ? (bounds.width - iconSize) * 0.5 - (showPinBadge ? 3 : 0) : 8
                let iconRect = NSRect(
                    x: iconX,
                    y: (bounds.height - iconSize) * 0.5,
                    width: iconSize,
                    height: iconSize
                )
                drawAppKitIcon(img, in: iconRect, alpha: 1.0, respectFlipped: isFlipped)
            }

            if let text = label, !text.isEmpty {
                let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.labelColor
                ]
                let strSize = (text as NSString).size(withAttributes: attrs)
                let maxW = bounds.width - 32 - (showPinBadge ? 16 : 0)
                let textRect = NSRect(
                    x: 29,
                    y: (bounds.height - strSize.height) * 0.5,
                    width: max(10, maxW),
                    height: strSize.height
                )
                (text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
            }

            if showPinBadge {
                let badgeSize: CGFloat = 13
                let badgeRect = NSRect(
                    x: bounds.maxX - badgeSize - 3,
                    y: bounds.maxY - badgeSize - 3,
                    width: badgeSize,
                    height: badgeSize
                )
                let circle = NSBezierPath(ovalIn: badgeRect)
                NSColor.systemGreen.setFill()
                circle.fill()

                let plusAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: NSColor.white
                ]
                let pSize = ("+" as NSString).size(withAttributes: plusAttrs)
                ("+" as NSString).draw(
                    at: NSPoint(
                        x: badgeRect.midX - pSize.width * 0.5,
                        y: badgeRect.midY - pSize.height * 0.5 + 0.5
                    ),
                    withAttributes: plusAttrs
                )
            }
        }
    }
}

fileprivate func drawAppKitIcon(_ img: NSImage, in rect: NSRect, alpha: CGFloat, respectFlipped: Bool) {
    if img.isTemplate, let cg = NSGraphicsContext.current?.cgContext {
        cg.saveGState()
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: respectFlipped, hints: nil)
        NSColor.labelColor.withAlphaComponent(alpha).setFill()
        rect.fill(using: .sourceIn)
        cg.endTransparencyLayer()
        cg.restoreGState()
    } else {
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: respectFlipped, hints: nil)
    }
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
                SecondaryBarStripRepresentable(
                    items: apps,
                    activeOpenedID: activeID,
                    draggingID: draggingID,
                    menuController: menuController
                )
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

// MARK: - Unified Native AppKit Icon Strip (120fps Live Drag Reorder + 1x/2x Right-Click)

private struct SecondaryBarStripRepresentable: NSViewRepresentable {
    let items: [MenuBarAppItem]
    let activeOpenedID: String?
    let draggingID: String?
    let menuController: MenuBarController

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true

        let strip = SecondaryBarStripNSView()
        scroll.documentView = strip
        applyConfiguration(to: scroll, strip: strip)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let strip = nsView.documentView as? SecondaryBarStripNSView else { return }
        applyConfiguration(to: nsView, strip: strip)
    }

    private func applyConfiguration(to scroll: NSScrollView, strip: SecondaryBarStripNSView) {
        let count = items.count
        let slotSize = SecondaryBarController.iconSlotSize
        let spacing = SecondaryBarController.iconSpacing
        let totalWidth = CGFloat(count) * slotSize + CGFloat(max(count - 1, 0)) * spacing

        let targetFrame = NSRect(x: 0, y: 0, width: max(totalWidth, slotSize), height: slotSize)
        if strip.frame != targetFrame {
            strip.frame = targetFrame
        }
        strip.configure(
            items: items,
            activeOpenedID: activeOpenedID,
            draggingID: draggingID,
            menuController: menuController
        )
    }
}

@MainActor
final class SecondaryBarStripNSView: NSView {
    private var items: [MenuBarAppItem] = []
    private var activeOpenedID: String? = nil
    private var draggingID: String? = nil
    private weak var menuController: MenuBarController?

    private var trackingAreaRef: NSTrackingArea?
    private var hoveredIndex: Int? = nil {
        didSet {
            if hoveredIndex != oldValue {
                updateHoveredToolTip()
                needsDisplay = true
            }
        }
    }

    // Direct pointer-tracking drag state (works 100% inside non-activating panels without NSDraggingSession issues!)
    private var pressedItem: MenuBarAppItem? = nil
    private var mouseDownLocalPt: NSPoint? = nil
    private var isDraggingIcon: Bool = false
    private var isHoveringMainMenuBar: Bool = false

    // Single right-click (app menu) vs Double right-click (BarFlow management menu)
    private var pendingSingleRightClickWork: DispatchWorkItem? = nil
    private var lastRightClickTime: CFAbsoluteTime = 0
    private var lastRightClickItemID: String? = nil
    private var lastEmptyGapRightClickTime: CFAbsoluteTime = 0

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    func configure(
        items: [MenuBarAppItem],
        activeOpenedID: String?,
        draggingID: String?,
        menuController: MenuBarController
    ) {
        let changed = self.items != items || self.activeOpenedID != activeOpenedID || self.draggingID != draggingID
        self.items = items
        self.activeOpenedID = activeOpenedID
        self.draggingID = draggingID
        self.menuController = menuController
        if changed {
            needsDisplay = true
        }
    }

    private func slotRect(for index: Int) -> NSRect {
        let slotSize = SecondaryBarController.iconSlotSize
        let stride = slotSize + SecondaryBarController.iconSpacing
        return NSRect(x: CGFloat(index) * stride, y: 0, width: slotSize, height: slotSize)
    }

    private func slotIndex(at localPoint: NSPoint, allowVerticalSlack: CGFloat = 4.0) -> Int? {
        guard !items.isEmpty else { return nil }
        guard localPoint.y >= -allowVerticalSlack && localPoint.y <= bounds.height + allowVerticalSlack else {
            return nil
        }
        let slotSize = SecondaryBarController.iconSlotSize
        let stride = slotSize + SecondaryBarController.iconSpacing
        let rawIdx = Int(floor((localPoint.x + SecondaryBarController.iconSpacing * 0.5) / stride))
        guard rawIdx >= 0 && rawIdx < items.count else { return nil }
        let rect = slotRect(for: rawIdx).insetBy(dx: -2, dy: -allowVerticalSlack)
        return rect.contains(localPoint) ? rawIdx : nil
    }

    private func clampedReorderTargetIndex(forLocalX x: CGFloat) -> Int {
        guard !items.isEmpty else { return 0 }
        let stride = SecondaryBarController.iconSlotSize + SecondaryBarController.iconSpacing
        let raw = Int(floor(x / stride))
        return min(max(0, raw), items.count - 1)
    }

    private func slotScreenRect(for index: Int) -> NSRect? {
        guard let win = window, index >= 0, index < items.count else { return nil }
        let rectInWin = convert(slotRect(for: index), to: nil)
        return win.convertToScreen(rectInWin)
    }

    private func updateHoveredToolTip() {
        guard let idx = hoveredIndex, idx >= 0, idx < items.count else {
            toolTip = nil
            return
        }
        let item = items[idx]
        let titleBase = item.statusTitle.isEmpty ? item.appName : "\(item.appName) (\(item.statusTitle))"
        toolTip = "\(titleBase) • Click trái: mở ứng dụng • Click phải 1 lần: menu \(item.appName) • Click phải 2 lần: menu quản lý BarFlow • Kéo thả: đổi vị trí (kéo lên trên để ghim lên Menu Bar)"
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let iconSize: CGFloat = 20.0

        for (idx, item) in items.enumerated() {
            let rect = slotRect(for: idx)
            guard rect.intersects(dirtyRect) else { continue }

            let isOpened = (activeOpenedID == item.id)
            let isDragged = (draggingID == item.id)
            let isHover = (hoveredIndex == idx) && !isDraggingIcon

            if isDragged {
                let dropHighlight = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
                NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
                dropHighlight.fill()
                NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
                dropHighlight.lineWidth = 1.2
                dropHighlight.stroke()
            } else if isOpened || isHover {
                let bgPath = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
                if isOpened {
                    NSColor.controlAccentColor.withAlphaComponent(0.24).setFill()
                } else {
                    NSColor.labelColor.withAlphaComponent(0.14).setFill()
                }
                bgPath.fill()
            }

            let iconRect = NSRect(
                x: rect.minX + (rect.width - iconSize) * 0.5,
                y: rect.minY + (rect.height - iconSize) * 0.5,
                width: iconSize,
                height: iconSize
            )
            drawAppKitIcon(
                item.appIcon,
                in: iconRect,
                alpha: isDragged ? 0.30 : 1.0,
                respectFlipped: true
            )
        }
    }

    // MARK: - Hover Tracking

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        hoveredIndex = slotIndex(at: pt)
    }

    override func mouseEntered(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        hoveredIndex = slotIndex(at: pt)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
    }

    // MARK: - Left Mouse: Instant Click + Live 120fps Drag-to-Reorder (or Drag Up to Main Menu Bar!)

    override func mouseDown(with event: NSEvent) {
        cancelPendingSingleRightClick()
        SecondaryBarController.shared.notifyUserInteraction()

        let pt = convert(event.locationInWindow, from: nil)
        mouseDownLocalPt = pt
        isDraggingIcon = false
        isHoveringMainMenuBar = false
        if let idx = slotIndex(at: pt), idx < items.count {
            pressedItem = items[idx]
        } else {
            pressedItem = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        SecondaryBarController.shared.notifyUserInteraction()
        guard let startPt = mouseDownLocalPt,
              let dragged = pressedItem,
              let menuController = menuController else { return }

        let curLocal = convert(event.locationInWindow, from: nil)
        if !isDraggingIcon {
            guard hypot(curLocal.x - startPt.x, curLocal.y - startPt.y) >= 3.5 else { return }
            isDraggingIcon = true
            hoveredIndex = nil
            menuController.beginDraggingItem(dragged.id)
            NSCursor.closedHand.push()
        }

        let screenPt = NSEvent.mouseLocation
        let screen = window?.screen ?? MenuBarScanner.screenContainingMouse()
        let barThickness = MenuBarScanner.effectiveMenuBarThickness(for: screen)
        let overMainBar = screenPt.y >= (screen.frame.maxY - barThickness - 4.0)
        isHoveringMainMenuBar = overMainBar

        FloatingIconDragGhost.shared.showOrUpdate(
            icon: dragged.appIcon,
            label: overMainBar ? "Ghim \(dragged.appName) lên Menu Bar" : nil,
            screenPoint: screenPt,
            showPinBadge: overMainBar
        )

        if !overMainBar {
            let targetIdx = clampedReorderTargetIndex(forLocalX: curLocal.x)
            let liveList = menuController.secondaryBarApps
            if targetIdx >= 0 && targetIdx < liveList.count {
                let targetID = liveList[targetIdx].id
                if targetID != dragged.id {
                    menuController.reorderSecondaryBarItem(draggedID: dragged.id, targetID: targetID)
                }
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = isDraggingIcon
        let wasOverMainBar = isHoveringMainMenuBar
        let activePressed = pressedItem

        pressedItem = nil
        mouseDownLocalPt = nil
        isDraggingIcon = false
        isHoveringMainMenuBar = false

        if wasDragging {
            NSCursor.pop()
            FloatingIconDragGhost.shared.hide()
            if wasOverMainBar, let dragged = activePressed {
                menuController?.promoteSecondaryItemToMainBarAtScreenPoint(
                    dragged,
                    screenPointAppKit: NSEvent.mouseLocation
                )
            }
            menuController?.endDraggingSession()
            let pt = convert(event.locationInWindow, from: nil)
            hoveredIndex = slotIndex(at: pt)
            needsDisplay = true
            return
        }

        guard let item = activePressed, let menuController = menuController else { return }
        let curLocal = convert(event.locationInWindow, from: nil)
        guard let idx = slotIndex(at: curLocal, allowVerticalSlack: 6.0),
              idx < items.count,
              items[idx].id == item.id else { return }

        let screenRect = slotScreenRect(for: idx)
        if event.modifierFlags.contains(.option) {
            let anchorPt = screenRect.map { NSPoint(x: $0.minX, y: $0.minY - 4) }
            menuController.presentBarFlowManagementMenu(
                for: item,
                anchorView: nil,
                anchorScreenPoint: anchorPt
            )
            return
        }

        let isCtrlClick = event.modifierFlags.contains(.control)
        menuController.activateAppFromSecondaryBar(
            item,
            rightClick: isCtrlClick,
            anchorScreenRectAppKit: screenRect,
            anchorView: nil
        )
    }

    // MARK: - Right Mouse: 1x Right-Click -> App Menu, 2x Right-Click -> BarFlow Management Menu

    private func cancelPendingSingleRightClick() {
        pendingSingleRightClickWork?.cancel()
        pendingSingleRightClickWork = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        SecondaryBarController.shared.notifyUserInteraction()
    }

    override func rightMouseUp(with event: NSEvent) {
        SecondaryBarController.shared.notifyUserInteraction()
        guard let menuController = menuController else { return }

        let curLocal = convert(event.locationInWindow, from: nil)
        let now = CFAbsoluteTimeGetCurrent()

        guard let idx = slotIndex(at: curLocal, allowVerticalSlack: 6.0), idx < items.count else {
            // Clicked on empty gap between icons inside the strip: 2x right-click opens BarFlow Management Menu!
            if event.clickCount >= 2 || (now - lastEmptyGapRightClickTime) <= 0.40 {
                lastEmptyGapRightClickTime = 0
                let panelMinY = window?.frame.minY ?? NSEvent.mouseLocation.y
                menuController.presentBarFlowManagementMenu(
                    for: nil,
                    anchorView: nil,
                    anchorScreenPoint: NSPoint(x: NSEvent.mouseLocation.x, y: panelMinY - 4)
                )
            } else {
                lastEmptyGapRightClickTime = now
            }
            return
        }

        let item = items[idx]
        let screenRect = slotScreenRect(for: idx)
        let anchorPt = screenRect.map { NSPoint(x: $0.minX, y: $0.minY - 4) } ?? NSEvent.mouseLocation

        if event.modifierFlags.contains(.option) {
            cancelPendingSingleRightClick()
            lastRightClickTime = 0
            lastRightClickItemID = nil
            menuController.presentBarFlowManagementMenu(
                for: item,
                anchorView: nil,
                anchorScreenPoint: anchorPt
            )
            return
        }

        let isDoubleRightClick = event.clickCount >= 2 ||
            (lastRightClickItemID == item.id && (now - lastRightClickTime) <= 0.36)

        if isDoubleRightClick {
            cancelPendingSingleRightClick()
            lastRightClickTime = 0
            lastRightClickItemID = nil
            menuController.presentBarFlowManagementMenu(
                for: item,
                anchorView: nil,
                anchorScreenPoint: anchorPt
            )
        } else {
            cancelPendingSingleRightClick()
            lastRightClickTime = now
            lastRightClickItemID = item.id

            let capturedItem = item
            let capturedRect = screenRect
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.pendingSingleRightClickWork = nil
                self.lastRightClickTime = 0
                self.lastRightClickItemID = nil
                self.menuController?.activateAppFromSecondaryBar(
                    capturedItem,
                    rightClick: true,
                    anchorScreenRectAppKit: capturedRect,
                    anchorView: nil
                )
            }
            pendingSingleRightClickWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.21, execute: work)
        }
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
        .help("Chọn lọc & sắp xếp ứng dụng Menu Bar (Click phải 2 lần để mở nhanh menu BarFlow)")
    }
}
