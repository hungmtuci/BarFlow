import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
                            SecondaryBarIconButton(
                                item: item,
                                index: index,
                                totalCount: apps.count,
                                isBeingDragged: menuController.draggingItemID == item.id,
                                menuController: menuController,
                                onLeftClick: {
                                    menuController.activateAppFromSecondaryBar(item, rightClick: false)
                                },
                                onRightClickMenu: {
                                    menuController.activateAppFromSecondaryBar(item, rightClick: true)
                                },
                                onMoveToMainBar: {
                                    menuController.setAppSelection(item, visibleOnMainBar: true)
                                }
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

private struct SecondaryBarIconButton: View {
    let item: MenuBarAppItem
    let index: Int
    let totalCount: Int
    let isBeingDragged: Bool
    let menuController: MenuBarController
    let onLeftClick: () -> Void
    let onRightClickMenu: () -> Void
    let onMoveToMainBar: () -> Void

    @StateObject private var hover = LocalHoverBox()

    private var tooltipText: String {
        let base = item.statusTitle.isEmpty ? item.appName : "\(item.appName) (\(item.statusTitle))"
        return "\(base) • Kéo thả để đổi thứ tự"
    }

    var body: some View {
        Button(action: onLeftClick) {
            Image(nsImage: item.appIcon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
                .frame(
                    width: SecondaryBarController.iconSlotSize,
                    height: SecondaryBarController.iconSlotSize
                )
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hover.isHovered ? Color.primary.opacity(0.14) : Color.clear)
                )
                .opacity(isBeingDragged ? 0.42 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if hover.isHovered != inside {
                hover.isHovered = inside
            }
        }
        .onDrag {
            menuController.beginDraggingItem(item.id)
            return NSItemProvider(object: item.id as NSString)
        }
        .onDrop(
            of: [UTType.text, UTType.plainText],
            delegate: SecondaryBarIconDropDelegate(
                targetItemID: item.id,
                menuController: menuController
            )
        )
        .help(tooltipText)
        .contextMenu {
            Button(action: onLeftClick) {
                Label("Mở menu của \(item.appName)", systemImage: "cursorarrow.click")
            }

            Button(action: onRightClickMenu) {
                Label("Click chuột phải vào \(item.appName)", systemImage: "cursorarrow.click.2")
            }

            Divider()

            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    menuController.moveSecondaryBarItem(id: item.id, direction: -1)
                }
            } label: {
                Label("Di chuyển sang trái (◀)", systemImage: "arrow.left")
            }
            .disabled(index <= 0)

            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    menuController.moveSecondaryBarItem(id: item.id, direction: 1)
                }
            } label: {
                Label("Di chuyển sang phải (▶)", systemImage: "arrow.right")
            }
            .disabled(index >= totalCount - 1)

            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    menuController.moveSecondaryBarItemToEdge(id: item.id, toStart: true)
                }
            } label: {
                Label("Đưa sang ngoài cùng bên trái", systemImage: "arrow.left.to.line")
            }
            .disabled(index <= 0)

            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    menuController.moveSecondaryBarItemToEdge(id: item.id, toStart: false)
                }
            } label: {
                Label("Đưa sang ngoài cùng bên phải", systemImage: "arrow.right.to.line")
            }
            .disabled(index >= totalCount - 1)

            Divider()

            Button(action: onMoveToMainBar) {
                Label("Đưa lên Menu Bar chính", systemImage: "pin.fill")
            }

            if let app = NSRunningApplication(processIdentifier: item.pid) {
                Button {
                    app.activate()
                } label: {
                    Label("Chuyển tới cửa sổ \(item.appName)", systemImage: "macwindow")
                }
            }
        }
    }
}

@MainActor
private struct SecondaryBarIconDropDelegate: DropDelegate {
    let targetItemID: String
    let menuController: MenuBarController

    func dropEntered(info: DropInfo) {
        guard let draggedID = menuController.draggingItemID,
              draggedID != targetItemID else { return }
        withAnimation(.interactiveSpring(response: 0.20, dampingFraction: 0.84)) {
            menuController.reorderSecondaryBarItem(draggedID: draggedID, targetID: targetItemID)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        if let draggedID = menuController.draggingItemID, draggedID != targetItemID {
            menuController.reorderSecondaryBarItem(draggedID: draggedID, targetID: targetItemID)
        }
        menuController.endDraggingSession()
        return true
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
