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
    let barController: SecondaryBarController
    @ObservedObject var menuController: MenuBarController

    var body: some View {
        let apps = menuController.secondaryBarApps

        HStack(spacing: 5) {
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
                        ForEach(apps) { item in
                            SecondaryBarIconButton(
                                item: item,
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
    let onLeftClick: () -> Void
    let onRightClickMenu: () -> Void
    let onMoveToMainBar: () -> Void

    @StateObject private var hover = LocalHoverBox()

    private var tooltipText: String {
        if item.statusTitle.isEmpty {
            return item.appName
        }
        return "\(item.appName) (\(item.statusTitle))"
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
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if hover.isHovered != inside {
                hover.isHovered = inside
            }
        }
        .help(tooltipText)
        .contextMenu {
            Button(action: onLeftClick) {
                Label("Mở menu của \(item.appName)", systemImage: "cursorarrow.click")
            }

            Button(action: onRightClickMenu) {
                Label("Click chuột phải vào \(item.appName)", systemImage: "cursorarrow.click.2")
            }

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
        .help("Chọn lọc ứng dụng Menu Bar")
    }
}
