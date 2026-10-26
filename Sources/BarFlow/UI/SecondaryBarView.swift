import SwiftUI
import AppKit

/// Native AppKit frosted glass backdrop for the floating bar right below the macOS Menu Bar.
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

struct SecondaryBarView: View {
    @ObservedObject var barController: SecondaryBarController
    @ObservedObject var menuController: MenuBarController

    private let maxColumnsPerRow = 12

    var body: some View {
        let apps = menuController.secondaryBarApps
        let rows = chunkedApps(apps, size: maxColumnsPerRow)

        VStack(alignment: .leading, spacing: 5) {
            // Top micro-header: shows hovered app name + Ctrl+B hint + auto-hide badge
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)

                    if let hovered = barController.hoveredAppName {
                        Text(hovered)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .transition(.opacity)
                    } else {
                        Text("Ứng dụng ẩn (\(apps.count)) — Click để thao tác")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 12)

                if menuController.autoHideDuration != .never {
                    HStack(spacing: 3) {
                        Image(systemName: barController.isHoveringBar ? "pause.circle.fill" : "timer")
                            .font(.system(size: 10))
                        Text(barController.isHoveringBar ? "Đang giữ" : menuController.autoHideDuration.shortLabel)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(.secondary)
                }

                Text("⌃B")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 10)
            .padding(.top, 7)

            // Main Interactive App Icons Strip
            HStack(alignment: .center, spacing: 8) {
                if !menuController.isAccessibilityGranted {
                    Button {
                        barController.hide()
                        MenuBarScanner.shared.promptForAccessibilityPermission()
                        menuController.onOpenSelectionWindowRequested?()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.shield.fill")
                                .foregroundStyle(.orange)
                            Text("Cấp quyền Trợ năng (Accessibility) để đọc các icon Menu Bar")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                } else if apps.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Tất cả ứng dụng đang hiển thị trên Menu Bar chính")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, rowApps in
                            HStack(spacing: 4) {
                                ForEach(rowApps) { item in
                                    SecondaryBarItemButton(
                                        item: item,
                                        isHovered: barController.hoveredItemID == item.id,
                                        onHoverChanged: { hovering in
                                            if hovering {
                                                barController.hoveredItemID = item.id
                                                let suffix = item.statusTitle.isEmpty ? "" : "  •  \(item.statusTitle)"
                                                barController.hoveredAppName = "\(item.appName)\(suffix)"
                                            } else if barController.hoveredItemID == item.id {
                                                barController.hoveredItemID = nil
                                                barController.hoveredAppName = nil
                                            }
                                        },
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
                    }
                }

                Divider()
                    .frame(height: 24)
                    .padding(.horizontal, 2)

                // Trailing Utility Actions (Open Selection Window / Dismiss)
                HStack(spacing: 4) {
                    Button {
                        barController.hide()
                        menuController.onOpenSelectionWindowRequested?()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(barController.hoveredUtilityID == "settings" ? .primary : .secondary)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(barController.hoveredUtilityID == "settings" ? Color.primary.opacity(0.10) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in
                        barController.hoveredUtilityID = inside ? "settings" : (barController.hoveredUtilityID == "settings" ? nil : barController.hoveredUtilityID)
                    }
                    .help("Chọn lọc ứng dụng hiển thị trên Menu Bar chính")

                    Button {
                        barController.hide()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(barController.hoveredUtilityID == "close" ? .primary : .secondary)
                            .frame(width: 24, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(barController.hoveredUtilityID == "close" ? Color.primary.opacity(0.10) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in
                        barController.hoveredUtilityID = inside ? "close" : (barController.hoveredUtilityID == "close" ? nil : barController.hoveredUtilityID)
                    }
                    .help("Ẩn thanh phụ (Ctrl + B hoặc Esc)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, menuController.autoHideDuration == .never ? 8 : 5)

            // Subtle auto-hide progress bar along bottom edge
            if menuController.autoHideDuration != .never {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.06))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color.accentColor.opacity(0.85), Color.cyan.opacity(0.85)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(0, geo.size.width * barController.countdownProgress))
                            .animation(.linear(duration: 0.06), value: barController.countdownProgress)
                    }
                }
                .frame(height: 2.5)
                .padding(.horizontal, 12)
                .padding(.bottom, 5)
            }
        }
        .background {
            FrostedBarBackground()
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
        }
        .padding(4)
        .onHover { inside in
            barController.isHoveringBar = inside
        }
    }

    private func chunkedApps(_ items: [MenuBarAppItem], size: Int) -> [[MenuBarAppItem]] {
        guard !items.isEmpty, size > 0 else { return [] }
        return stride(from: 0, to: items.count, by: size).map { start in
            Array(items[start..<min(start + size, items.count)])
        }
    }
}

private struct SecondaryBarItemButton: View {
    let item: MenuBarAppItem
    let isHovered: Bool
    let onHoverChanged: (Bool) -> Void
    let onLeftClick: () -> Void
    let onRightClickMenu: () -> Void
    let onMoveToMainBar: () -> Void

    var body: some View {
        Button(action: onLeftClick) {
            HStack(spacing: 4) {
                Image(nsImage: item.appIcon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22)

                if !item.statusTitle.isEmpty && item.statusTitle.count <= 14 {
                    Text(item.statusTitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, (!item.statusTitle.isEmpty && item.statusTitle.count <= 14) ? 7 : 6)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? Color.accentColor.opacity(0.20) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isHovered ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
            )
            .scaleEffect(isHovered ? 1.06 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            onHoverChanged(inside)
        }
        .contextMenu {
            Button {
                onLeftClick()
            } label: {
                Label("Mở menu của \(item.appName)", systemImage: "cursorarrow.click")
            }

            Button {
                onRightClickMenu()
            } label: {
                Label("Click chuột phải vào \(item.appName)", systemImage: "cursorarrow.click.2")
            }

            Divider()

            Button {
                onMoveToMainBar()
            } label: {
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
