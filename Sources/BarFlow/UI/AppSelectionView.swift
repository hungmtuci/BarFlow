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
            item.statusTitle.localizedCaseInsensitiveContains(trimmed) ||
            item.statusDescription.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()

            if !menuController.isAccessibilityGranted || (menuController.requiresFullDiskAccess && !menuController.isFullDiskAccessGranted) {
                permissionsOnboardingBanner
                Divider()
            }

            liveZonesPreviewSection
            Divider()

            filterAndBulkActionToolbar
            Divider()

            appListSection
            Divider()

            footerSettingsBar
        }
        .frame(minWidth: 780, idealWidth: 850, minHeight: 620, idealHeight: 690)
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
                Text("Tự động ẩn thực sự khỏi Menu Bar chính • Các app còn lại hiện gọn 1 dòng bên phải khi bấm Ctrl + B")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(0)

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Button {
                    menuController.refreshAndSyncManually()
                } label: {
                    Label("Làm mới", systemImage: "arrow.clockwise")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .help("Quét lại toàn bộ ứng dụng và tiện ích đang chạy trên Menu Bar")

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
                    HStack(spacing: 5) {
                        if menuController.isArrangingMenuBar {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                        }
                        Text(menuController.isArrangingMenuBar ? "Đang đồng bộ..." : "Áp dụng ngay")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(menuController.isArrangingMenuBar)
                .help("Đồng bộ ngay lập tức việc ẩn/hiện ứng dụng trên Menu Bar chính")
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - 2. Permissions Onboarding Banner (Accessibility + Full Disk Access on macOS 26/27)

    private var permissionsOnboardingBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            if menuController.shouldOfferMoveToApplications {
                HStack(spacing: 10) {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.blue)

                    Text("Bạn đang chạy BarFlow từ thư mục tạm/Downloads. Hãy cài vào /Applications trước khi cấp quyền để không bị mất quyền khi tải bản mới:")
                        .font(.system(size: 11.5, weight: .medium))

                    Spacer()

                    Button("Cài vào /Applications & Mở lại") {
                        menuController.installToApplicationsAndRelaunch()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .fixedSize()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if !menuController.isAccessibilityGranted {
                HStack(spacing: 12) {
                    Image(systemName: "1.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.orange)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bước 1 — Cấp quyền Trợ năng (Accessibility) để quét & kích hoạt ứng dụng Menu Bar")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("Nếu vừa cập nhật BarFlow, hãy tắt rồi bật lại công tắc BarFlow (hoặc kéo thả file BarFlow mới vào danh sách Accessibility).")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Cấp quyền Accessibility") {
                        MenuBarScanner.shared.promptForAccessibilityPermission(openSystemSettings: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.small)
                    .fixedSize()
                }
            }

            if menuController.requiresFullDiskAccess && !menuController.isFullDiskAccessGranted {
                HStack(spacing: 12) {
                    Image(systemName: menuController.isAccessibilityGranted ? "exclamationmark.lock.fill" : "2.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.red)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cần cấp quyền Full Disk Access (Truy cập Toàn bộ Đĩa) để ẩn thực sự các icon khỏi Menu Bar chính")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("Trên macOS 26/27, Apple khoá cấu hình MenuBarAgent bằng TCC. Bấm 'Cấp quyền Full Disk Access' → kéo BarFlow.app từ Finder thả vào danh sách Full Disk Access và bật công tắc → chọn Quit & Reopen.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    HStack(spacing: 6) {
                        Button("Hiện trong Finder") {
                            menuController.revealRunningAppInFinder()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()

                        Button("Cấp quyền Full Disk Access") {
                            menuController.openFullDiskAccessSettings(alsoRevealInFinder: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.small)
                        .fixedSize()
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.11))
    }

    // MARK: - 3. Live Dual-Bar Visual Preview (With Direct Bulk Transfer Buttons)

    private var liveZonesPreviewSection: some View {
        let mainApps = menuController.mainBarApps
        let secApps = menuController.secondaryBarApps

        return VStack(alignment: .leading, spacing: 10) {
            // Zone A: Main Menu Bar Preview
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Label("Giữ trên Menu Bar chính (\(mainApps.count))", systemImage: "pin.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)

                    Spacer()

                    Text("Click icon để chuyển lẻ")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)

                    Button {
                        menuController.moveAllToSecondaryBar()
                    } label: {
                        Label("Chuyển toàn bộ xuống phụ", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.blue)
                    .disabled(mainApps.isEmpty)
                    .help("Đưa toàn bộ ứng dụng đang ở Menu Bar chính xuống thanh phụ Ctrl + B")
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if mainApps.isEmpty {
                            Text("Đã chuyển toàn bộ xuống thanh phụ Ctrl + B — chỉ còn biểu tượng BarFlow trên Menu Bar chính")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(mainApps) { item in
                                PreviewChipButton(
                                    item: item,
                                    isPinnedMain: true,
                                    action: {
                                        menuController.toggleAppSelection(item)
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
                HStack(spacing: 8) {
                    Label("Hiện ở thanh phụ bên phải dưới Menu Bar khi bấm Ctrl + B (\(secApps.count))", systemImage: "menubar.arrow.down.rectangle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.blue)

                    Spacer()

                    Text("Click icon để chuyển lẻ")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)

                    Button {
                        menuController.selectAllForMainBar()
                    } label: {
                        Label("Chuyển toàn bộ lên chính", systemImage: "arrow.up.circle.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.green)
                    .disabled(secApps.isEmpty)
                    .help("Đưa toàn bộ ứng dụng từ thanh phụ Ctrl + B lên lại Menu Bar chính")
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if secApps.isEmpty {
                            Text("Không có ứng dụng ẩn — bấm 'Chuyển toàn bộ xuống phụ' hoặc tắt công tắc bên dưới để đưa vào Ctrl + B")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(secApps) { item in
                                PreviewChipButton(
                                    item: item,
                                    isPinnedMain: false,
                                    action: {
                                        menuController.toggleAppSelection(item)
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

    // MARK: - 4. Filter, Search & Direct Bulk Transfer Toolbar

    private var filterAndBulkActionToolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Tìm ứng dụng Menu Bar...", text: $menuController.searchText)
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
            .frame(minWidth: 170, maxWidth: 220)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

            Picker("", selection: $menuController.filterModeRaw) {
                Text("Tất cả (\(menuController.allRunningApps.count))").tag(AppFilterMode.all.rawValue)
                Text("Menu Bar chính (\(menuController.mainBarApps.count))").tag(AppFilterMode.mainBar.rawValue)
                Text("Thanh phụ ⌃B (\(menuController.secondaryBarApps.count))").tag(AppFilterMode.secondaryBar.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)

            Spacer(minLength: 4)

            // Explicit 1-click Bulk Transfer Buttons requested by user
            HStack(spacing: 6) {
                Button {
                    menuController.moveAllToSecondaryBar()
                } label: {
                    Label("Toàn bộ xuống phụ", systemImage: "arrow.down.to.line")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(menuController.mainBarApps.isEmpty)
                .help("Chuyển toàn bộ ứng dụng xuống thanh phụ Ctrl + B")

                Button {
                    menuController.selectAllForMainBar()
                } label: {
                    Label("Toàn bộ lên chính", systemImage: "arrow.up.to.line")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(menuController.secondaryBarApps.isEmpty)
                .help("Chuyển toàn bộ ứng dụng lên lại Menu Bar chính")
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
    }

    // MARK: - 5. Running Menu Bar Apps List

    private var appListSection: some View {
        let apps = filteredApps
        return ScrollView {
            LazyVStack(spacing: 5) {
                if apps.isEmpty {
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
                    ForEach(apps) { item in
                        AppSelectionRow(
                            item: item,
                            isSelectedOnMainBar: menuController.selectedMainBarIDs.contains(item.id),
                            onToggle: { newValue in
                                menuController.setAppSelection(item, visibleOnMainBar: newValue)
                            },
                            onRowTap: {
                                menuController.toggleAppSelection(item)
                            },
                            onTestTrigger: {
                                menuController.activateAppFromSecondaryBar(item, rightClick: false)
                            }
                        )
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }

    // MARK: - 6. Bottom Settings Bar

    private var footerSettingsBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "timer")
                    .foregroundStyle(.secondary)
                Text("Tự ẩn Ctrl + B:")
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize()
                Picker("", selection: $menuController.autoHideDuration) {
                    ForEach(AutoHideDuration.allCases) { option in
                        Text(option.shortLabel == "Thủ công" ? "Không tự ẩn" : option.title).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 115)
            }
            .fixedSize(horizontal: true, vertical: false)

            Divider()
                .frame(height: 18)

            Toggle("Ẩn các app không chọn khỏi Menu Bar chính", isOn: $menuController.isMainBarHidingEnabled)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 8)

            Toggle("Hiện khi mở app", isOn: $menuController.showSelectionOnLaunch)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .fixedSize(horizontal: true, vertical: false)

            Toggle("Ẩn khỏi Dock", isOn: $menuController.hideFromDock)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }
}

// MARK: - Supporting Row & Chip Views (Zero Parent Hover Churn)

private struct PreviewChipButton: View {
    let item: MenuBarAppItem
    let isPinnedMain: Bool
    let action: () -> Void

    @StateObject private var hover = LocalHoverBox()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(nsImage: item.appIcon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 17, height: 17)

                Text(item.appName)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(hover.isHovered
                          ? (isPinnedMain ? Color.red.opacity(0.14) : Color.green.opacity(0.16))
                          : Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if hover.isHovered != inside {
                hover.isHovered = inside
            }
        }
        .help(isPinnedMain ? "Click để chuyển \(item.appName) xuống thanh phụ Ctrl + B" : "Click để đưa \(item.appName) lên Menu Bar chính")
    }
}

private struct AppSelectionRow: View {
    let item: MenuBarAppItem
    let isSelectedOnMainBar: Bool
    let onToggle: (Bool) -> Void
    let onRowTap: () -> Void
    let onTestTrigger: () -> Void

    @StateObject private var hover = LocalHoverBox()

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: item.appIcon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)

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

                    if let bundle = item.bundleIdentifier {
                        Text(bundle)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onRowTap()
            }

            Button(action: onTestTrigger) {
                Label("Mở menu", systemImage: "cursorarrow.click")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .opacity(hover.isHovered ? 1.0 : 0.72)
            .help("Mở ngay menu của \(item.appName)")

            HStack(spacing: 8) {
                Text(isSelectedOnMainBar ? "Menu Bar chính" : "Thanh phụ ⌃B")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(isSelectedOnMainBar ? .green : .blue)
                    .frame(width: 96, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onRowTap()
                    }

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
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hover.isHovered ? Color.primary.opacity(0.05) : Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    isSelectedOnMainBar ? Color.green.opacity(0.26) : Color.primary.opacity(0.06),
                    lineWidth: 1
                )
        )
        .onHover { inside in
            if hover.isHovered != inside {
                hover.isHovered = inside
            }
        }
    }
}
