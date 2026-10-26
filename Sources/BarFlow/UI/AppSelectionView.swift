import SwiftUI
import AppKit

enum AppFilterMode: String, CaseIterable, Identifiable {
    case all = "all"
    case mainBar = "main"
    case secondaryBar = "secondary"

    var id: String { rawValue }
}

struct AppSelectionView: View {
    @ObservedObject var menuController: MenuBarController
    @ObservedObject var barController: SecondaryBarController

    private var filterMode: AppFilterMode {
        AppFilterMode(rawValue: menuController.filterModeRaw) ?? .all
    }

    private var filteredApps: [MenuBarAppItem] {
        let base: [MenuBarAppItem]
        switch filterMode {
        case .all:
            base = menuController.allRunningApps
        case .mainBar:
            base = menuController.mainBarApps
        case .secondaryBar:
            base = menuController.secondaryBarApps
        }
        let trimmed = menuController.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        return base.filter { item in
            item.appName.localizedCaseInsensitiveContains(trimmed) ||
            (item.bundleIdentifier?.localizedCaseInsensitiveContains(trimmed) ?? false) ||
            item.statusTitle.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()

            if !menuController.isAccessibilityGranted {
                accessibilityPermissionBanner
                Divider()
            }

            liveZonesPreviewSection
            Divider()

            filterAndSearchToolbar
            Divider()

            appListSection
            Divider()

            footerSettingsBar
        }
        .frame(minWidth: 740, idealWidth: 780, minHeight: 620, idealHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 1. Top Header

    private var headerSection: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.blue, Color.indigo],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)
                Image(systemName: "menubar.dock.rectangle")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("BarFlow")
                        .font(.system(size: 18, weight: .bold))
                    Text("Ctrl + B")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.12), in: Capsule())
                }
                Text("Chọn lọc ứng dụng giữ lại trên Menu Bar chính • Các ứng dụng còn lại hiển thị ngay dưới Menu Bar khi bấm Ctrl + B")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    menuController.refreshRunningApps()
                } label: {
                    Label("Làm mới", systemImage: "arrow.clockwise")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .help("Quét lại danh sách ứng dụng đang chạy trên Menu Bar")

                Button {
                    barController.toggle()
                } label: {
                    Label(barController.isVisible ? "Ẩn thanh phụ (⌃B)" : "Hiện thử (⌃B)", systemImage: "menubar.arrow.down.rectangle")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .buttonStyle(.bordered)

                Button {
                    Task {
                        await menuController.arrangeMenuBarAccordingToSelection()
                    }
                } label: {
                    HStack(spacing: 6) {
                        if menuController.isArrangingMenuBar {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "wand.and.stars")
                        }
                        Text(menuController.isArrangingMenuBar ? "Đang sắp xếp..." : "Áp dụng lên Menu Bar")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(menuController.isArrangingMenuBar)
                .help("Tự động sắp xếp các icon đã chọn sang bên phải và ẩn các icon còn lại trên Menu Bar chính")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - 2. Accessibility Permission Banner

    private var accessibilityPermissionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 22))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Cần cấp quyền Trợ năng (Accessibility) để quản lý Menu Bar")
                    .font(.system(size: 13, weight: .semibold))
                Text("BarFlow dùng Accessibility API của macOS để đọc danh sách ứng dụng đang chạy trên Menu Bar và kích hoạt menu khi bấm từ thanh phụ Ctrl + B.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Cấp quyền ngay") {
                MenuBarScanner.shared.promptForAccessibilityPermission()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.10))
    }

    // MARK: - 3. Live Dual-Bar Visual Preview (Bartender Style)

    private var liveZonesPreviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Zone A: Main Menu Bar Preview
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label("Giữ trên Menu Bar chính (\(menuController.mainBarApps.count))", systemImage: "pin.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("Click vào icon bất kỳ để chuyển nhanh xuống thanh phụ Ctrl + B")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if menuController.mainBarApps.isEmpty {
                            Text("Chưa chọn ứng dụng nào — chỉ còn biểu tượng BarFlow trên Menu Bar chính")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(menuController.mainBarApps) { item in
                                let chipKey = "main:\(item.id)"
                                PreviewChipButton(
                                    item: item,
                                    isPinnedMain: true,
                                    isHovered: menuController.hoveredPreviewID == chipKey,
                                    onHover: { inside in
                                        menuController.hoveredPreviewID = inside ? chipKey : (menuController.hoveredPreviewID == chipKey ? nil : menuController.hoveredPreviewID)
                                    },
                                    action: {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            menuController.toggleAppSelection(item)
                                        }
                                    }
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.green.opacity(0.32), lineWidth: 1)
                )
            }

            // Zone B: Secondary Bar (Ctrl + B) Preview
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label("Hiện ở thanh phụ dưới Menu Bar khi bấm Ctrl + B (\(menuController.secondaryBarApps.count))", systemImage: "menubar.arrow.down.rectangle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.blue)
                    Spacer()
                    Text("Click vào icon bất kỳ để đưa lên Menu Bar chính")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if menuController.secondaryBarApps.isEmpty {
                            Text("Không có ứng dụng ẩn — bỏ chọn bớt ứng dụng bên dưới để đưa vào thanh Ctrl + B")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(menuController.secondaryBarApps) { item in
                                let chipKey = "sec:\(item.id)"
                                PreviewChipButton(
                                    item: item,
                                    isPinnedMain: false,
                                    isHovered: menuController.hoveredPreviewID == chipKey,
                                    onHover: { inside in
                                        menuController.hoveredPreviewID = inside ? chipKey : (menuController.hoveredPreviewID == chipKey ? nil : menuController.hoveredPreviewID)
                                    },
                                    action: {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            menuController.toggleAppSelection(item)
                                        }
                                    }
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.blue.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.blue.opacity(0.28), lineWidth: 1)
                )
            }

            if !menuController.statusMessage.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                    Text(menuController.statusMessage)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    // MARK: - 4. Filter & Search Toolbar

    private var filterAndSearchToolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Tìm ứng dụng đang chạy trên Menu Bar...", text: $menuController.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                if !menuController.searchText.isEmpty {
                    Button {
                        menuController.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: 260)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

            Picker("", selection: $menuController.filterModeRaw) {
                Text("Tất cả (\(menuController.allRunningApps.count))").tag(AppFilterMode.all.rawValue)
                Text("Menu Bar chính (\(menuController.mainBarApps.count))").tag(AppFilterMode.mainBar.rawValue)
                Text("Thanh phụ ⌃B (\(menuController.secondaryBarApps.count))").tag(AppFilterMode.secondaryBar.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 340)

            Spacer()

            Menu {
                Button("Chọn tất cả lên Menu Bar chính") {
                    menuController.selectAllForMainBar()
                }
                Button("Đưa tất cả app hãng thứ 3 xuống thanh phụ Ctrl + B") {
                    menuController.deselectAllNonSystemForMainBar()
                }
            } label: {
                Label("Chọn nhanh", systemImage: "checklist")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
    }

    // MARK: - 5. Running Menu Bar Apps List

    private var appListSection: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                if filteredApps.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "menubar.rectangle")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                        Text(menuController.isAccessibilityGranted
                             ? "Không tìm thấy ứng dụng phù hợp."
                             : "Hãy cấp quyền Trợ năng ở thanh thông báo phía trên để hiển thị danh sách ứng dụng.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                } else {
                    ForEach(filteredApps) { item in
                        AppSelectionRow(
                            item: item,
                            isSelectedOnMainBar: menuController.isSelectedForMainBar(item),
                            isHovered: menuController.hoveredRowID == item.id,
                            onHover: { inside in
                                menuController.hoveredRowID = inside ? item.id : (menuController.hoveredRowID == item.id ? nil : menuController.hoveredRowID)
                            },
                            onToggle: { newValue in
                                withAnimation(.easeInOut(duration: 0.14)) {
                                    menuController.setAppSelection(item, visibleOnMainBar: newValue)
                                }
                            },
                            onTestTrigger: {
                                menuController.activateAppFromSecondaryBar(item, rightClick: false)
                            }
                        )
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    // MARK: - 6. Bottom Settings Bar

    private var footerSettingsBar: some View {
        HStack(spacing: 18) {
            HStack(spacing: 6) {
                Image(systemName: "timer")
                    .foregroundStyle(.secondary)
                Text("Tự động ẩn thanh Ctrl + B:")
                    .font(.system(size: 12, weight: .medium))
                Picker("", selection: $menuController.autoHideDuration) {
                    ForEach(AutoHideDuration.allCases) { option in
                        Text(option.shortLabel == "Thủ công" ? "Không tự ẩn" : option.title).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 125)
            }

            Divider()
                .frame(height: 18)

            Toggle("Ẩn các app không chọn khỏi Menu Bar chính", isOn: $menuController.isMainBarHidingEnabled)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))

            Spacer()

            Toggle("Hiện khi mở app", isOn: $menuController.showSelectionOnLaunch)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))

            Toggle("Ẩn khỏi Dock", isOn: $menuController.hideFromDock)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }
}

// MARK: - Supporting Row & Chip Views

private struct PreviewChipButton: View {
    let item: MenuBarAppItem
    let isPinnedMain: Bool
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(nsImage: item.appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 18, height: 18)

                Text(item.appName)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isHovered
                          ? (isPinnedMain ? Color.red.opacity(0.14) : Color.green.opacity(0.16))
                          : Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .onHover { onHover($0) }
        .help(isPinnedMain ? "Click để chuyển \(item.appName) xuống thanh phụ Ctrl + B" : "Click để đưa \(item.appName) lên Menu Bar chính")
    }
}

private struct AppSelectionRow: View {
    let item: MenuBarAppItem
    let isSelectedOnMainBar: Bool
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onToggle: (Bool) -> Void
    let onTestTrigger: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: item.appIcon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.appName)
                        .font(.system(size: 13.5, weight: .semibold))

                    if !item.statusTitle.isEmpty {
                        Text(item.statusTitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.10), in: Capsule())
                    }

                    if item.isSystemItem {
                        Text("Hệ thống")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }

                HStack(spacing: 8) {
                    if let bundle = item.bundleIdentifier {
                        Text(bundle)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            Button {
                onTestTrigger()
            } label: {
                Label("Thao tác thử", systemImage: "cursorarrow.click")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .opacity(isHovered ? 1.0 : 0.65)
            .help("Kích hoạt ngay menu của \(item.appName)")

            HStack(spacing: 8) {
                Text(isSelectedOnMainBar ? "Menu Bar chính" : "Thanh phụ ⌃B")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(isSelectedOnMainBar ? .green : .blue)
                    .frame(width: 96, alignment: .trailing)

                Toggle("", isOn: Binding(
                    get: { isSelectedOnMainBar },
                    set: { onToggle($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.05) : Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelectedOnMainBar ? Color.green.opacity(0.24) : Color.primary.opacity(0.06),
                    lineWidth: 1
                )
        )
        .onHover { onHover($0) }
    }
}
