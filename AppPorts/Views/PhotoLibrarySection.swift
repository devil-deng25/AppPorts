//
//  PhotoLibrarySection.swift
//  AppPorts
//
//  「目录迁移」页顶部的照片图库卡片。
//
//  图库搬家本身没有新逻辑：选好目标后建立一条普通的 `CustomDirConfig`，
//  剩下的交给页面已有的迁移任务队列。这样图库迁移完成后，接回、还原、断开链接
//  在下面的列表里同样可用，不需要为照片单独维护一套状态。
//

import AppKit
import SwiftUI

@MainActor
struct PhotoLibrarySection: View {
    var isActive: Bool = true
    let configs: [CustomDirConfig]
    /// 建立配置并开始迁移；返回错误文案表示没有开始。
    var onMove: (CustomDirConfig) -> String?
    var onRestore: (CustomDirConfig) -> Void
    var onRelink: (CustomDirConfig) -> Void

    @ObservedObject private var operationState = AppOperationState.shared
    @State private var items: [PhotoLibraryItem] = []
    @State private var sizes: [String: String] = [:]
    @State private var isScanning = false
    @State private var moveTarget: PhotoLibraryItem?
    @State private var errorMessage = ""
    @State private var showError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if items.isEmpty {
                Text(isScanning ? "正在扫描...".localized : "未发现照片图库".localized)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            } else {
                ForEach(items) { item in
                    row(for: item)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(12)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .onAppear { refresh() }
        .onChange(of: isActive) { active in
            if active { refresh() } else { items = [] }
        }
        .onChange(of: configs) { _ in refresh() }
        .sheet(item: $moveTarget) { item in
            PhotoLibraryMoveSheet(item: item, existingConfigs: configs, onMove: onMove)
        }
        .alert("操作失败".localized, isPresented: $showError) {
            Button("好的".localized, role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .foregroundColor(.pink)
                    Text("照片图库".localized)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text("把「照片」图库整体搬到外置盘，本地留链接，照片 App 照常打开".localized)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func row(for item: PhotoLibraryItem) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(item.state.statusText)
                        .font(.system(size: 11))
                        .foregroundColor(item.state.needsAttention ? .orange : .secondary)
                    if let size = sizes[item.id] {
                        Text(size)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    if let destination = item.externalDestination, item.state.canRestore {
                        Text(destination.path)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(destination.path)
                    }
                }
            }

            Spacer(minLength: 8)

            actionButton(for: item)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func actionButton(for item: PhotoLibraryItem) -> some View {
        switch item.state {
        case .movable:
            Button("移动到外置盘".localized) { moveTarget = item }
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .onExternal:
            // 整个「图片」文件夹已被迁移时图库也在外置盘上，但没有自己的配置，
            // 此时还原该走那条目录的配置，这里不给按钮。
            if let config = item.config {
                Button("还原".localized) { onRestore(config) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        case .pendingRelink:
            if let config = item.config {
                Button("接回".localized) { onRelink(config) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        case .externalUnavailable, .missing:
            EmptyView()
        }
    }

    /// 扫描与度量分开：状态要立刻出来，大小可以晚一步。
    private func refresh() {
        guard isActive else { return }
        items = PhotoLibraryService.items(configs: configs)
        isScanning = true

        let targets = items.filter { $0.state.canMove || $0.state.canRestore || $0.state.canRelink }
            .map { ($0.id, $0.state.canMove ? $0.url : ($0.externalDestination ?? $0.url)) }
        guard !targets.isEmpty else {
            isScanning = false
            return
        }

        Task.detached(priority: .utility) {
            var measured: [String: String] = [:]
            for (id, url) in targets {
                if Task.isCancelled { return }
                measured[id] = PhotoLibraryService.measureSize(of: url).text
            }
            await MainActor.run {
                // 只保留当前仍在列表里的图库：扫描期间列表可能已经变了。
                let current = Set(items.map(\.id))
                sizes = measured.filter { current.contains($0.key) }
                isScanning = false
            }
        }
    }
}

// MARK: - 迁移表单

@MainActor
private struct PhotoLibraryMoveSheet: View {
    let item: PhotoLibraryItem
    let existingConfigs: [CustomDirConfig]
    let onMove: (CustomDirConfig) -> String?

    @ObservedObject private var operationState = AppOperationState.shared
    @Environment(\.dismiss) private var dismiss
    @State private var externalBaseURL: URL?
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var photosRunning = false

    private var finalDestinationURL: URL? {
        guard let externalBaseURL else { return nil }
        return externalBaseURL.appendingPathComponent(item.url.lastPathComponent).standardizedFileURL
    }

    /// 目标盘的元数据能力在选择时就要给出结论：搬完才发现打不开，代价太大。
    private var storageNotice: String? {
        guard let finalDestinationURL else { return nil }
        return PhotoLibraryService.storageLimitation(at: finalDestinationURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("移动照片图库".localized)
                .font(.title3.weight(.semibold))

            pickerRow

            if let finalDestinationURL {
                VStack(alignment: .leading, spacing: 3) {
                    Text("最终位置".localized)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Text(finalDestinationURL.path)
                        .font(.system(size: 11))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(finalDestinationURL.path)
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05))
                .cornerRadius(8)
            }

            warningBullets

            if let storageNotice {
                noticeRow(storageNotice, tint: .red)
            } else if photosRunning {
                noticeRow("照片 App 正在运行，需要先退出".localized, tint: .orange)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button { dismiss() } label: {
                    footerLabel(title: "取消".localized, icon: "xmark")
                }
                .buttonStyle(.bordered)

                Button { move() } label: {
                    footerLabel(title: "迁移".localized, icon: "arrow.right")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(operationState.blocksInteraction || isWorking
                    || externalBaseURL == nil || storageNotice != nil)
            }
        }
        .padding(24)
        .frame(width: 620)
        .onAppear { photosRunning = !PhotoLibraryService.photosApplications().isEmpty }
    }

    private var pickerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("外部目标文件夹".localized)
                .font(.system(size: 11, weight: .medium))
            HStack(spacing: 8) {
                Text(externalBaseURL?.path ?? "未选择".localized)
                    .font(.system(size: 11))
                    .foregroundColor(externalBaseURL == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(externalBaseURL?.path ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { chooseExternalBaseDirectory() } label: {
                    Label("选择外部目标文件夹".localized, systemImage: "externaldrive.badge.plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(8)
            .background(Color.primary.opacity(0.05))
            .cornerRadius(8)
        }
    }

    private var warningBullets: some View {
        VStack(alignment: .leading, spacing: 6) {
            bullet("exclamationmark.triangle",
                   "迁移期间照片 App 必须保持关闭，否则可能损坏图库".localized)
            bullet("externaldrive",
                   "外置盘未连接时照片 App 会提示找不到图库，请连接后再打开照片".localized)
            bullet("hand.point.up.left",
                   "迁移完成后直接用照片 App 打开即可，不要按住 Option 启动去切换图库".localized)
        }
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .frame(width: 14)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .foregroundColor(.secondary)
    }

    private func noticeRow(_ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(tint)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08))
        .cornerRadius(8)
    }

    private func footerLabel(title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text(title)
                .font(.system(size: 13))
        }
        .frame(minWidth: 82)
        .frame(height: 28)
    }

    private func chooseExternalBaseDirectory() {
        let panel = NSOpenPanel()
        panel.prompt = "选择文件夹".localized
        panel.message = "选择外部目标父文件夹".localized
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try CustomDirValidator.validateExternalBaseDirectory(url)
            try CustomDirValidator.validate(
                localURL: item.url,
                externalBaseURL: url,
                existingConfigs: existingConfigs
            )
        } catch {
            externalBaseURL = nil
            errorMessage = error.localizedDescription
            return
        }
        externalBaseURL = url
        errorMessage = nil
    }

    private func move() {
        guard !operationState.blocksInteraction, !isWorking,
              let externalBaseURL, let finalDestinationURL else { return }
        if let limitation = PhotoLibraryService.storageLimitation(at: finalDestinationURL) {
            errorMessage = limitation
            return
        }

        isWorking = true
        errorMessage = nil
        Task {
            let closed = await PhotoLibraryService.quitPhotos()
            guard closed else {
                isWorking = false
                photosRunning = true
                errorMessage = PhotoLibraryService.MigrationError.photosStillRunning.localizedDescription
                return
            }
            photosRunning = false
            do {
                try CustomDirValidator.validate(
                    localURL: item.url,
                    externalBaseURL: externalBaseURL,
                    existingConfigs: existingConfigs
                )
            } catch {
                isWorking = false
                errorMessage = error.localizedDescription
                return
            }

            let config = CustomDirConfig(localPath: item.url.path, externalBasePath: externalBaseURL.path)
            if let callbackError = onMove(config) {
                isWorking = false
                errorMessage = callbackError
                return
            }
            isWorking = false
            dismiss()
        }
    }
}
