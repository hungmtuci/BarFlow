import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum AppFilterMode: String, CaseIterable, Identifiable {
    case all = "all"
    case mainBar = "main"
    case secondaryBar = "secondary"

    var id: String { rawValue }
}

struct AppSelectionView: View {
    @ObservedObject var menuController: MenuBarController
    @ObservedObject var barController: SecondaryBarController
    @ObservedObject var hotKeyService: HotKeyService
    @ObservedObject var updateService: UpdateCheckerService

    private var filterMode: AppFilterMode {
        AppFilterMode(rawValue: menuController.filterModeRaw) ?? .all
    }

    private var isSearchEmpty: Bool {
        menuController.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredApps: [MenuBarAppItem] {
        let base: [MenuBarAppItem]
        switch filterMode {
        case .all:
            base = menuController.stableAllApps
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
        .frame(minWidth: 800, idealWidth: 870, minHeight: 630, idealHeight: 700)
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
                HStack(spacing: 7) {
                    Text("BarFlow")
                        .font(.system(size: 18, weight: .bold))

                    Text("v\(updateService.currentVersion)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: Capsule())

                    Button {
                        hotKeyService.toggleRecording()
                    } label: {
                        Text(hotKeyService.isRecordingShortcut
                             ? "Bấm phím mới..."
                             : menuController.hotKeyBinding.readableDisplay)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(hotKeyService.isRecordingShortcut ? Color.orange : Color.blue)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                (hotKeyService.isRecordingShortcut ? Color.orange : Color.blue).opacity(0.14),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Bấm để đổi phím tắt mở nhanh thanh ứng dụng phụ")
                }
                Text("Chọn lọc & kéo thả sắp xếp thứ tự Trái → Phải cho cả Menu Bar chính lẫn thanh phụ \(menuController.hotKeyBinding.compactDisplay)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(0)

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                if case let .available(newVer, _, _) = updateService.state {
                    Button {
                        updateService.installAvailableUpdate()
                    } label: {
                        Label("Cập nhật v\(newVer)", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .help("Tự động tải và cài đặt BarFlow v\(newVer) từ GitHub Releases")
                }

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
                    let shortcut = menuController.hotKeyBinding.compactDisplay
                    Label(barController.isVisible ? "Ẩn thanh phụ (\(shortcut))" : "Hiện thử (\(shortcut))", systemImage: "menubar.arrow.down.rectangle")
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
                .help("Đồng bộ ngay lập tức việc ẩn/hiện & thứ tự ứng dụng trên Menu Bar chính")
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

    // MARK: - 3. Live Dual-Bar Visual Preview (Drag & Drop Left -> Right Ordering + 1-Click Transfer)

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

                    Text("Trái → Phải")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.green.opacity(0.12), in: Capsule())

                    Spacer()

                    Text("Kéo thả để sắp xếp • Click để chuyển xuống phụ")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)

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
                            Text("Đã chuyển toàn bộ xuống thanh phụ Ctrl + B — kéo thả icon vào đây hoặc bật công tắc để giữ trên Menu Bar chính")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(Array(mainApps.enumerated()), id: \.element.id) { index, item in
                                PreviewChipButton(
                                    item: item,
                                    positionNumber: index + 1,
                                    totalCount: mainApps.count,
                                    isPinnedMain: true,
                                    isBeingDragged: menuController.draggingItemID == item.id,
                                    menuController: menuController,
                                    action: {
                                        menuController.toggleAppSelection(item)
                                    }
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(minHeight: 38)
                }
                .onDrop(
                    of: [UTType.text, UTType.plainText],
                    delegate: BarZoneContainerDropDelegate(
                        toMainBar: true,
                        menuController: menuController
                    )
                )
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.green.opacity(0.32), lineWidth: 1)
                )
            }

            // Zone B: Secondary Bar Preview
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Label("Thanh phụ bên phải khi bấm \(menuController.hotKeyBinding.readableDisplay) (\(secApps.count))", systemImage: "menubar.arrow.down.rectangle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.blue)

                    Text("Trái → Phải")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.blue.opacity(0.12), in: Capsule())

                    Spacer()

                    Text("Kéo thả để sắp xếp • Click để đưa lên chính")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)

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
                            Text("Không có ứng dụng ẩn — kéo thả icon vào đây hoặc bấm 'Chuyển toàn bộ xuống phụ' để đưa vào Ctrl + B")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(Array(secApps.enumerated()), id: \.element.id) { index, item in
                                PreviewChipButton(
                                    item: item,
                                    positionNumber: index + 1,
                                    totalCount: secApps.count,
                                    isPinnedMain: false,
                                    isBeingDragged: menuController.draggingItemID == item.id,
                                    menuController: menuController,
                                    action: {
                                        menuController.toggleAppSelection(item)
                                    }
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(minHeight: 38)
                }
                .onDrop(
                    of: [UTType.text, UTType.plainText],
                    delegate: BarZoneContainerDropDelegate(
                        toMainBar: false,
                        menuController: menuController
                    )
                )
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
                Text("Tất cả (\(menuController.stableAllApps.count))").tag(AppFilterMode.all.rawValue)
                Text("Menu Bar chính (\(menuController.mainBarApps.count))").tag(AppFilterMode.mainBar.rawValue)
                Text("Thanh phụ \(menuController.hotKeyBinding.compactDisplay) (\(menuController.secondaryBarApps.count))").tag(AppFilterMode.secondaryBar.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 330)

            Spacer(minLength: 4)

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

    // MARK: - 5. Running Menu Bar Apps List (Equatable Rows + ◀/▶ Ordering + Tab Drag & Drop)

    private var appListSection: some View {
        let apps = filteredApps
        let mainApps = menuController.mainBarApps
        let secApps = menuController.secondaryBarApps

        var mainIdxMap: [String: Int] = [:]
        mainIdxMap.reserveCapacity(mainApps.count)
        for (idx, m) in mainApps.enumerated() {
            mainIdxMap[m.id] = idx
        }

        var secIdxMap: [String: Int] = [:]
        secIdxMap.reserveCapacity(secApps.count)
        for (idx, s) in secApps.enumerated() {
            secIdxMap[s.id] = idx
        }

        let allowRowDrag = isSearchEmpty && (filterMode == .mainBar || filterMode == .secondaryBar)
        let draggingID = menuController.draggingItemID

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
                        let isSelected = menuController.selectedMainBarIDs.contains(item.id)
                        let posIdx = isSelected ? (mainIdxMap[item.id] ?? 0) : (secIdxMap[item.id] ?? 0)
                        let zoneTotal = isSelected ? mainApps.count : secApps.count

                        let row = AppSelectionRow(
                            item: item,
                            isSelectedOnMainBar: isSelected,
                            positionIndex: posIdx,
                            zoneCount: zoneTotal,
                            isBeingDragged: draggingID == item.id,
                            showDragHandle: allowRowDrag,
                            onToggle: { newValue in
                                menuController.setAppSelection(item, visibleOnMainBar: newValue)
                            },
                            onRowTap: {
                                menuController.toggleAppSelection(item)
                            },
                            onMoveLeft: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    if isSelected {
                                        menuController.moveMainBarItem(id: item.id, direction: -1)
                                    } else {
                                        menuController.moveSecondaryBarItem(id: item.id, direction: -1)
                                    }
                                }
                            },
                            onMoveRight: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    if isSelected {
                                        menuController.moveMainBarItem(id: item.id, direction: 1)
                                    } else {
                                        menuController.moveSecondaryBarItem(id: item.id, direction: 1)
                                    }
                                }
                            },
                            onTestTrigger: {
                                menuController.activateAppFromSecondaryBar(item, rightClick: false)
                            }
                        )
                        .equatable()

                        if allowRowDrag {
                            row
                                .onDrag {
                                    menuController.beginDraggingItem(item.id)
                                    return NSItemProvider(object: item.id as NSString)
                                }
                                .onDrop(
                                    of: [UTType.text, UTType.plainText],
                                    delegate: BarZoneChipDropDelegate(
                                        targetItemID: item.id,
                                        isMainZone: filterMode == .mainBar,
                                        menuController: menuController
                                    )
                                )
                        } else {
                            row
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }

    // MARK: - 6. Bottom Settings Bar (Custom Hotkey, Hover/Scroll, Launch at Login & 1-Click Auto-Update)

    private var footerSettingsBar: some View {
        VStack(spacing: 8) {
            // Row 1: Shortcut Recorder + Auto-Hide + Hover Trigger + Update Checker
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "keyboard")
                        .foregroundStyle(.secondary)
                    Text("Phím tắt:")
                        .font(.system(size: 12, weight: .medium))
                        .fixedSize()

                    Button {
                        hotKeyService.toggleRecording()
                    } label: {
                        Text(hotKeyService.isRecordingShortcut
                             ? "Bấm tổ hợp phím... (Esc huỷ)"
                             : menuController.hotKeyBinding.compactDisplay)
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(hotKeyService.isRecordingShortcut ? Color.orange : Color.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(hotKeyService.isRecordingShortcut
                                          ? Color.orange.opacity(0.16)
                                          : Color.primary.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(
                                        hotKeyService.isRecordingShortcut ? Color.orange : Color.primary.opacity(0.15),
                                        lineWidth: 0.9
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Bấm vào đây rồi nhấn tổ hợp phím mới (cần kèm Ctrl / Option / Cmd, hoặc nhấn Delete để về mặc định Ctrl + B)")

                    if !menuController.hotKeyBinding.isDefault && !hotKeyService.isRecordingShortcut {
                        Button {
                            menuController.hotKeyBinding = .defaultCtrlB
                            menuController.statusMessage = "Đã khôi phục phím tắt mặc định Ctrl + B!"
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Khôi phục phím tắt mặc định Ctrl + B")
                    }
                }
                .fixedSize(horizontal: true, vertical: false)

                Divider()
                    .frame(height: 16)

                HStack(spacing: 6) {
                    Image(systemName: "timer")
                        .foregroundStyle(.secondary)
                    Text("Tự ẩn:")
                        .font(.system(size: 12, weight: .medium))
                        .fixedSize()
                    Picker("", selection: $menuController.autoHideDuration) {
                        ForEach(AutoHideDuration.allCases) { option in
                            Text(option.shortLabel == "Thủ công" ? "Không tự ẩn" : option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
                .fixedSize(horizontal: true, vertical: false)

                Divider()
                    .frame(height: 16)

                Toggle("Rê chuột vào ••• để mở", isOn: $menuController.hoverToOpenEnabled)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: true, vertical: false)
                    .help("Tự động bung thanh phụ khi rê chuột dừng 0.2s trên nút ••• (ngoài ra luôn hỗ trợ cuộn chuột 2 ngón trên •••)")

                Spacer(minLength: 6)

                footerUpdateButton
            }

            Divider()
                .opacity(0.55)

            // Row 2: Main Bar Hiding + Launch at Login + Launch Window + Dock Visibility
            HStack(spacing: 16) {
                Toggle("Ẩn các app không chọn khỏi Menu Bar chính", isOn: $menuController.isMainBarHidingEnabled)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 8)

                Toggle("Khởi động cùng macOS", isOn: $menuController.launchAtLogin)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: true, vertical: false)
                    .help("Tự động chạy ngầm BarFlow ngay khi đăng nhập vào máy Mac")

                Toggle("Hiện khi mở app", isOn: $menuController.showSelectionOnLaunch)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: true, vertical: false)

                Toggle("Ẩn khỏi Dock", isOn: $menuController.hideFromDock)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    @ViewBuilder
    private var footerUpdateButton: some View {
        switch updateService.state {
        case .checking:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.small)
                Text("Đang kiểm tra...")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .fixedSize()

        case .downloading(let ver), .installing(let ver):
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.small)
                Text("Đang cập nhật v\(ver)...")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.blue)
            }
            .fixedSize()

        case .available(let ver, _, _):
            Button {
                updateService.installAvailableUpdate()
            } label: {
                Label("Cập nhật ngay v\(ver)", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.green)
            .fixedSize()

        case .idle, .upToDate, .failed:
            Button {
                updateService.checkForUpdatesManually()
            } label: {
                Label("Kiểm tra cập nhật", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .help("Kiểm tra và tự động cập nhật phiên bản mới nhất từ GitHub Releases")
        }
    }
}

// MARK: - Supporting Chip, Drop Delegates & Equatable Row Views

private struct PreviewChipButton: View {
    let item: MenuBarAppItem
    let positionNumber: Int
    let totalCount: Int
    let isPinnedMain: Bool
    let isBeingDragged: Bool
    let menuController: MenuBarController
    let action: () -> Void

    @StateObject private var hover = LocalHoverBox()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text("\(positionNumber)")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(isPinnedMain ? Color.green : Color.blue)
                    .frame(minWidth: 14, minHeight: 14)
                    .padding(.horizontal, 2)
                    .background(
                        (isPinnedMain ? Color.green : Color.blue).opacity(0.14),
                        in: Capsule()
                    )

                Image(nsImage: item.appIcon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 17, height: 17)

                Text(item.appName)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.leading, 5)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(hover.isHovered
                          ? (isPinnedMain ? Color.red.opacity(0.13) : Color.green.opacity(0.15))
                          : Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isBeingDragged
                            ? Color.accentColor
                            : Color.primary.opacity(0.12),
                        lineWidth: isBeingDragged ? 1.4 : 0.8
                    )
            )
            .opacity(isBeingDragged ? 0.45 : 1.0)
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
            delegate: BarZoneChipDropDelegate(
                targetItemID: item.id,
                isMainZone: isPinnedMain,
                menuController: menuController
            )
        )
        .contextMenu {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    if isPinnedMain {
                        menuController.moveMainBarItem(id: item.id, direction: -1)
                    } else {
                        menuController.moveSecondaryBarItem(id: item.id, direction: -1)
                    }
                }
            } label: {
                Label("Di chuyển sang trái (◀)", systemImage: "arrow.left")
            }
            .disabled(positionNumber <= 1)

            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    if isPinnedMain {
                        menuController.moveMainBarItem(id: item.id, direction: 1)
                    } else {
                        menuController.moveSecondaryBarItem(id: item.id, direction: 1)
                    }
                }
            } label: {
                Label("Di chuyển sang phải (▶)", systemImage: "arrow.right")
            }
            .disabled(positionNumber >= totalCount)

            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    if isPinnedMain {
                        menuController.moveMainBarItemToEdge(id: item.id, toStart: true)
                    } else {
                        menuController.moveSecondaryBarItemToEdge(id: item.id, toStart: true)
                    }
                }
            } label: {
                Label("Đưa sang ngoài cùng bên trái", systemImage: "arrow.left.to.line")
            }
            .disabled(positionNumber <= 1)

            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    if isPinnedMain {
                        menuController.moveMainBarItemToEdge(id: item.id, toStart: false)
                    } else {
                        menuController.moveSecondaryBarItemToEdge(id: item.id, toStart: false)
                    }
                }
            } label: {
                Label("Đưa sang ngoài cùng bên phải", systemImage: "arrow.right.to.line")
            }
            .disabled(positionNumber >= totalCount)

            Divider()

            Button(action: action) {
                Label(
                    isPinnedMain ? "Chuyển xuống thanh phụ Ctrl + B" : "Đưa lên Menu Bar chính",
                    systemImage: isPinnedMain ? "arrow.down.circle" : "pin.fill"
                )
            }
        }
        .help(
            isPinnedMain
                ? "Vị trí #\(positionNumber) trên Menu Bar chính • Kéo thả để đổi thứ tự • Click để chuyển xuống Ctrl + B"
                : "Vị trí #\(positionNumber) trên thanh phụ Ctrl + B • Kéo thả để đổi thứ tự • Click để đưa lên Menu Bar chính"
        )
    }
}

@MainActor
private struct BarZoneChipDropDelegate: DropDelegate {
    let targetItemID: String
    let isMainZone: Bool
    let menuController: MenuBarController

    func dropEntered(info: DropInfo) {
        guard let draggedID = menuController.draggingItemID,
              draggedID != targetItemID else { return }
        withAnimation(.interactiveSpring(response: 0.20, dampingFraction: 0.84)) {
            if isMainZone {
                menuController.reorderMainBarItem(draggedID: draggedID, targetID: targetItemID)
            } else {
                menuController.reorderSecondaryBarItem(draggedID: draggedID, targetID: targetItemID)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        if let draggedID = menuController.draggingItemID, draggedID != targetItemID {
            if isMainZone {
                menuController.reorderMainBarItem(draggedID: draggedID, targetID: targetItemID)
            } else {
                menuController.reorderSecondaryBarItem(draggedID: draggedID, targetID: targetItemID)
            }
        }
        menuController.endDraggingSession()
        return true
    }
}

@MainActor
private struct BarZoneContainerDropDelegate: DropDelegate {
    let toMainBar: Bool
    let menuController: MenuBarController

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        if let draggedID = menuController.draggingItemID {
            withAnimation(.interactiveSpring(response: 0.20, dampingFraction: 0.84)) {
                menuController.dropItemIntoZone(draggedID: draggedID, toMainBar: toMainBar)
            }
        }
        menuController.endDraggingSession()
        return true
    }
}

private struct AppSelectionRow: View, Equatable {
    let item: MenuBarAppItem
    let isSelectedOnMainBar: Bool
    let positionIndex: Int
    let zoneCount: Int
    let isBeingDragged: Bool
    let showDragHandle: Bool
    let onToggle: (Bool) -> Void
    let onRowTap: () -> Void
    let onMoveLeft: () -> Void
    let onMoveRight: () -> Void
    let onTestTrigger: () -> Void

    @StateObject private var hover = LocalHoverBox()

    static func == (lhs: AppSelectionRow, rhs: AppSelectionRow) -> Bool {
        lhs.item == rhs.item &&
        lhs.isSelectedOnMainBar == rhs.isSelectedOnMainBar &&
        lhs.positionIndex == rhs.positionIndex &&
        lhs.zoneCount == rhs.zoneCount &&
        lhs.isBeingDragged == rhs.isBeingDragged &&
        lhs.showDragHandle == rhs.showDragHandle
    }

    var body: some View {
        HStack(spacing: 10) {
            if showDragHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                    .help("Kéo thả lên/xuống để đổi thứ tự Trái → Phải")
            }

            HStack(spacing: 11) {
                Image(nsImage: item.appIcon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.appName)
                            .font(.system(size: 13.5, weight: .semibold))
                            .lineLimit(1)

                        if !item.statusTitle.isEmpty {
                            Text(item.statusTitle)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.blue.opacity(0.10), in: Capsule())
                                .lineLimit(1)
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
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onRowTap()
            }

            // Direct 1-click Left / Right order controls for whichever bar this app belongs to
            HStack(spacing: 2) {
                Button(action: onMoveLeft) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(positionIndex <= 0)
                .opacity(positionIndex <= 0 ? 0.28 : 0.88)
                .help("Đẩy sang trái 1 vị trí trên \(isSelectedOnMainBar ? "Menu Bar chính" : "thanh phụ Ctrl + B")")

                Text("#\(positionIndex + 1)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isSelectedOnMainBar ? Color.green : Color.blue)
                    .frame(minWidth: 24)
                    .help("Vị trí thứ \(positionIndex + 1) (tính từ trái sang phải) trên \(isSelectedOnMainBar ? "Menu Bar chính" : "thanh phụ Ctrl + B")")

                Button(action: onMoveRight) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(positionIndex >= zoneCount - 1)
                .opacity(positionIndex >= zoneCount - 1 ? 0.28 : 0.88)
                .help("Đẩy sang phải 1 vị trí trên \(isSelectedOnMainBar ? "Menu Bar chính" : "thanh phụ Ctrl + B")")
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.045), in: Capsule())

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
                    .frame(width: 92, alignment: .trailing)
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
                    isBeingDragged
                        ? Color.accentColor
                        : (isSelectedOnMainBar ? Color.green.opacity(0.26) : Color.primary.opacity(0.06)),
                    lineWidth: isBeingDragged ? 1.4 : 1
                )
        )
        .opacity(isBeingDragged ? 0.48 : 1.0)
        .onHover { inside in
            if hover.isHovered != inside {
                hover.isHovered = inside
            }
        }
    }
}
