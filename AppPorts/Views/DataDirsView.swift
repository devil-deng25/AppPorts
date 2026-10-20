//
//  DataDirsView.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/3/4.
//

import SwiftUI

// MARK: - 数据目录分组

/// 按数据类型分组的目录集合
struct DataDirGroup {
    let type: DataDirType
    let items: [DataDirItem]
}

// MARK: - 数据目录主视图

/// 数据目录管理视图（主界面 Tab 三）
///
/// 展示两类数据目录：
/// - 已知工具 dotFolder（~/.npm、~/.m2 等）
/// - 本地应用在 ~/Library/ 下的关联数据（需用户选择应用）
struct DataDirsView: View {
    @ObservedObject private var languageManager = LanguageManager.shared
    @ObservedObject private var operationState = AppOperationState.shared

    // MARK: - 外部依赖
    /// 外部存储路径（共用 ContentView 中的选择）
    let externalDriveURL: URL?
    /// 本地已扫描的应用列表（供用户选择查关联目录用）
    let localApps: [AppItem]
    /// 当前数据目录子页面，由 ContentView 顶部工具栏统一控制
    @Binding var selectedTab: DataTab
    /// 当前选中的应用数据来源应用，由 ContentView 顶部工具栏读取重签名状态。
    @Binding var selectedApp: AppItem?
    /// 当前扫描状态，由 ContentView 顶部刷新按钮读取。
    @Binding var isScanning: Bool
    /// 经典数据迁移模式生效：容器目录允许符号链接迁移，沙盒应用允许重签名。
    let classicModeActive: Bool
    /// 父级工具栏触发刷新时递增。
    let refreshTrigger: Int
    /// 选择外部存储路径的回调
    let onSelectExternalDrive: () -> URL?
    /// 打开签名修复面板
    var onRepairSignature: ((AppItem) -> Void)? = nil
    /// 独立手动重签，不与迁移组成一个操作。
    let onResignApp: ((AppItem) -> Void)?
    /// 解析应用真实路径（已链接→外部，未链接→本地），不返回假壳路径
    let resolveRealAppURL: (AppItem) throws -> URL

    // MARK: - 内部状态
    @State private var weChatPreferenceRevision = 0
    @State private var weChatContainerIdentifier = PartialWeChatMigrationPolicy.bundleIdentifier
    @State private var weChatMigrationItem: DataDirItem?
    @State private var weChatMigrationMode: WeChatAccountMigrationService.Mode = .whole
    @State private var dotFolderItems: [DataDirItem] = []
    @State private var libraryItems:   [DataDirItem] = []
    @State private var directoryRevealRequest: DataDirTree.RevealRequest?
    @State private var summaryFilter: DataDirTree.SummaryFilter?
    @State private var dotFolderReadIssues: [DataDirReadIssue] = []
    @State private var libraryReadIssues: [DataDirReadIssue] = []
    @State private var libraryIdentityIssue: AppIdentityIssue?
    @State private var selectedAppIsWeChat = false
    @State private var showReadinessCheck = false
    @AppStorage("showZeroByteDataDirectories") private var showZeroByteDirectories = false
    @AppStorage("showLockedAppDataDirectoryStructure") private var showLockedDirectoryStructure = false
    @AppStorage("showNonMigratableAppDataDirectories") private var showNonMigratableDirectories = false

    @State private var showAppDataFilters = false
    @State private var selectedPriorityFilters: Set<DataDirPriority> = []
    @State private var selectedStatusFilters: Set<String> = []
    @State private var selectedTypeFilters: Set<DataDirType> = []
    @State private var selectedAppDataSortMode: AppDataSortMode = .defaultOrder

    // 进度弹窗
    @State private var showProgress = false
    @State private var progressTitle = ""
    @State private var transferProgress = DataTransferProgress()

    // 确认弹窗
    @State private var confirmRequest: WarningSheetRequest?
    @State private var managedLinkNormalizationRequest: WarningSheetRequest?
    @State private var managedLinkNormalizationItem: DataDirItem? = nil
    @State private var managedLinkNormalizationCurrentTarget: URL? = nil
    @State private var migrationRiskRequest: WarningSheetRequest?

    // 挂载迁移（沙盒应用容器数据）
    @State private var selectedAppIsSandboxed = false
    @State private var mountMigrationRequest: WarningSheetRequest?
    @State private var pendingMountMigrationItem: DataDirItem? = nil
    /// 挂载迁移前正在检查目标盘；检查期间忽略重复点击
    @State private var isCheckingMountDestination = false
    @State private var pendingCleanups: [ContainerCleanupRecord] = []
    @State private var dataTransfers: [DataTransferRecord] = []
    @State private var preservedMaterials: [DataTransferMaterial] = []
    @State private var cleanupWarning: ContainerVolumeMigrator.CleanupWarning?
    @State private var showCleanupWarning = false
    @State private var dataCompletionWarning = ""
    @State private var showDataCompletionWarning = false

    // 错误弹窗
    @State private var showError = false
    @State private var errorMessage = ""

    // 选中项（用于高亮）
    @State private var selectedItemID: String? = nil
    @State private var dotFolderScanToken = UUID()
    @State private var libraryScanToken = UUID()
    @State private var directoryScanTask: Task<Void, Never>?
    @State private var hasLoadedDirectories = false

    // 搜索
    @State private var appSearchText = ""
    @State private var directorySearchText = ""

    enum DataTab: String, CaseIterable {
        case toolDirs  = "工具目录"
        case appDirs   = "应用数据"
    }

    enum AppDataSortMode: String, CaseIterable {
        case defaultOrder = "默认"
        case size = "按大小"
        case alphabetical = "按首字母"

        var localizedTitle: String {
            switch self {
            case .defaultOrder:
                return "默认".localized
            case .size:
                return "按大小".localized
            case .alphabetical:
                return "按首字母".localized
            }
        }
    }

    private let appDataStatusOrder = ["本地", "已链接", "已挂载", "待挂载", "卷丢失", "待规范", "现有软链", "用户目录入口", "待接回", "待完成", "未找到"]

    private var partialWeChatMigrationEnabled: Bool {
        _ = weChatPreferenceRevision
        return selectedApp.map { MigrationPreferences.isPartialWeChatMigrationEnabled(for: $0.path) } ?? false
    }

    private var selectedWeChatPolicy: PartialWeChatMigrationPolicy {
        PartialWeChatMigrationPolicy(containerIdentifier: weChatContainerIdentifier)
    }

    private var partialWeChatMigrationBinding: Binding<Bool> {
        Binding(get: { partialWeChatMigrationEnabled }, set: { enabled in
            guard let app = selectedApp else { return }
            MigrationPreferences.setPartialWeChatMigrationEnabled(enabled, for: app.path)
            weChatPreferenceRevision += 1
            clearAppDataFilters()
            directorySearchText = ""
            clearSizeCache()
            scanLibraryDirs(for: app)
        })
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if dataTransfers.contains(where: { $0.retainedCopyRemovedAt == nil }) || !pendingCleanups.isEmpty || !preservedMaterials.isEmpty {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("操作尚未全部完成，AppPorts 会自动继续处理。".localized)
                        if let reason = dataTransfers.compactMap(\.recoverableReason).first ?? preservedMaterials.first?.reason {
                            Text(verbatim: reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("重试".localized) { retryPendingOperations() }
                }
                .padding(12)
            }
            // ── 主内容区 ────────────────────────────────────────
            if selectedTab == .toolDirs {
                toolDirsContent
            } else {
                appDirsContent
            }
        }
        .disabled(operationState.isBusy)
        .onAppear {
            guard !hasLoadedDirectories else { return }
            hasLoadedDirectories = true
            reloadCurrentTab()
        }
        .onChange(of: selectedTab) { _ in
            directoryRevealRequest = nil
            summaryFilter = nil
            reloadCurrentTab()
        }
        .onDisappear {
            if isScanning { hasLoadedDirectories = false }
            directoryScanTask?.cancel()
            dotFolderScanToken = UUID()
            libraryScanToken = UUID()
            isScanning = false
        }
        .onChange(of: refreshTrigger) { _ in
            clearSizeCache()
            reloadCurrentTab()
        }
        .sheet(item: $weChatMigrationItem) { item in
            WeChatAccountMigrationSheet(item: item, containerIdentifier: weChatContainerIdentifier) { mode in
                weChatMigrationItem = nil
                weChatMigrationMode = mode
                checkMountMigrationDestination(for: item, destination: externalDriveURL)
            }
        }
        // 确认弹窗
        .warningSheet($confirmRequest)
        .warningSheet($managedLinkNormalizationRequest)
        .warningSheet($migrationRiskRequest)
        .warningSheet($mountMigrationRequest)
        .sheet(isPresented: $showReadinessCheck) {
            ReadinessCheckSheet()
        }
        // 错误弹窗
        .alert("操作失败".localized, isPresented: $showError) {
            Button("好的".localized, role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .alert("操作尚未完成".localized, isPresented: $showDataCompletionWarning) {
            Button("好的".localized, role: .cancel) {}
        } message: {
            Text(dataCompletionWarning)
        }
        .alert("操作尚未完成".localized, isPresented: $showCleanupWarning) {
            Button("重试".localized) { retryPendingOperations() }
            Button("稍后".localized, role: .cancel) {}
        } message: {
            Text(cleanupWarning?.message ?? "")
        }
        // 进度覆盖层
        .overlay {
            if showProgress {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    DataDirProgressOverlay(
                        title: progressTitle,
                        progress: transferProgress
                    )
                }
            }
        }
    }

    // MARK: - 工具目录 Tab

    private var toolDirsContent: some View {
        VStack(spacing: 0) {
            // 外部存储路径提示区
            if externalDriveURL == nil {
                externalDriveWarning
            }

            // 统计栏
            if !dotFolderItems.isEmpty {
                statsBar(items: filteredDotFolderItems)
            }

            // 列表
            ZStack {
                Color(nsColor: .controlBackgroundColor).ignoresSafeArea()

                if isScanning && dotFolderItems.isEmpty {
                    loadingView
                } else if dotFolderItems.isEmpty {
                    ContentView.EmptyStateView(icon: "folder.badge.questionmark", text: "未发现已知工具目录".localized)
                } else if filteredDotFolderItems.isEmpty {
                    ContentView.EmptyStateView(icon: "line.3.horizontal.decrease.circle", text: "没有匹配当前筛选条件的数据目录".localized)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(filteredDotFolderItems) { item in
                                DataDirRowView(
                                    item: item,
                                    isSelected: selectedItemID == item.id,
                                    onMigrate: { askMigrate($0) },
                                    onRestore: { askRestore($0) },
                                    onManageExistingLink: { askManageExistingLink($0) },
                                    onNormalizeManagedLink: { askNormalizeManagedLink($0) },
                                    onRelinkExternalData: { askRelinkExternalData($0) }
                                )
                                .onTapGesture { selectedItemID = item.id }
                                .padding(.horizontal, 12)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        }
    }

    // MARK: - 应用数据 Tab

    private var appDirsContent: some View {
        HSplitView {
            // 左侧：应用选择列表
            VStack(spacing: 0) {
                appSelectionHeader

                if localApps.isEmpty {
                    ContentView.EmptyStateView(icon: "app.dashed", text: "无本地应用".localized)
                } else {
                    let filteredApps = localApps.filter { app in
                        !app.isFolder && (appSearchText.isEmpty || app.displayName.localizedCaseInsensitiveContains(appSearchText) || app.name.localizedCaseInsensitiveContains(appSearchText))
                    }
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(filteredApps, id: \.id) { app in
                                Button {
                                    selectedApp = app
                                } label: {
                                    AppListRow(app: app, isSelected: selectedApp?.id == app.id)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(app.displayName)
                                .accessibilityAddTraits(selectedApp?.id == app.id ? .isSelected : [])
                            }
                        }
                        .padding(.bottom, 12)
                        .padding(.horizontal, 12)
                    }
                }
            }
            .frame(minWidth: 200, maxWidth: 280)
            .onChange(of: selectedApp?.path) { _ in
                selectedAppIsWeChat = false
                directorySearchText = ""
                directoryRevealRequest = nil
                summaryFilter = nil
                if let app = selectedApp { scanLibraryDirs(for: app) }
                else {
                    directoryScanTask?.cancel()
                    libraryScanToken = UUID()
                    libraryItems = []
                    libraryReadIssues = []
                    libraryIdentityIssue = nil
                    selectedAppIsSandboxed = false
                    isScanning = false
                }
            }
            .onChange(of: localApps) { newApps in
                // 重签名/迁移后刷新 selectedApp，避免持有旧的 isResigned 等字段
                // 更新应用展示信息，不因后台列表更新重新扫描数据目录。
                if let selected = selectedApp,
                   let refreshed = newApps.first(where: { $0.path == selected.path }) {
                    selectedApp = refreshed
                }
            }

            // 右侧：关联数据目录
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        if let app = selectedApp {
                            Text(String(format: "%@ 的数据目录".localized, app.displayName))
                        } else {
                            Text("请从左侧选择应用".localized)
                        }
                        if selectedAppIsWeChat {
                            Toggle("微信账号拆分迁移".localized, isOn: partialWeChatMigrationBinding)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .font(.system(size: 12))
                                .fixedSize()
                        }
                        Spacer()
                        if selectedApp != nil {
                            appDataSortMenu
                            appDataFilterButton
                        }
                    }
                    .frame(minHeight: 22)

                    if selectedApp != nil {
                        directorySearchField
                        if hasActiveAppDataFilters { appDataFilterSummary }
                        if !libraryItems.isEmpty || !libraryReadIssues.isEmpty || libraryIdentityIssue != nil {
                            VStack(alignment: .leading, spacing: 8) {
                                statsSummary(
                                    items: summaryBaseLibraryItems,
                                    allItems: libraryItems,
                                    readIssues: libraryReadIssues,
                                    hasIdentityIssue: libraryIdentityIssue != nil,
                                    displayedItems: filteredLibraryItems,
                                    onSelectSummary: selectSummaryFilter
                                )
                                appDataVisibilityToggles
                            }
                        }
                        if let issue = libraryIdentityIssue {
                            appIdentityWarning(issue: issue)
                        }
                        if !libraryReadIssues.isEmpty {
                            directoryReadWarning(issues: libraryReadIssues)
                        }
                    }
                }
                .font(.headline)
                .settingsCardBackground(opacity: 0.05)
                .padding(12)

                // 外部存储路径提示
                if externalDriveURL == nil { externalDriveWarning }

                if let app = selectedApp, app.needsSignatureAttention {
                    signatureReplacedBanner(for: app)
                }

                ZStack {
                    Color(nsColor: .controlBackgroundColor).ignoresSafeArea()

                    if selectedApp == nil {
                        ContentView.EmptyStateView(icon: "arrow.left.circle", text: "从左侧选择一个应用".localized)
                    } else if isScanning && libraryItems.isEmpty {
                        loadingView
                    } else if libraryItems.isEmpty {
                        if libraryIdentityIssue != nil {
                            ContentView.EmptyStateView(icon: "exclamationmark.circle", text: "无法完整识别应用数据".localized)
                        } else if !libraryReadIssues.isEmpty {
                            ContentView.EmptyStateView(icon: "exclamationmark.circle", text: "部分目录无法读取，请检查后刷新。".localized)
                        } else {
                            ContentView.EmptyStateView(icon: "folder.badge.questionmark", text: "未找到关联数据目录".localized)
                        }
                    } else if sortedFilteredLibraryItems.isEmpty {
                        ContentView.EmptyStateView(icon: "line.3.horizontal.decrease.circle", text: "没有匹配当前筛选条件的数据目录".localized)
                    } else {
                        AppDataDirectoryBrowser(
                            groups: groupedLibraryItems,
                            matchingItemIDs: Set(filteredLibraryItems.map(\.id)),
                            isFiltering: hasActiveAppDataFilters || !directorySearchText.isEmpty,
                            showLockedStructure: showLockedDirectoryStructure,
                            revealRequest: directoryRevealRequest,
                            actions: directoryOperationButtons
                        )
                    }
                }
            }
            .frame(minWidth: 340, maxWidth: .infinity)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - 辅助子视图

    private var appSelectionHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("应用".localized)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("\(localApps.filter { !$0.isFolder }.count)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                        .fixedSize()
                }

                Spacer(minLength: 4)

            }
            .padding(.horizontal, 10)
            .frame(minHeight: 28)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(.primary.opacity(0.6))
                    .frame(width: 32)
                TextField(
                    "搜索应用...".localized,
                    text: $appSearchText,
                    prompt: Text("搜索应用...".localized).foregroundColor(.primary.opacity(0.6))
                )
                    .textFieldStyle(.plain)
                    .foregroundColor(.primary)
                    .onExitCommand { appSearchText = "" }
                if !appSearchText.isEmpty {
                    Button { appSearchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索".localized)
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.primary.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(.horizontal, 12)
        .padding(.top, 0)
        .padding(.bottom, 12)
    }

    private var externalDriveWarning: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .foregroundColor(.orange)
            Text("请先选择外部存储路径".localized)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Button("选择外部存储".localized) { _ = onSelectExternalDrive() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .overlay(Rectangle().frame(height: 1).foregroundColor(.orange.opacity(0.2)), alignment: .bottom)
    }

    private func signatureReplacedBanner(for app: AppItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundColor(app.signatureCheckUnavailable ? .orange : .red)
            Text(app.signatureCheckUnavailable
                 ? "暂时无法检查签名。请连接外置盘后重新检查；恢复备份已保留。".localized
                 : "此应用的签名曾被 AppPorts 替换，在 macOS 27 上可能无法正常启动。如果它现在能正常启动，可以暂不处理；无法打开请根据右侧修复步骤恢复。".localized)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let onRepairSignature {
                Button(app.signatureCheckUnavailable ? "检查签名".localized : "查看修复步骤".localized) { onRepairSignature(app) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background((app.signatureCheckUnavailable ? Color.orange : .red).opacity(0.06))
        .overlay(Rectangle().frame(height: 1).foregroundColor((app.signatureCheckUnavailable ? Color.orange : .red).opacity(0.2)), alignment: .bottom)
    }

    private var directorySearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.primary.opacity(0.6))
            TextField(
                "搜索目录或路径…".localized,
                text: $directorySearchText,
                prompt: Text("搜索目录或路径…".localized).foregroundColor(.primary.opacity(0.6))
            )
                .textFieldStyle(.plain)
                .foregroundColor(.primary)
                .onExitCommand { directorySearchText = "" }
            if !directorySearchText.isEmpty {
                Button { directorySearchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索".localized)
            }
            Text(String(format: "显示 %lld / %lld".localized, Int64(filteredLibraryItems.count), Int64(libraryItems.count)))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize()
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var appDataFilterButton: some View {
        Button(action: { showAppDataFilters.toggle() }) {
            HStack(spacing: 6) {
                Image(systemName: hasActiveAppDataFilters
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
                Text("筛选".localized)
                if hasActiveAppDataFilters {
                    Text("\(activeAppDataFilterCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.14))
                        .clipShape(Capsule())
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .popover(isPresented: $showAppDataFilters, arrowEdge: .top) {
            appDataFilterPopover
        }
    }

    private var appDataSortMenu: some View {
        Menu {
            ForEach(AppDataSortMode.allCases, id: \.self) { mode in
                Button(action: { selectedAppDataSortMode = mode }) {
                    HStack {
                        Text(mode.localizedTitle)
                        Spacer()
                        if selectedAppDataSortMode == mode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down.circle")
                Text(selectedAppDataSortMode.localizedTitle)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var appDataFilterSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(String(format: "显示 %lld / %lld".localized, Int64(sortedFilteredLibraryItems.count), Int64(libraryItems.count)))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)

                Text(String(format: "排序：%@".localized, selectedAppDataSortMode.localizedTitle))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                if hasActiveAppDataFilters {
                    Button("清除筛选".localized, action: clearAppDataFilters)
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }

                Spacer()
            }

            if hasActiveAppDataFilters {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(activeAppDataFilterLabels, id: \.self) { label in
                            Text(label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.primary.opacity(0.06))
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
    }

    private var appDataFilterPopover: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("筛选应用数据".localized)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if hasActiveAppDataFilters {
                    Button("清除筛选".localized, action: clearAppDataFilters)
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("迁移建议".localized)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                ForEach(DataDirPriority.allCases, id: \.self) { priority in
                    Toggle(priority.localizedTitle, isOn: priorityFilterBinding(priority))
                        .toggleStyle(.checkbox)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("链接状态".localized)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                ForEach(appDataStatusOrder, id: \.self) { status in
                    Toggle(DataDirStatus.localized(status), isOn: statusFilterBinding(status))
                        .toggleStyle(.checkbox)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("数据类型".localized)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                ForEach(appDataFilterTypes, id: \.self) { type in
                    Toggle(type.localizedTitle, isOn: typeFilterBinding(type))
                        .toggleStyle(.checkbox)
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func statsBar(items: [DataDirItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                statsSummary(items: items, allItems: dotFolderItems, readIssues: dotFolderReadIssues)
                zeroByteDirectoriesToggle
            }
            if !dotFolderReadIssues.isEmpty {
                directoryReadWarning(issues: dotFolderReadIssues)
            }
        }
        .settingsCardBackground(opacity: 0.05)
        .padding(12)
    }

    private var appDataVisibilityToggles: some View {
        AppDataVisibilityControls(showZeroByteDirectories: $showZeroByteDirectories,
                                  showLockedStructure: $showLockedDirectoryStructure,
                                  showNonMigratableDirectories: $showNonMigratableDirectories)
    }

    private var zeroByteDirectoriesToggle: some View {
        Toggle("显示零字节目录".localized, isOn: $showZeroByteDirectories)
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .fixedSize()
    }

    private func directoryReadWarning(issues: [DataDirReadIssue]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("部分目录无法读取，请检查后刷新。".localized)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help(issues.map {
                    $0.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") + "\n" + $0.errorDescription
                }.joined(separator: "\n\n"))
            Spacer(minLength: 0)
            if issues.contains(where: \.isPermissionDenied) {
                Button("检查访问权限".localized) {
                    showReadinessCheck = true
                }
                .buttonStyle(.link)
                .help("AppPorts 读取邮件、信息等受保护的应用数据目录需要它。请在「系统设置 › 隐私与安全性 › 完全磁盘访问权限」里勾选 AppPorts。".localized)
            }
        }
        .font(.system(size: 12))
    }

    private func appIdentityWarning(issue: AppIdentityIssue) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .foregroundColor(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("应用信息读取失败，以下结果可能不完整。".localized)
                if issue.reason == .realAppUnavailable {
                    Text("请检查应用路径；若应用位于外置磁盘，请连接磁盘后刷新。".localized)
                }
            }
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .help(issue.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        .accessibilityElement(children: .combine)
    }

    private func statsSummary(
        items: [DataDirItem], allItems: [DataDirItem], readIssues: [DataDirReadIssue], hasIdentityIssue: Bool = false,
        displayedItems: [DataDirItem]? = nil,
        onSelectSummary: ((DataDirTree.SummaryFilter) -> Void)? = nil
    ) -> some View {
        let visibleItems = displayedItems ?? items
        let summary = DataDirSpaceSummary(
            items: visibleItems, allItems: allItems, hasReadIssues: !readIssues.isEmpty, hasIdentityIssue: hasIdentityIssue
        )
        let linked = items.filter { $0.status == "已链接" }.count
        let mounted = items.filter { DataDirStatus.mountStatuses.contains($0.status) }.count
        let needsNormalization = items.filter { $0.status == "待规范" }.count
        let existingSymlinks = items.filter { $0.status == "现有软链" && !$0.isUserDirectoryLink }.count
        let relinkable = items.filter { $0.status == "待接回" }.count
        return HStack(spacing: 14) {
            Label(String(format: "%lld 个目录".localized, Int64(visibleItems.count)), systemImage: "folder.fill")
                .foregroundColor(.secondary)
            if summary.isIncomplete {
                Label("空间统计不完整".localized, systemImage: "exclamationmark.circle")
                    .foregroundColor(.orange)
            } else if summary.isCalculating {
                Label("计算中...".localized, systemImage: "hourglass")
                    .foregroundColor(.secondary)
            } else if summary.reclaimableBytes > 0 {
                Label(
                    LocalizedByteCountFormatter.string(fromByteCount: summary.reclaimableBytes, allowedUnits: [.mb, .gb]) + " 可释放".localized,
                    systemImage: "sparkles"
                )
                    .foregroundColor(.accentColor)
                    .help("原件仍保留，清理后才会释放空间。".localized)
            }
            if linked > 0 {
                summaryNavigationLabel(String(format: "%lld 个已链接".localized, Int64(linked)),
                    systemImage: "link.circle.fill", color: .green,
                    filter: .linked, onSelect: onSelectSummary)
            }
            if mounted > 0 {
                summaryNavigationLabel(String(format: "%lld 个挂载迁移".localized, Int64(mounted)),
                    systemImage: "externaldrive.fill.badge.checkmark", color: .purple,
                    filter: .mounted, onSelect: onSelectSummary)
            }
            if needsNormalization > 0 {
                Label(String(format: "%lld 个待整理".localized, Int64(needsNormalization)), systemImage: "arrow.triangle.2.circlepath")
                    .foregroundColor(.mint)
            }
            if existingSymlinks > 0 {
                summaryNavigationLabel(String(format: "%lld 个现有软链".localized, Int64(existingSymlinks)),
                    systemImage: "questionmark.circle", color: .teal,
                    filter: .existingSymlink, onSelect: onSelectSummary)
            }
            if relinkable > 0 {
                Label(String(format: "%lld 个待接回".localized, Int64(relinkable)), systemImage: "arrow.triangle.branch")
                    .foregroundColor(.indigo)
            }
            Spacer()
        }
        .font(.system(size: 12))
    }

    @ViewBuilder
    private func summaryNavigationLabel(_ title: String, systemImage: String, color: Color,
                                        filter: DataDirTree.SummaryFilter, onSelect: ((DataDirTree.SummaryFilter) -> Void)?) -> some View {
        if let onSelect {
            Button { onSelect(filter) } label: {
                Label(title, systemImage: systemImage)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(summaryFilter == filter ? 0.16 : 0)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(color)
        } else {
            Label(title, systemImage: systemImage).foregroundColor(color)
        }
    }

    private func directoryOperationButtons(for item: DataDirItem) -> DataDirOperationButtons {
        DataDirOperationButtons(
            item: item,
            onMigrate: askMigrate,
            onRestore: askRestore,
            onManageExistingLink: askManageExistingLink,
            onNormalizeManagedLink: askNormalizeManagedLink,
            onRelinkExternalData: askRelinkExternalData,
            onMountMigrate: askMountMigrate,
            onMount: performMount,
            onUnmount: performUnmount,
            onMountRestore: askMountRestore,
            classicModeActive: classicModeActive,
            inline: true
        )
    }

    private func selectSummaryFilter(_ filter: DataDirTree.SummaryFilter) {
        summaryFilter = summaryFilter == filter ? nil : filter
        directoryRevealRequest = summaryFilter.map { selected in
            .init(itemIDs: Set(summaryBaseLibraryItems.filter { selected.matches($0) }.map(\.id)))
        }
    }

    private var summaryBaseLibraryItems: [DataDirItem] {
        libraryItems.filter(matchesAppDataFilters)
    }

    private var filteredLibraryItems: [DataDirItem] {
        summaryBaseLibraryItems.filter { summaryFilter?.matches($0) ?? true }
    }

    private var filteredDotFolderItems: [DataDirItem] {
        dotFolderItems.filter { showZeroByteDirectories || !$0.isEmptyLocalDirectory }
    }

    /// 链接状态优先级：已链接、挂载迁移、待规范、现有软链优先展示
    private let statusPriority: [String] = ["已链接", "已挂载", "待挂载", "卷丢失", "待规范", "现有软链", "用户目录入口", "待接回", "本地", "未找到"]

    private func statusSortKey(_ status: String) -> Int {
        statusPriority.firstIndex(of: status) ?? statusPriority.count
    }

    private var sortedFilteredLibraryItems: [DataDirItem] {
        sortedLibraryItems.filter { matchesAppDataFilters($0) && (summaryFilter?.matches($0) ?? true) }
    }

    private var sortedLibraryItems: [DataDirItem] {
        switch selectedAppDataSortMode {
        case .defaultOrder:
            // 已迁移路径在前，然后按大小降序
            return libraryItems.sorted { lhs, rhs in
                let lhsKey = statusSortKey(lhs.displayedStatus)
                let rhsKey = statusSortKey(rhs.displayedStatus)
                if lhsKey != rhsKey { return lhsKey < rhsKey }
                if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
                return lhs.path.lastPathComponent.localizedStandardCompare(rhs.path.lastPathComponent) == .orderedAscending
            }
        case .size:
            return libraryItems.sorted { lhs, rhs in
                if lhs.sizeBytes != rhs.sizeBytes {
                    return lhs.sizeBytes > rhs.sizeBytes
                }
                return lhs.path.lastPathComponent.localizedStandardCompare(rhs.path.lastPathComponent) == .orderedAscending
            }
        case .alphabetical:
            return libraryItems.sorted { lhs, rhs in
                lhs.path.lastPathComponent.localizedStandardCompare(rhs.path.lastPathComponent) == .orderedAscending
            }
        }
    }

    private var groupedLibraryItems: [DataDirGroup] {
        let matchingIDs = Set(filteredLibraryItems.map(\.id))
        let groups = Dictionary(grouping: sortedLibraryItems, by: \.type)
        return DataDirType.allCases.compactMap { type in
            guard let items = groups[type] else { return nil }
            let tree = summaryFilter.map { filter in
                DataDirTree.summaryTree(from: items.filter { matchingIDs.contains($0.id) }, filter: filter)
            } ?? DataDirTree.visibleTree(from: items,
                                              showZeroByteDirectories: showZeroByteDirectories,
                                              showLockedStructure: showLockedDirectoryStructure,
                                              matchingIDs: matchingIDs,
                                              showNonMigratableDirectories: showNonMigratableDirectories)
            return tree.isEmpty ? nil : DataDirGroup(type: type, items: tree)
        }
    }

    private var hasActiveAppDataFilters: Bool {
        summaryFilter != nil || !selectedPriorityFilters.isEmpty || !selectedStatusFilters.isEmpty || !selectedTypeFilters.isEmpty
    }

    private var activeAppDataFilterCount: Int {
        selectedPriorityFilters.count + selectedStatusFilters.count + selectedTypeFilters.count + (summaryFilter == nil ? 0 : 1)
    }

    private var activeAppDataFilterLabels: [String] {
        var labels: [String] = []
        if let summaryFilter {
            switch summaryFilter {
            case .linked: labels.append("已链接".localized)
            case .mounted: labels.append("挂载迁移".localized)
            case .existingSymlink: labels.append("现有软链".localized)
            }
        }
        labels.append(contentsOf: DataDirPriority.allCases.filter(selectedPriorityFilters.contains).map(\.localizedTitle))
        labels.append(contentsOf: appDataStatusOrder.filter(selectedStatusFilters.contains).map(DataDirStatus.localized))
        labels.append(contentsOf: appDataFilterTypes.filter(selectedTypeFilters.contains).map(\.localizedTitle))
        return labels
    }

    private var appDataFilterTypes: [DataDirType] {
        DataDirType.allCases.filter { $0 != .dotFolder }
    }

    private func matchesAppDataFilters(_ item: DataDirItem) -> Bool {
        if selectedAppIsWeChat, partialWeChatMigrationEnabled,
           !selectedWeChatPolicy.isAccount(item.path) { return false }
        let query = directorySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchesSearch = query.isEmpty || item.path.path.localizedStandardContains(query)
            || item.name.localizedStandardContains(query) || item.description.localizedStandardContains(query)
        return matchesSearch && (selectedPriorityFilters.isEmpty || selectedPriorityFilters.contains(item.priority))
            && (selectedStatusFilters.isEmpty || selectedStatusFilters.contains(item.displayedStatus))
            && (selectedTypeFilters.isEmpty || selectedTypeFilters.contains(item.type))
            && item.matchesVisibility(showZeroByteDirectories: showZeroByteDirectories,
                                      showLockedStructure: showLockedDirectoryStructure,
                                      showNonMigratableDirectories: showNonMigratableDirectories)
    }

    private func clearAppDataFilters() {
        summaryFilter = nil
        directoryRevealRequest = nil
        selectedPriorityFilters.removeAll()
        selectedStatusFilters.removeAll()
        selectedTypeFilters.removeAll()
    }

    private func priorityFilterBinding(_ priority: DataDirPriority) -> Binding<Bool> {
        Binding(
            get: { selectedPriorityFilters.contains(priority) },
            set: { isSelected in
                if isSelected {
                    selectedPriorityFilters.insert(priority)
                } else {
                    selectedPriorityFilters.remove(priority)
                }
            }
        )
    }

    private func statusFilterBinding(_ status: String) -> Binding<Bool> {
        Binding(
            get: { selectedStatusFilters.contains(status) },
            set: { isSelected in
                if isSelected {
                    selectedStatusFilters.insert(status)
                } else {
                    selectedStatusFilters.remove(status)
                }
            }
        )
    }

    private func typeFilterBinding(_ type: DataDirType) -> Binding<Bool> {
        Binding(
            get: { selectedTypeFilters.contains(type) },
            set: { isSelected in
                if isSelected {
                    selectedTypeFilters.insert(type)
                } else {
                    selectedTypeFilters.remove(type)
                }
            }
        )
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("扫描中...".localized)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 扫描逻辑

    private func reloadCurrentTab() {
        do {
            dataTransfers = try ContainerMountStore.shared.transfers()
            preservedMaterials = try ContainerMountStore.shared.preservedMaterials()
        }
        catch {
            errorMessage = error.localizedDescription
            showError = true
        }
        do { pendingCleanups = try ContainerMountStore.shared.pendingCleanups() }
        catch {
            AppLogger.shared.logError("无法读取待清理记录，保留原文件", error: error, errorCode: "CONTAINER-CLEANUP-RECORD-READ-FAILED")
        }
        AppLogger.shared.logContext(
            "刷新数据目录当前标签",
            details: [
                ("selected_tab", selectedTab == .toolDirs ? "toolDirs" : "appData"),
                ("selected_app", selectedApp?.displayName)
            ],
            level: "TRACE"
        )
        if selectedTab == .toolDirs {
            libraryScanToken = UUID()
            scanDotFolders()
        } else {
            dotFolderScanToken = UUID()
            if let app = selectedApp {
                scanLibraryDirs(for: app)
            } else {
                isScanning = false
            }
        }
    }

    private func scanDotFolders() {
        directoryScanTask?.cancel()
        let scanToken = UUID()
        dotFolderScanToken = scanToken
        isScanning = true
        dotFolderReadIssues = []
        let selectedExternalRoot = externalDriveURL
        let scanID = AppLogger.shared.makeOperationID(prefix: "scan-dot-folders")
        AppLogger.shared.logContext(
            "开始扫描工具目录",
            details: [
                ("scan_id", scanID),
                ("external_root", selectedExternalRoot?.path)
            ]
        )
        directoryScanTask = Task.detached(priority: .userInitiated) {
            let scanner = DataDirScanner()
            let items = await scanner.scanKnownDotFolders(externalRootURL: selectedExternalRoot)
            guard !Task.isCancelled else { return }
            let initialItems = items

            await MainActor.run {
                guard self.dotFolderScanToken == scanToken else { return }
                self.dotFolderItems = initialItems
            }
            AppLogger.shared.logContext(
                "工具目录扫描完成",
                details: [
                    ("scan_id", scanID),
                    ("count", String(items.count)),
                    ("statuses", Dictionary(grouping: items, by: \.status).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: ", "))
                ]
            )

            guard !Task.isCancelled else { return }
            // 每次扫描重新测量，应用运行期间的写入不能沿用上次大小。
            let sizedItems = await withTaskGroup(of: (Int, DirectorySizeResult).self) { group in
                var results: [(Int, DirectorySizeResult)] = []
                var iterator = items.indices.makeIterator()
                var active = 0
                let maxConcurrency = 4

                // 启动初始批次
                for _ in 0..<min(maxConcurrency, items.count) {
                    guard let i = iterator.next() else { break }
                    let measuredItem = items[i]
                    group.addTask { (i, measureDataDirectorySize(for: measuredItem)) }
                    active += 1
                }

                // 每完成一个再启动一个
                for await result in group {
                    results.append(result)
                    active -= 1
                    if !Task.isCancelled, let i = iterator.next() {
                        let measuredItem = items[i]
                        group.addTask { (i, measureDataDirectorySize(for: measuredItem)) }
                        active += 1
                    }
                }
                return results
            }

            await MainActor.run {
                guard self.dotFolderScanToken == scanToken else { return }
                withAnimation {
                    for (i, result) in sizedItems {
                        guard i < self.dotFolderItems.count else { continue }
                        self.dotFolderItems[i].applySize(result)
                        self.dotFolderReadIssues.append(contentsOf: result.readIssues)
                    }
                    self.isScanning = false
                }
            }
        }
    }

    private func scanLibraryDirs(for app: AppItem) {
        directoryScanTask?.cancel()
        let scanToken = UUID()
        libraryScanToken = scanToken
        isScanning = true
        libraryItems = []
        libraryReadIssues = []
        libraryIdentityIssue = nil
        let appDisplayName = app.displayName
        let appPath = app.path.standardizedFileURL
        let selectedExternalRoot = externalDriveURL
        let splitMode = MigrationPreferences.isPartialWeChatMigrationEnabled(for: app.path)
        let scanID = AppLogger.shared.makeOperationID(prefix: "scan-library-dirs")
        AppLogger.shared.logContext(
            "开始扫描应用数据目录",
            details: [
                ("scan_id", scanID),
                ("app_name", appDisplayName),
                ("app_path", app.path.path),
                ("external_root", selectedExternalRoot?.path)
            ]
        )
        directoryScanTask = Task.detached(priority: .userInitiated) {
            let matchesWeChatName = app.displayName.localizedCaseInsensitiveContains("wechat")
            let isWeChat: Bool
            let containerIdentifier: String
            if case .success(let identity) = AppIdentityResolver.resolve(at: app.displayURL) {
                isWeChat = matchesWeChatName || identity.bundleIdentifier == PartialWeChatMigrationPolicy.bundleIdentifier
                containerIdentifier = isWeChat ? identity.bundleIdentifier : PartialWeChatMigrationPolicy.bundleIdentifier
            } else {
                isWeChat = matchesWeChatName
                containerIdentifier = PartialWeChatMigrationPolicy.bundleIdentifier
            }
            let scanner = DataDirScanner(partialWeChatMigrationEnabled: splitMode && isWeChat,
                                         weChatContainerIdentifier: containerIdentifier)
            // 沙盒应用迁移数据后不能重签名；先算一次供整页使用。
            let isSandboxed = await scanner.isSandboxed(app)
            guard !Task.isCancelled else { return }
            let scanResult = await scanner.scanLibraryDirsWithDiagnostics(for: app, externalRootURL: selectedExternalRoot)
            guard !Task.isCancelled else { return }
            let items = WeChatAccountMigrationService.groupedItems(scanResult.items, splitMode: splitMode && isWeChat,
                                                                   containerIdentifier: containerIdentifier)

            await MainActor.run {
                guard self.libraryScanToken == scanToken,
                      self.selectedApp?.path.standardizedFileURL == appPath else { return }
                self.libraryItems = items
                self.libraryReadIssues = scanResult.readIssues
                self.libraryIdentityIssue = scanResult.identityIssue
                self.selectedAppIsSandboxed = isSandboxed
                self.selectedAppIsWeChat = isWeChat
                self.weChatContainerIdentifier = containerIdentifier
            }
            AppLogger.shared.logContext(
                "应用数据目录扫描完成",
                details: [
                    ("scan_id", scanID),
                    ("app_name", appDisplayName),
                    ("sandboxed", isSandboxed ? "true" : "false"),
                    ("count", String(items.count)),
                    ("statuses", Dictionary(grouping: items, by: \.status).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: ", "))
                ]
            )

            guard !Task.isCancelled else { return }
            // 并行计算所有目录大小
            let sizedItems = await withTaskGroup(of: (Int, DirectorySizeResult).self) { group in
                var results: [(Int, DirectorySizeResult)] = []
                var iterator = items.indices.makeIterator()
                var active = 0
                let maxConcurrency = 4

                // 启动初始批次
                for _ in 0..<min(maxConcurrency, items.count) {
                    guard let i = iterator.next() else { break }
                    let measuredItem = items[i]
                    group.addTask { (i, measureDataDirectorySize(for: measuredItem)) }
                    active += 1
                }

                // 每完成一个再启动一个
                for await result in group {
                    results.append(result)
                    active -= 1
                    if !Task.isCancelled, let i = iterator.next() {
                        let measuredItem = items[i]
                        group.addTask { (i, measureDataDirectorySize(for: measuredItem)) }
                        active += 1
                    }
                }
                return results
            }

            await MainActor.run {
                guard self.libraryScanToken == scanToken,
                      self.selectedApp?.path.standardizedFileURL == appPath else { return }
                withAnimation {
                    for (i, result) in sizedItems {
                        guard i < self.libraryItems.count else { continue }
                        self.libraryItems[i].applySize(result)
                        self.libraryReadIssues.append(contentsOf: result.readIssues)
                    }
                    self.isScanning = false
                }
            }
        }
    }

    // MARK: - 迁移 / 还原 确认

    private func askMigrate(_ item: DataDirItem) {
        if !item.weChatSplitMembers.isEmpty {
            weChatMigrationMode = .split
            checkMountMigrationDestination(for: item, destination: externalDriveURL)
            return
        }
        if partialWeChatMigrationEnabled, selectedWeChatPolicy.isAccount(item.path) {
            askMountMigrate(item)
            return
        }
        // 容器数据只能挂载迁移；符号链接会被内核按真实路径拒绝。经典模式下由用户自担风险。
        if item.requiresMountMigration && !classicModeActive {
            askMountMigrate(item)
            return
        }

        guard let dest = externalDriveURL else {
            AppLogger.shared.logError(
                "请求迁移数据目录被拒绝：未选择外部路径",
                context: [("item_name", item.name), ("path", item.path.path)],
                relatedURLs: [("item", item.path)]
            )
            errorMessage = "请先选择外部存储路径".localized
            showError = true
            return
        }

        // 检查关联应用是否正在运行
        if let runningAppName = runningAssociatedAppName(for: item) {
            errorMessage = String(format: "「%@」正在运行中，请先关闭该应用后再迁移其数据目录。".localized, runningAppName)
            showError = true
            return
        }

        let destPath = suggestedDestinationPath(for: item, under: dest)

        presentMigrationConfirmation(for: item, destinationPath: destPath,
                                     associatedApp: selectedTab == .appDirs ? selectedApp : nil)
    }

    private func askRestore(_ item: DataDirItem) {
        if !item.weChatSplitMembers.isEmpty { askMountRestore(item); return }
        // 检查关联应用是否正在运行
        if let runningAppName = runningAssociatedAppName(for: item) {
            errorMessage = String(format: "「%@」正在运行中，请先关闭该应用后再还原其数据目录。".localized, runningAppName)
            showError = true
            return
        }

        let linkedDest = item.linkedDestination?.path ?? "（未知）".localized

        confirmRequest = makeConfirmRequest(
            title: "还原数据目录".localized,
            actionTitle: "继续".localized,
            message: String(format: "将「%@」还原到本地。\n\n外部来源：%@\n还原到：%@\n\n校验和切换成功后自动清理外部旧副本，还原直接完成。".localized,
                item.name, linkedDest, item.path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")),
            action: { performRestore(item) }
        )
    }

    private func isContainerSymlinkOperationBlocked(_ item: DataDirItem) -> Bool {
        guard item.type == .containers || item.type == .groupContainers, !classicModeActive else { return false }
        errorMessage = "容器目录不再使用符号链接迁移。请先「还原」到本地，再使用「挂载迁移」。".localized
        showError = true
        return true
    }

    private func askManageExistingLink(_ item: DataDirItem) {
        if isContainerSymlinkOperationBlocked(item) { return }
        guard let linkedDest = item.linkedDestination else {
            AppLogger.shared.logError(
                "请求接管现有软链失败：无法读取目标路径",
                context: [("item_name", item.name), ("path", item.path.path)],
                relatedURLs: [("item", item.path)]
            )
            errorMessage = "无法读取现有软链的目标路径".localized
            showError = true
            return
        }

        confirmRequest = makeConfirmRequest(
            title: "现有软链".localized,
            actionTitle: "规范化管理".localized,
            message: String(format: "检测到「%@」已经是一个现有软链。\n\n软链路径：%@\n目标路径：%@\n\n选择「规范化管理」后，AppPorts 会将这条软链接纳入受管状态，后续可直接还原。".localized,
                item.name, item.path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), linkedDest.path),
            action: { queueManagedLinkNormalization(item, currentTarget: linkedDest) }
        )
    }

    private func askNormalizeManagedLink(_ item: DataDirItem) {
        if isContainerSymlinkOperationBlocked(item) { return }
        // 检查关联应用是否正在运行
        if let runningAppName = runningAssociatedAppName(for: item) {
            errorMessage = String(format: "「%@」正在运行中，请先关闭该应用后再整理其数据目录。".localized, runningAppName)
            showError = true
            return
        }

        guard let linkedDest = item.linkedDestination else {
            AppLogger.shared.logError(
                "请求规范化受管软链失败：无法读取目标路径",
                context: [("item_name", item.name), ("path", item.path.path)],
                relatedURLs: [("item", item.path)]
            )
            errorMessage = "无法读取已链接目录的目标路径".localized
            showError = true
            return
        }

        let normalizedTarget = normalizedManagementDestination(for: item, currentTarget: linkedDest)

        confirmRequest = makeConfirmRequest(
            title: "整理已链接目录".localized,
            actionTitle: "继续".localized,
            message: String(format: "检测到「%@」已经由 AppPorts 接管，但外部目标仍位于旧路径。\n\n当前外部路径：%@\n规范后路径：%@\n\n继续后将进入二次确认，并执行真实迁移。".localized,
                item.name, linkedDest.path, normalizedTarget.path),
            action: { queueManagedLinkNormalization(item, currentTarget: linkedDest) }
        )
    }

    private func queueManagedLinkNormalization(_ item: DataDirItem, currentTarget: URL) {
        let normalizedTarget = normalizedManagementDestination(for: item, currentTarget: currentTarget)
        let currentPath = currentTarget.path
        let normalizedPath = normalizedTarget.path
        let note = currentPath == normalizedPath
            ? "当前路径已经符合 AppPorts 的规范路径。".localized
            : "当前路径与规范路径不同。本次操作会将外部数据移动到规范路径，并重建本地软链接。".localized

        managedLinkNormalizationItem = item
        managedLinkNormalizationCurrentTarget = currentTarget
        let request = WarningSheetRequest(
            title: "确认规范化管理".localized,
            icon: "questionmark.circle.fill",
            tint: .blue,
            intro: String(format: "请确认是否继续规范化管理「%@」。\n\n现在的路径：%@\n规范后路径：%@\n\n%@".localized,
                item.name, currentPath, normalizedPath, note),
            onCancel: { clearManagedLinkNormalizationState() },
            actions: [
                WarningAction("确认".localized, style: .preferred) {
                    if let item = managedLinkNormalizationItem,
                       let target = managedLinkNormalizationCurrentTarget {
                        performManageExistingLink(item, target: target)
                    }
                    clearManagedLinkNormalizationState()
                }
            ]
        )
        confirmRequest = nil
        // 先关掉上一个弹窗，下一拍再开这一个，避免同一帧内切换 sheet。
        DispatchQueue.main.async {
            self.managedLinkNormalizationRequest = request
        }
    }

    private func askRelinkExternalData(_ item: DataDirItem) {
        if isContainerSymlinkOperationBlocked(item) { return }
        // 检查关联应用是否正在运行
        if let runningAppName = runningAssociatedAppName(for: item) {
            errorMessage = String(format: "「%@」正在运行中，请先关闭该应用后再接回其数据目录。".localized, runningAppName)
            showError = true
            return
        }

        guard let linkedDest = item.linkedDestination else {
            AppLogger.shared.logError(
                "请求接回外部数据失败：无法读取目标路径",
                context: [("item_name", item.name), ("path", item.path.path)],
                relatedURLs: [("item", item.path)]
            )
            errorMessage = "无法读取外部目录路径".localized
            showError = true
            return
        }

        confirmRequest = makeConfirmRequest(
            title: "接回外部数据".localized,
            actionTitle: "接回".localized,
            message: String(format: "检测到「%@」的数据目录已存在于外部存储，但本地原路径尚未建立链接。\n\n本地原路径：%@\n外部目录：%@\n\n选择「接回」后，AppPorts 会在原路径补建符号链接，并将其纳入受管状态。".localized,
                item.name, item.path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), linkedDest.path),
            action: { performRelinkExternalData(item, target: linkedDest) }
        )
    }

    // MARK: - 执行操作

    private func performMigrate(_ item: DataDirItem, to dest: URL, associatedApp: AppItem? = nil) {
        if let runningAppName = runningAssociatedAppName(for: item, associatedApp: associatedApp) {
            errorMessage = String(format: "「%@」正在运行中，请先关闭该应用后再迁移其数据目录。".localized, runningAppName)
            showError = true
            return
        }
        guard let operationToken = operationState.begin() else { return }
        progressTitle = String(format: "正在迁移「%@」".localized, item.name)
        transferProgress = DataTransferProgress()
        showProgress = true
        let task = Task { @MainActor in
            let operationLock = OperationLock()
            let acquired = await operationLock.acquire(timeout: OperationLock.appWaitTimeout)
            defer {
                showProgress = false
                if acquired { operationLock.release() }
                operationState.finish(operationToken)
            }
            do {
                guard acquired else { throw DataOperationSafety.Failure.occupied(item.path.path) }
                let result = try await DataMigrationWorkflow.run(validateBeforeMigration: {
                    if runningAssociatedAppName(for: item, associatedApp: associatedApp) != nil {
                        throw AppMoverError.appIsRunning
                    }
                }, migrate: {
                    try await transferProgress.track { handler in
                        try await DataDirMover().migrateAndComplete(item: item, to: dest, progressHandler: handler)
                    }
                })
                reloadCurrentTab()
                presentDataCompletionWarnings([result.cleanupWarning])
            } catch {
                reloadCurrentTab()
                errorMessage = error.localizedDescription
                showError = true
            }
        }
        operationState.registerCancellation(for: operationToken) { task.cancel() }
    }

    private func presentMigrationConfirmation(for item: DataDirItem, destinationPath: URL, associatedApp: AppItem? = nil) {
        let sizeInfo = item.size.map { String(format: "，大小约 %@".localized, $0) } ?? ""
        let detail = String(format: "将「%@」迁移到外部存储%@。\n\n源路径：%@\n目标路径：%@\n\n校验和切换成功后自动清理旧副本。应用签名保持不变。".localized,
                            item.name, sizeInfo, item.path.path, destinationPath.path)
        let ownershipNote = ownershipStorageNote(for: destinationPath)
        let execute = { performMigrate(item, to: destinationPath.deletingLastPathComponent(), associatedApp: associatedApp) }
        if classicModeActive, item.requiresMountMigration {
            var actions: [WarningAction] = [
                WarningAction("改用挂载迁移".localized) { askMountMigrate(item) }
            ]
            if let associatedApp, let onResignApp {
                actions.append(WarningAction("先手动重签".localized) { onResignApp(associatedApp) })
            }
            actions.append(WarningAction("仅迁移数据".localized, style: .preferred, handler: execute))
            migrationRiskRequest = WarningSheetRequest(
                title: "经典模式迁移".localized, tint: .orange,
                intro: detail + "\n\n" + "仍受沙盒限制的应用可能无法读取链接位置。迁移不会自动重签；仅搬完数据不代表应用兼容性已验证。".localized
                    + ownershipNote,
                actions: actions)
        } else {
            let warning = item.migrationWarning.map { "\n\n" + $0 } ?? ""
            confirmRequest = makeConfirmRequest(title: "迁移数据目录".localized, actionTitle: "继续".localized,
                                               message: detail + warning + ownershipNote, action: execute)
        }
    }

    /// 目标盘存不住文件所有者时，在确认框里补一句说明。只提示、不阻断。
    private func ownershipStorageNote(for destinationPath: URL) -> String {
        let advisory = OwnershipStorageAdvisory()
        guard let limitation = advisory.limitation(for: destinationPath) else { return "" }
        let driveName = MountMigrationGuidance.driveName(for: destinationPath.path)
        AppLogger.shared.logContext(
            "迁移目标盘不保存文件所有者",
            details: [
                ("destination", destinationPath.path),
                ("drive_name", driveName),
                ("limitation", String(describing: limitation))
            ],
            level: "WARN"
        )
        return "\n\n" + limitation.advisoryMessage(driveName: driveName)
    }

    /// 组装一个「标题 + 正文 + 单个继续按钮」的确认弹窗。
    private func makeConfirmRequest(
        title: String,
        actionTitle: String,
        message: String,
        action: @escaping () -> Void
    ) -> WarningSheetRequest {
        WarningSheetRequest(
            title: title,
            icon: "questionmark.circle.fill",
            tint: .blue,
            intro: message,
            actions: [WarningAction(actionTitle, style: .preferred, handler: action)]
        )
    }

    private func performRestore(_ item: DataDirItem) {
        if let runningAppName = runningAssociatedAppName(for: item) {
            errorMessage = String(format: "「%@」正在运行中，请先关闭该应用后再还原其数据目录。".localized, runningAppName)
            showError = true
            return
        }
        guard let operationToken = AppOperationState.shared.begin() else { return }
        progressTitle = String(format: "正在还原「%@」".localized, item.name)
        transferProgress = DataTransferProgress()
        showProgress = true
        let operationID = AppLogger.shared.makeOperationID(prefix: "view-data-restore")
        AppLogger.shared.logContext(
            "用户确认还原数据目录",
            details: [
                ("operation_id", operationID),
                ("item_name", item.name),
                ("type", item.type.rawValue),
                ("local_path", item.path.path),
                ("linked_destination", item.linkedDestination?.path)
            ] + appContextFields()
        )

        operationState.startTask(for: operationToken) { @MainActor in
            let operationLock = OperationLock()
            let lockAcquired = await operationLock.acquire(timeout: OperationLock.appWaitTimeout)
            defer {
                showProgress = false
                if lockAcquired { operationLock.release() }
                AppOperationState.shared.finish(operationToken)
            }
            let mover = DataDirMover()
            do {
                guard lockAcquired else { throw DataOperationSafety.Failure.occupied(item.path.path) }
                let result = try await transferProgress.track { handler in
                    try await mover.restoreAndComplete(item: item, progressHandler: handler)
                }

                AppLogger.shared.logContext(
                    "数据目录还原成功",
                    details: [("operation_id", operationID), ("item_name", item.name)]
                )
                await MainActor.run {
                    self.reloadCurrentTab()
                    self.presentDataCompletionWarnings([result.cleanupWarning])
                }
            } catch {
                AppLogger.shared.logError(
                    "数据目录还原失败",
                    error: error,
                    context: [("operation_id", operationID), ("item_name", item.name)],
                    relatedURLs: [("local", item.path)]
                )
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                }
            }
        }
    }

    private func performManageExistingLink(_ item: DataDirItem, target: URL) {
        if let runningAppName = runningAssociatedAppName(for: item) {
            errorMessage = String(format: "「%@」正在运行中，请先关闭该应用后再整理其数据目录。".localized, runningAppName)
            showError = true
            return
        }
        guard let operationToken = AppOperationState.shared.begin() else { return }
        progressTitle = "整理已链接目录".localized
        transferProgress = DataTransferProgress()
        showProgress = true
        let operationID = AppLogger.shared.makeOperationID(prefix: "view-data-manage-link")
        AppLogger.shared.logContext(
            "用户确认接管现有软链",
            details: [
                ("operation_id", operationID),
                ("item_name", item.name),
                ("local_path", item.path.path),
                ("target", target.path)
            ] + appContextFields()
        )
        operationState.startTask(for: operationToken) { @MainActor in
            let operationLock = OperationLock()
            let lockAcquired = await operationLock.acquire(timeout: OperationLock.appWaitTimeout)
            defer {
                if lockAcquired { operationLock.release() }
                showProgress = false
                AppOperationState.shared.finish(operationToken)
            }
            guard lockAcquired else {
                errorMessage = operationLock.admissionFailureReason ?? "后台正在连接外部存储，本次操作尚未开始。请稍后重试。".localized
                showError = true
                return
            }
            let mover = DataDirMover()
            let normalizedTarget = normalizedManagementDestination(for: item, currentTarget: target)
            do {
                let result = try await transferProgress.track { handler in
                    try await mover.normalizeManagedLinkAndComplete(
                        localPath: item.path,
                        currentExternalPath: target,
                        normalizedExternalPath: normalizedTarget,
                        progressHandler: handler
                    )
                }

                await MainActor.run {
                    self.reloadCurrentTab()
                    self.presentDataCompletionWarnings([result.cleanupWarning])
                }
            } catch {
                AppLogger.shared.logError(
                    "接管现有软链失败",
                    error: error,
                    context: [("operation_id", operationID), ("item_name", item.name)],
                    relatedURLs: [("local", item.path), ("target", target)]
                )
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                }
            }
        }
    }

    private func performRelinkExternalData(_ item: DataDirItem, target: URL) {
        if let runningAppName = runningAssociatedAppName(for: item) {
            errorMessage = String(format: "「%@」正在运行中，请先关闭该应用后再接回其数据目录。".localized, runningAppName)
            showError = true
            return
        }
        guard let operationToken = AppOperationState.shared.begin() else { return }
        progressTitle = "接回外部数据".localized
        transferProgress = DataTransferProgress()
        showProgress = true
        let operationID = AppLogger.shared.makeOperationID(prefix: "view-data-relink")
        AppLogger.shared.logContext(
            "用户确认接回外部数据",
            details: [
                ("operation_id", operationID),
                ("item_name", item.name),
                ("local_path", item.path.path),
                ("target", target.path)
            ] + appContextFields()
        )
        operationState.startTask(for: operationToken) { @MainActor in
            let operationLock = OperationLock()
            let lockAcquired = await operationLock.acquire(timeout: OperationLock.appWaitTimeout)
            defer {
                if lockAcquired { operationLock.release() }
                showProgress = false
                AppOperationState.shared.finish(operationToken)
            }
            guard lockAcquired else {
                errorMessage = operationLock.admissionFailureReason ?? "后台正在连接外部存储，本次操作尚未开始。请稍后重试。".localized
                showError = true
                return
            }
            let mover = DataDirMover()
            do {
                try await transferProgress.track { _ in
                    try await mover.createLink(localPath: item.path, externalPath: target,
                        bundleIdentifier: item.associatedBundleIdentifier, appName: item.associatedAppName)
                }
                AppLogger.shared.logContext(
                    "接回外部数据成功",
                    details: [("operation_id", operationID), ("item_name", item.name)]
                )
                await MainActor.run {
                    self.reloadCurrentTab()
                }
            } catch {
                AppLogger.shared.logError(
                    "接回外部数据失败",
                    error: error,
                    context: [("operation_id", operationID), ("item_name", item.name)],
                    relatedURLs: [("local", item.path), ("target", target)]
                )
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                }
            }
        }
    }

    // MARK: - 挂载迁移（沙盒应用容器数据）

    private func askMountMigrate(_ item: DataDirItem) {
        if partialWeChatMigrationEnabled, selectedWeChatPolicy.isAccount(item.path) {
            if requestAssociatedAppExit(for: item, continuing: { askMountMigrate(item) }) { return }
            weChatMigrationItem = item
            return
        }
        weChatMigrationMode = .whole
        checkMountMigrationDestination(for: item, destination: externalDriveURL)
    }

    private func checkMountMigrationDestination(for item: DataDirItem, destination: URL?) {
        // 直接从下载文件夹或安装包里打开时，macOS 把 AppPorts 放在退出即消失的临时路径上；
        // 登录代理必须指向一个固定的程序，开机后才有人把卷挂回来。
        if ContainerMountAgentInstaller.isRunningFromTemporaryLocation {
            errorMessage = "AppPorts 当前从临时位置运行（直接从下载文件夹或安装包里打开时，macOS 会这样处理）。挂载迁移需要在每次登录后自动重新挂载，请先把 AppPorts 拖到「应用程序」文件夹，再从那里打开。".localized
            showError = true
            return
        }
        if requestAssociatedAppExit(for: item, continuing: { checkMountMigrationDestination(for: item, destination: destination) }) { return }
        guard !isCheckingMountDestination else { return }
        isCheckingMountDestination = true
        let sourceAppID = selectedApp?.id
        Task { @MainActor in
            // 先只读检查目标盘（格式、加密、空间），再决定给确认框还是给引导。
            let outcome = await MountMigrationPreflight().evaluate(destination: destination, dataBytes: item.sizeBytes)
            isCheckingMountDestination = false
            guard selectedApp?.id == sourceAppID, !operationState.isBusy else { return }
            AppLogger.shared.logContext(
                "挂载迁移前检查目标盘",
                details: [
                    ("item_name", item.name),
                    ("external_root", destination?.path),
                    ("outcome", String(describing: outcome))
                ]
            )
            presentMountMigrationGuidance(for: item, destination: destination, outcome: outcome)
        }
    }

    /// 按检查结果展示确认框或引导。只有「可以迁移」时才有「迁移数据」按钮。
    private func presentMountMigrationGuidance(
        for item: DataDirItem,
        destination: URL?,
        outcome: MountMigrationPreflight.Outcome
    ) {
        let guidance = MountMigrationGuidance.make(
            outcome: outcome,
            appName: selectedApp?.displayName ?? item.name,
            dataSize: item.size,
            sourcePath: item.path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
            destinationPath: destination?.path
        )
        pendingMountMigrationItem = item
        mountMigrationRequest = WarningSheetRequest(
            title: guidance.title,
            icon: guidance.icon,
            tint: guidance.isReady ? .blue : .orange,
            intro: guidance.intro,
            bullets: guidance.bullets.map { WarningBullet($0.icon, $0.text) },
            detail: guidance.detail,
            cancelTitle: guidance.cancelTitle,
            onCancel: { pendingMountMigrationItem = nil },
            actions: guidance.actions.map { action in
                WarningAction(action.title, style: action.isPrimary ? .preferred : .normal) {
                    pendingMountMigrationItem = nil
                    switch action.kind {
                    case .migrate:
                        performMountMigrate(item)
                    case .chooseDestination:
                        if let chosenDestination = onSelectExternalDrive() {
                            checkMountMigrationDestination(for: item, destination: chosenDestination)
                        }
                    case .openGuide(let page, let anchor):
                        NSWorkspace.shared.open(DocumentationLink.url(page: page, anchor: anchor))
                    case .recheck:
                        askMountMigrate(item)
                    }
                }
            }
        )
    }

    private func performMountMigrate(_ item: DataDirItem) {
        if weChatMigrationMode == .split, selectedWeChatPolicy.isAccount(item.path) {
            performWeChatSplitOperation(item, restoring: false)
            return
        }
        guard let dest = externalDriveURL else { return }
        if requestAssociatedAppExit(for: item, continuing: { performMountMigrate(item) }) { return }
        guard let operationToken = AppOperationState.shared.begin() else { return }
        progressTitle = String(format: "正在挂载迁移「%@」".localized, item.name)
        transferProgress = DataTransferProgress()
        showProgress = true
        let operationID = AppLogger.shared.makeOperationID(prefix: "view-container-mount-migrate")
        let capturedApp = selectedApp
        let appName = capturedApp?.displayName ?? item.name
        let bundleID = capturedApp.flatMap { app in
            (try? resolveRealAppURL(app)).flatMap { CodeSigner.bundleIdentifier(at: $0) }
        }
        AppLogger.shared.logContext(
            "用户确认挂载迁移容器数据目录",
            details: [
                ("operation_id", operationID),
                ("item_name", item.name),
                ("type", item.type.rawValue),
                ("source", item.path.path),
                ("external_root", dest.path)
            ] + appContextFields(for: capturedApp)
        )

        operationState.startTask(for: operationToken) { @MainActor in
            // 挂载代理也监听 /Volumes：等它跑完再动手，避免两边抢同一个挂载点。
            let operationLock = OperationLock()
            let lockAcquired = await operationLock.acquire(timeout: OperationLock.appWaitTimeout)
            defer {
                showProgress = false
                AppOperationState.shared.finish(operationToken)
                if lockAcquired { operationLock.release() }
            }
            if !lockAcquired {
                AppLogger.shared.logContext(
                    "容器操作未取得跨进程锁",
                    details: [("item_name", item.name), ("reason", "挂载代理正在运行")]
                )
                errorMessage = operationLock.admissionFailureReason ?? "后台正在连接外部存储，本次操作尚未开始。请稍后重试。".localized
                showError = true
                return
            }
            if requestAssociatedAppExit(for: item, associatedApp: capturedApp, continuing: { performMountMigrate(item) }) { return }
            let migrator = ContainerVolumeMigrator()
            do {
                let result = try await transferProgress.track { handler in
                    try await migrator.migrateAndComplete(
                        item: item,
                        externalRootURL: dest,
                        appName: appName,
                        bundleIdentifier: bundleID,
                        progressHandler: handler
                    )
                }

                AppLogger.shared.logContext(
                    "挂载迁移成功",
                    details: [("operation_id", operationID), ("item_name", item.name), ("volume", result.record.volumeName)]
                )
                await MainActor.run {
                    self.reloadCurrentTab()
                    self.presentCleanupWarning(result.cleanupWarning)
                }
            } catch {
                AppLogger.shared.logError(
                    "挂载迁移失败",
                    error: error,
                    errorCode: "CONTAINER-MOUNT-MIGRATE-FAILED",
                    context: [("operation_id", operationID), ("item_name", item.name)],
                    relatedURLs: [("source", item.path)]
                )
                await MainActor.run {
                    self.reloadCurrentTab()
                    self.presentAPFSFailure(error, item: item, retry: { performMountMigrate(item) })
                }
            }
        }
    }

    private func performMount(_ item: DataDirItem) {
        guard let record = ContainerMountStore.shared.record(forMountPoint: item.path) else {
            errorMessage = "找不到该目录的挂载记录".localized
            showError = true
            return
        }
        guard let operationToken = AppOperationState.shared.begin() else { return }
        progressTitle = String(format: "正在挂载「%@」".localized, item.name)
        transferProgress = DataTransferProgress()
        showProgress = true
        operationState.startTask(for: operationToken) { @MainActor in
            // 挂载代理也监听 /Volumes：等它跑完再动手，避免两边抢同一个挂载点。
            let operationLock = OperationLock()
            let lockAcquired = await operationLock.acquire(timeout: OperationLock.appWaitTimeout)
            defer {
                showProgress = false
                AppOperationState.shared.finish(operationToken)
                if lockAcquired { operationLock.release() }
            }
            if !lockAcquired {
                AppLogger.shared.logContext(
                    "容器操作未取得跨进程锁",
                    details: [("item_name", item.name), ("reason", "挂载代理正在运行")]
                )
                errorMessage = operationLock.admissionFailureReason ?? "后台正在连接外部存储，本次操作尚未开始。请稍后重试。".localized
                showError = true
                return
            }
            do {
                try await transferProgress.track { _ in
                    try await ContainerVolumeMigrator().mount(record: record)
                }
                await MainActor.run { self.reloadCurrentTab() }
            } catch {
                AppLogger.shared.logError(
                    "挂载容器卷失败",
                    error: error,
                    errorCode: "CONTAINER-MOUNT-FAILED",
                    context: [("item_name", item.name), ("volume", record.volumeName)],
                    relatedURLs: [("mount_point", item.path)]
                )
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                }
            }
        }
    }

    private func performUnmount(_ item: DataDirItem) {
        if let runningAppName = runningAssociatedAppName(for: item) {
            errorMessage = String(format: "「%@」正在运行中，请先关闭该应用后再卸载其数据卷。".localized, runningAppName)
            showError = true
            return
        }
        guard let record = ContainerMountStore.shared.record(forMountPoint: item.path) else {
            errorMessage = "找不到该目录的挂载记录".localized
            showError = true
            return
        }
        guard let operationToken = AppOperationState.shared.begin() else { return }
        progressTitle = String(format: "正在卸载「%@」".localized, item.name)
        transferProgress = DataTransferProgress()
        showProgress = true
        let capturedApp = selectedApp
        operationState.startTask(for: operationToken) { @MainActor in
            // 挂载代理也监听 /Volumes：等它跑完再动手，避免两边抢同一个挂载点。
            let operationLock = OperationLock()
            let lockAcquired = await operationLock.acquire(timeout: OperationLock.appWaitTimeout)
            defer {
                showProgress = false
                AppOperationState.shared.finish(operationToken)
                if lockAcquired { operationLock.release() }
            }
            if !lockAcquired {
                AppLogger.shared.logContext(
                    "容器操作未取得跨进程锁",
                    details: [("item_name", item.name), ("reason", "挂载代理正在运行")]
                )
                errorMessage = operationLock.admissionFailureReason ?? "后台正在连接外部存储，本次操作尚未开始。请稍后重试。".localized
                showError = true
                return
            }
            if let runningAppName = runningAssociatedAppName(for: item, associatedApp: capturedApp) {
                errorMessage = String(format: "「%@」正在运行中，请先关闭该应用后再卸载其数据卷。".localized, runningAppName)
                showError = true
                return
            }
            do {
                try await transferProgress.track { _ in
                    try await ContainerVolumeMigrator().unmount(record: record)
                }
                await MainActor.run { self.reloadCurrentTab() }
            } catch {
                AppLogger.shared.logError(
                    "卸载容器卷失败",
                    error: error,
                    errorCode: "CONTAINER-UNMOUNT-FAILED",
                    context: [("item_name", item.name), ("volume", record.volumeName)],
                    relatedURLs: [("mount_point", item.path)]
                )
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                }
            }
        }
    }

    private func askMountRestore(_ item: DataDirItem) {
        if !item.weChatSplitMembers.isEmpty {
            if requestAssociatedAppExit(for: item, continuing: { askMountRestore(item) }) { return }
            confirmRequest = makeConfirmRequest(title: "还原微信账号数据".localized, actionTitle: "还原".localized,
                message: "将这个账号的 msg 和 business 一起还原到本地。校验并切换成功后，自动清理外置旧副本。".localized) {
                    performWeChatSplitOperation(item, restoring: true)
                }
            return
        }
        if requestAssociatedAppExit(for: item, continuing: { askMountRestore(item) }) { return }
        guard let record = try? ContainerMountStore.shared.recordForRestore(at: item.path) else {
            errorMessage = "无法确认原位置对应的迁移记录，数据已保留，未执行还原。".localized
            showError = true
            return
        }

        confirmRequest = makeConfirmRequest(
            title: "还原挂载迁移目录".localized,
            actionTitle: "继续".localized,
            message: String(
                format: "将「%@」还原到本地。\n\n外部来源：%@\n还原到：%@\n\n校验和切换成功后自动清理外部旧副本，还原直接完成。".localized,
                item.name,
                record.volumeName,
                item.path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            ),
            action: { performMountRestore(item, record: record) }
        )
    }

    private func performMountRestore(_ item: DataDirItem, record: ContainerMountRecord) {
        if requestAssociatedAppExit(for: item, continuing: { performMountRestore(item, record: record) }) { return }
        guard let operationToken = AppOperationState.shared.begin() else { return }
        progressTitle = String(format: "正在还原「%@」".localized, item.name)
        transferProgress = DataTransferProgress()
        showProgress = true
        let operationID = AppLogger.shared.makeOperationID(prefix: "view-container-mount-restore")
        let capturedApp = selectedApp
        AppLogger.shared.logContext(
            "用户确认还原挂载迁移目录",
            details: [
                ("operation_id", operationID),
                ("item_name", item.name),
                ("mount_point", item.path.path),
                ("volume", record.volumeName)
            ] + appContextFields()
        )

        operationState.startTask(for: operationToken) { @MainActor in
            // 挂载代理也监听 /Volumes：等它跑完再动手，避免两边抢同一个挂载点。
            let operationLock = OperationLock()
            let lockAcquired = await operationLock.acquire(timeout: OperationLock.appWaitTimeout)
            defer {
                showProgress = false
                AppOperationState.shared.finish(operationToken)
                if lockAcquired { operationLock.release() }
            }
            if !lockAcquired {
                AppLogger.shared.logContext(
                    "容器操作未取得跨进程锁",
                    details: [("item_name", item.name), ("reason", "挂载代理正在运行")]
                )
                let reason = operationLock.admissionFailureReason ?? "后台正在连接外部存储，本次操作尚未开始。请稍后重试。".localized
                presentAPFSFailure(NSError(domain: "AppPorts.DataOperation", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: reason]), item: item, record: record,
                    retry: { performMountRestore(item, record: record) })
                return
            }
            if requestAssociatedAppExit(for: item, associatedApp: capturedApp,
                continuing: { performMountRestore(item, record: record) }) { return }
            do {
                let warning = try await transferProgress.track { handler in
                    try await ContainerVolumeMigrator().restoreAndComplete(record: record,
                        estimatedTotalBytes: item.sizeBytes, progressHandler: handler)
                }

                AppLogger.shared.logContext(
                    "挂载迁移目录还原成功",
                    details: [("operation_id", operationID), ("item_name", item.name)]
                )
                await MainActor.run {
                    self.reloadCurrentTab()
                    self.presentCleanupWarning(warning)
                }
            } catch {
                AppLogger.shared.logError(
                    "挂载迁移目录还原失败",
                    error: error,
                    errorCode: "CONTAINER-MOUNT-RESTORE-FAILED",
                    context: [("operation_id", operationID), ("item_name", item.name)],
                    relatedURLs: [("mount_point", item.path)]
                )
                await MainActor.run {
                    self.reloadCurrentTab()
                    self.presentAPFSFailure(error, item: item, record: record,
                        retry: { performMountRestore(item, record: record) })
                }
            }
        }
    }

    private func performWeChatSplitOperation(_ item: DataDirItem, restoring: Bool) {
        if requestAssociatedAppExit(for: item, continuing: { performWeChatSplitOperation(item, restoring: restoring) }) { return }
        guard let token = operationState.begin() else { return }
        let destination = externalDriveURL
        progressTitle = restoring ? "正在还原微信账号数据".localized : "正在拆分迁移微信账号数据".localized
        transferProgress = DataTransferProgress()
        showProgress = true
        let capturedApp = selectedApp
        let splitEnabled = partialWeChatMigrationEnabled
        let containerIdentifier = weChatContainerIdentifier
        operationState.startTask(for: token) { @MainActor in
            let lock = OperationLock()
            let acquired = await lock.acquire(timeout: OperationLock.appWaitTimeout)
            defer {
                if acquired { lock.release() }
                showProgress = false
                operationState.finish(token)
            }
            do {
                guard acquired else { throw DataOperationSafety.Failure.occupied(item.path.path) }
                if requestAssociatedAppExit(for: item, associatedApp: capturedApp,
                    continuing: { performWeChatSplitOperation(item, restoring: restoring) }) { return }
                let service = WeChatAccountMigrationService(enabled: splitEnabled, containerIdentifier: containerIdentifier)
                let warnings = try await transferProgress.track { handler in
                    if restoring { return try await service.restoreSplit(account: item.path, progress: handler) }
                    guard let destination else { throw DataOperationSafety.Failure.inspection("请先选择外部存储路径".localized) }
                    return try await service.migrate(account: item.path, mode: .split, externalRoot: destination,
                        appName: capturedApp?.displayName ?? item.name, progress: handler)
                }
                if !warnings.isEmpty {
                    dataCompletionWarning = warnings.joined(separator: "\n")
                    showDataCompletionWarning = true
                }
                reloadCurrentTab()
            } catch {
                reloadCurrentTab()
                presentAPFSFailure(error, item: item,
                    retry: { performWeChatSplitOperation(item, restoring: restoring) })
            }
        }
    }

    private func presentAPFSFailure(_ error: Error, item: DataDirItem, record: ContainerMountRecord? = nil,
                                    retry: @escaping () -> Void) {
        let record = record ?? (try? ContainerMountStore.shared.recordForRestore(at: item.path))
        var actions: [WarningAction] = []
        if DataOperationIssue.needsAccessPermission(error) {
            actions.append(WarningAction("访问权限设置".localized) {
                if let url = LaunchReadinessChecker.Item.Action.fullDiskAccess.settingsURLs.first { NSWorkspace.shared.open(url) }
                // Keep the same operation available when the user returns.
                presentAPFSFailure(error, item: item, record: record, retry: retry)
            })
        }
        actions.append(WarningAction("重试".localized, style: .preferred, handler: retry))
        confirmRequest = WarningSheetRequest(title: "数据操作未完成".localized, tint: .orange,
            intro: error.localizedDescription, cancelTitle: "稍后".localized, actions: actions)
    }

    private func requestAssociatedAppExit(for item: DataDirItem, associatedApp: AppItem? = nil,
                                          continuing action: @escaping () -> Void) -> Bool {
        let app = associatedApp ?? (selectedTab == .appDirs ? selectedApp : nil)
        let appURL = app.map { (try? resolveRealAppURL($0)) ?? $0.displayURL }
        let bundleID = appURL.flatMap { CodeSigner.bundleIdentifier(at: $0) } ?? item.associatedBundleIdentifier
        let running = NSWorkspace.shared.runningApplications.filter { candidate in
            if let appURL {
                return AppRunningState.matches(appURL: appURL, bundleIdentifier: bundleID,
                    application: .init(bundleURL: candidate.bundleURL, bundleIdentifier: candidate.bundleIdentifier))
            }
            return bundleID != nil && candidate.bundleIdentifier == bundleID
        }
        guard !running.isEmpty else { return false }
        let name = app?.displayName ?? running.first?.localizedName ?? item.name
        confirmRequest = makeConfirmRequest(title: "先退出关联应用".localized, actionTitle: "退出应用并继续".localized,
            message: String(format: "「%@」正在使用这些数据。AppPorts 将请求它正常退出，退出后继续本次操作。".localized, name)) {
                Task { @MainActor in
                    for application in running where !application.isTerminated { _ = application.terminate() }
                    let deadline = ProcessInfo.processInfo.systemUptime + 8
                    while running.contains(where: { !$0.isTerminated }), ProcessInfo.processInfo.systemUptime < deadline {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    if running.allSatisfy(\.isTerminated) { action() }
                    else {
                        confirmRequest = makeConfirmRequest(title: "等待应用退出".localized, actionTitle: "继续".localized,
                            message: "请先完成关联应用中的保存或退出确认，然后点击继续。".localized, action: action)
                    }
                }
            }
        return true
    }

    private func presentCleanupWarning(_ warning: ContainerVolumeMigrator.CleanupWarning?, additionalWarning: String? = nil) {
        if let additionalWarning {
            cleanupWarning = warning
            showCleanupWarning = false
            presentDataCompletionWarnings([warning?.message, additionalWarning])
            return
        }
        guard let warning else { return }
        cleanupWarning = warning
        showCleanupWarning = true
    }

    private func presentDataCompletionWarnings(_ warnings: [String?]) {
        dataCompletionWarning = warnings.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        showDataCompletionWarning = !dataCompletionWarning.isEmpty
    }

    private func retryPendingOperations() {
        guard let token = operationState.begin() else { return }
        transferProgress = DataTransferProgress()
        showProgress = true
        progressTitle = "正在继续处理".localized
        operationState.startTask(for: token) { @MainActor in
            let warnings = await OperationMaintenance.shared.run { progress in
                await MainActor.run { transferProgress = progress }
            }
            showProgress = false
            operationState.finish(token)
            reloadCurrentTab()
            presentDataCompletionWarnings(warnings)
        }
    }

    private func suggestedDestinationPath(for item: DataDirItem, under externalRoot: URL) -> URL {
        guard item.type != .dotFolder else {
            return externalRoot.appendingPathComponent(item.type.rawValue).appendingPathComponent(item.path.lastPathComponent)
        }

        let standardizedPath = item.path.standardizedFileURL.path
        let libraryRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library").standardizedFileURL.path

        if standardizedPath.hasPrefix(libraryRoot + "/") {
            let relativePath = String(standardizedPath.dropFirst(libraryRoot.count + 1))
            return externalRoot.appendingPathComponent(relativePath)
        }

        return externalRoot.appendingPathComponent(item.type.rawValue).appendingPathComponent(item.path.lastPathComponent)
    }

    private func normalizedManagementDestination(for item: DataDirItem, currentTarget: URL) -> URL {
        if let externalDriveURL {
            return suggestedDestinationPath(for: item, under: externalDriveURL)
        }

        if item.type != .dotFolder {
            let libraryRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library").standardizedFileURL.path
            let localPath = item.path.standardizedFileURL.path

            if localPath.hasPrefix(libraryRoot + "/") {
                let relativePath = String(localPath.dropFirst(libraryRoot.count + 1))
                if let range = currentTarget.standardizedFileURL.path.range(of: "/Library/\(relativePath)") {
                    let basePath = String(currentTarget.standardizedFileURL.path[..<range.lowerBound])
                    return URL(fileURLWithPath: basePath).appendingPathComponent(relativePath)
                }
            }
        }

        return currentTarget
    }

    private func clearManagedLinkNormalizationState() {
        managedLinkNormalizationItem = nil
        managedLinkNormalizationCurrentTarget = nil
        managedLinkNormalizationRequest = nil
    }

    // MARK: - 权限与运行检查

    /// 从 localApps 中刷新 selectedApp，确保 isResigned 等字段为最新
    private func refreshSelectedApp() {
        if let selected = selectedApp,
           let refreshed = localApps.first(where: { $0.path == selected.path }) {
            selectedApp = refreshed
        }
    }

    /// 检查数据目录关联的应用是否正在运行
    ///
    /// - 应用数据 Tab：检查 `selectedApp` 是否正在运行
    /// - 工具目录 Tab：尝试从目录路径中匹配正在运行的进程（基于 bundle ID 或路径名）
    ///
    /// - Returns: 正在运行的应用显示名称，未运行则返回 nil
    private func runningAssociatedAppName(for item: DataDirItem, associatedApp: AppItem? = nil) -> String? {
        let runningApps = NSWorkspace.shared.runningApplications.map {
            AppRunningState.RunningApplication(bundleURL: $0.bundleURL, bundleIdentifier: $0.bundleIdentifier)
        }

        // 已迁移应用的本地路径可能是 Stub，运行进程使用真实外部路径和原始 Bundle ID。
        if let app = associatedApp ?? (selectedTab == .appDirs ? selectedApp : nil) {
            if AppRunningState.isRunning(appURL: app.displayURL, applications: runningApps) {
                AppLogger.shared.logContext(
                    "拒绝操作：关联应用正在运行",
                    details: [("app_name", app.displayName), ("app_path", app.displayURL.path), ("item_name", item.name)],
                    level: "WARN"
                )
                return app.displayName
            }
            return nil
        }

        // 工具目录 Tab：尝试从目录路径或名称推断关联进程
        // 例如 ~/.npm → 检查 node/npm 进程（但通常工具目录不需要强制检查）
        // 当前不做强制阻断，因为工具目录通常不与单个 .app 绑定
        return nil
    }

    // MARK: - 日志辅助

    /// 构建关联应用的背景信息字段，供各操作日志复用
    private func appContextFields(for explicitApp: AppItem? = nil) -> [(String, String?)] {
        guard let app = explicitApp ?? selectedApp else { return [] }
        let realURL = (try? resolveRealAppURL(app)) ?? app.displayURL
        let bundleID: String? = {
            let plistURL = realURL.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: plistURL),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return nil }
            return plist["CFBundleIdentifier"] as? String
        }()
        return [
            ("app_name", app.displayName),
            ("app_status", app.status),
            ("app_is_resigned", app.isResigned ? "true" : "false"),
            ("app_bundle_id", bundleID),
            ("app_real_path", realURL.path),
        ]
    }


}

// MARK: - 应用选择列表行

/// 左侧应用列表行视图（带 Hover 和选中态）
private struct AppListRow: View {
    let app: AppItem
    let isSelected: Bool

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(url: app.displayURL, size: 32)

            Text(app.displayName)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .foregroundColor(.primary)
                .lineLimit(1)

            // 已重签名标记
            if app.isResigned {
                Image(systemName: "seal.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.teal)
                    .help("此应用已被 Ad-hoc 重签名".localized)
            }

            // Sparkle/Electron 标记
            if app.isSparkleApp {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9))
                    .foregroundColor(.teal.opacity(0.7))
                    .help("Sparkle 自更新应用".localized)
            } else if app.isElectronApp {
                Image(systemName: "atom")
                    .font(.system(size: 9))
                    .foregroundColor(.indigo.opacity(0.7))
                    .help("Electron 应用".localized)
            }

            Spacer()
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.12)
                      : (isHovered ? Color.primary.opacity(0.04) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovered)
    }
}
