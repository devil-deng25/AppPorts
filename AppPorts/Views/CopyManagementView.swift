import SwiftUI

/// Always reachable from the main toolbar, including an empty data page.
@MainActor
struct CopyManagementView: View {
    @StateObject private var model: CopyManagementModel
    @ObservedObject private var operationState: AppOperationState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation: WarningSheetRequest?
    @State private var selectedGroup: DataTransferGroup?

    init(model: CopyManagementModel? = nil, operationState: AppOperationState? = nil) {
        let state = operationState ?? .shared
        _model = StateObject(wrappedValue: model ?? CopyManagementModel(operationState: state))
        _operationState = ObservedObject(wrappedValue: state)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("副本管理".localized).font(.title2.bold())
                Spacer()
                if model.isRefreshing || model.isWorking { ProgressView().controlSize(.small) }
                Button("刷新".localized) { Task { await model.refresh() } }
                    .disabled(model.isRefreshing || model.isWorking)
            }
            Text("正常迁移和还原会自动清理旧副本。这里显示未完成的操作、清理事项和历史签名原件。".localized)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let notice = model.notice {
                Text(verbatim: notice).foregroundStyle(.orange).textSelection(.enabled)
            }
            if let error = model.errorMessage {
                Text(verbatim: error).foregroundStyle(.red).textSelection(.enabled)
            }
            List {
                ForEach(model.snapshot.readErrors, id: \.self) { message in
                    Label { Text(verbatim: message).textSelection(.enabled) }
                    icon: { Image(systemName: "exclamationmark.triangle") }
                        .foregroundStyle(.orange)
                }
                if model.snapshot.isEmpty && !model.isRefreshing && model.snapshot.readErrors.isEmpty {
                    Text("没有待处理的副本。".localized).foregroundStyle(.secondary)
                }
                if !model.snapshot.dataGroups.isEmpty {
                    Section("数据转移".localized) {
                        ForEach(model.snapshot.dataGroups) { group in dataRow(group) }
                    }
                }
                if !model.snapshot.legacyCleanups.isEmpty {
                    Section("历史数据清理".localized) {
                        ForEach(model.snapshot.legacyCleanups) { cleanup in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: cleanup.mountRecord.appName).font(.headline)
                                path(cleanup.mountRecord.mountPointURL.path)
                                if cleanup.localPath != cleanup.mountRecord.mountPointPath { path(cleanup.localPath) }
                                if let staging = cleanup.restoreStagingPath { path(staging) }
                                Text(verbatim: "APFS · " + cleanup.mountRecord.volumeUUID)
                                    .font(.caption.monospaced()).textSelection(.enabled)
                                Text("旧记录无法确认副本归属。请检查所列位置；移除记录会保留文件和卷。".localized)
                                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                Button("仅移除记录".localized) {
                                    confirm(title: "仅移除记录".localized,
                                        message: "仅移除这条记录，所有文件和卷都会保留，不会释放存储空间。请确认这些材料已由你自行处理或决定保留。".localized,
                                        action: .removeLegacyCleanupRecord(cleanup, confirmation: .keepAllFilesAndVolumes))
                                }.disabled(operationState.isBusy)
                            }
                        }
                    }
                }
                if !model.snapshot.appTransfers.isEmpty || !model.snapshot.appTransferIssues.isEmpty {
                    Section("应用转移".localized) {
                        ForEach(model.snapshot.appTransfers) { transfer in appRow(transfer) }
                        ForEach(model.snapshot.appTransferIssues) { issue in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(verbatim: issue.appName).font(.headline)
                                Text(verbatim: issue.message).foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                                path(issue.url.path)
                                ForEach(issue.knownPaths, id: \.self) { path($0) }
                            }.padding(.vertical, 5)
                                .accessibilityElement(children: .contain)
                        }
                    }
                }
                if !model.snapshot.signatureMaterials.isEmpty {
                    Section("签名原件与临时副本".localized) {
                        ForEach(model.snapshot.signatureMaterials) { material in signatureRow(material) }
                    }
                }
                if !model.snapshot.dataMaterials.isEmpty {
                    Section("已保留的材料".localized) {
                        ForEach(model.snapshot.dataMaterials) { material in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: material.appName).font(.headline)
                                Text(verbatim: material.reason).foregroundStyle(.secondary)
                                ForEach(material.paths, id: \.self) { path($0) }
                                if let uuid = material.volumeUUID {
                                    Text(verbatim: "APFS · " + uuid).font(.caption.monospaced()).textSelection(.enabled)
                                } else if let name = material.volumeName {
                                    Text(verbatim: name).font(.caption).textSelection(.enabled)
                                }
                                HStack {
                                    Button("重新检查".localized) { model.start(.recheckDataMaterial(material.id)) }
                                    Button("移除记录".localized) {
                                        confirm(title: "移除记录".localized,
                                            message: "仅移除这条记录，所有文件和卷都会保留，不会释放存储空间。请确认这些材料已由你自行处理或决定保留。".localized,
                                            action: .removeDataMaterialRecord(material.id, confirmation: .keepAllFilesAndVolumes))
                                    }
                                }.disabled(operationState.isBusy)
                            }
                            .accessibilityElement(children: .contain)
                        }
                    }
                }
            }
            .listStyle(.inset)
            HStack {
                Spacer()
                Button("关闭".localized) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 420, idealHeight: 600)
        .task { await model.refresh() }
        .onChange(of: operationState.recordsRevision) { _ in Task { await model.refresh() } }
        .warningSheet($confirmation)
        .sheet(item: $selectedGroup) { oldGroup in
            let group = model.snapshot.dataGroups.first { $0.id == oldGroup.id }
            if let group {
                DataTransferReviewView(group: group,
                    onCleanup: { model.start(.cleanupData(group)) },
                    onUnlock: { if let transfer = group.unlockTransfer { model.start(.cancelData(transfer, preserveMaterials: false)) } },
                    onResume: { if let transfer = group.resumeTransfer { model.start(.resumeData(transfer)) } })
            } else {
                VStack(spacing: 12) {
                    Text("这项操作已处理完成。".localized)
                    Button("关闭".localized) { selectedGroup = nil }
                }.padding(24)
            }
        }
    }

    private func dataRow(_ group: DataTransferGroup) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(verbatim: group.displayName).font(.headline)
                Spacer()
                Text(group.statusTitle).foregroundStyle(.secondary)
            }
            path(group.activePath)
            HStack {
                Button("查看副本".localized) { selectedGroup = group }
                if let transfer = group.resumeTransfer {
                    Button("继续".localized) { model.start(.resumeData(transfer)) }
                }
                if let transfer = group.unlockTransfer {
                    Button("取消并清理暂存".localized) { confirmDataCancellation(transfer, preserve: false) }
                    Button("结束尝试并保留材料".localized) { confirmDataCancellation(transfer, preserve: true) }
                }
            }.disabled(operationState.isBusy)
        }.padding(.vertical, 5)
            .accessibilityElement(children: .contain)
    }

    private func appRow(_ transfer: AppTransferRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(verbatim: transfer.appName).font(.headline)
            Text(transfer.phase == .cancelled ? "转移已取消，未确认的材料已保留。".localized
                : transfer.isSwitchComplete ? "应用位置已切换，仍有待办。".localized : "应用转移尚未完成。".localized)
                .foregroundStyle(.secondary)
            path(transfer.sourcePath)
            if transfer.activeDestinationPath != transfer.sourcePath { path(transfer.activeDestinationPath) }
            ForEach(transfer.pendingTasks) { task in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: task.message).font(.callout)
                    if let value = task.path, value != transfer.sourcePath && value != transfer.activeDestinationPath { path(value) }
                }
            }
            HStack {
                Button(transfer.phase == .cancelled ? "重新检查".localized
                    : transfer.isSwitchComplete ? "重试待办".localized : "继续".localized) {
                    model.start(.resumeApp(transfer.id))
                }
                if transfer.canCancel {
                    Button("取消转移".localized) {
                        confirm(title: "取消转移".localized,
                            message: "确认源应用尚未切换后，清理本次暂存。无法确认归属的对象会保留并列出。".localized,
                            action: .cancelApp(transfer.id))
                    }
                }
            }.disabled(operationState.isBusy)
        }.padding(.vertical, 5)
            .accessibilityElement(children: .contain)
    }

    private func signatureRow(_ material: SignatureMaterial) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(verbatim: material.appName).font(.headline)
                Spacer()
                if let bytes = material.sizeBytes {
                    Text(LocalizedByteCountFormatter.string(fromByteCount: bytes)).foregroundStyle(.secondary)
                }
            }
            Text(verbatim: material.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            path(material.url.path)
            HStack {
                if material.canResume {
                    Button("继续处理".localized) { model.start(.resumeSignature(material.id)) }
                }
                if material.canCancel {
                    Button("取消并清理暂存".localized) {
                        confirm(title: "取消签名操作".localized,
                            message: "确认应用尚未切换后，清理这次临时工作包。".localized,
                            action: .cancelSignature(material.id))
                    }
                }
                if material.canRestore {
                    Button("恢复此原件".localized) {
                        confirm(title: "恢复原始签名".localized,
                            message: "将核对当前应用、官方身份和版本后恢复。应用数据目录不会被替换。".localized,
                            action: .restoreSignature(material))
                    }
                }
                if material.canRemoveRecord {
                    Button("仅移除记录".localized) {
                        confirm(title: "仅移除记录".localized,
                            message: material.url.path + "\n\n" + "仅移除这条历史记录，不会删除任何文件或卷，也不会释放存储空间。原件位置可能离线或无法核实；移除记录不代表原件已删除。".localized,
                            action: .removeSignatureRecord(material.id, confirmation: .keepAllFilesAndVolumes))
                    }
                }
                if material.canDelete && material.kind != .temporaryOperation && material.kind != .unclaimedTemporary {
                    Menu("删除此原件".localized) {
                        Button("直接删除".localized, role: .destructive) {
                            confirm(title: "删除此签名恢复原件".localized,
                                message: material.url.path + "\n\n" + "删除后无法再用这份原件恢复签名，当前应用和数据会保留。".localized,
                                action: .deleteSignature(material.id, moveToTrash: false))
                        }
                        Button("移入废纸篓".localized) {
                            confirm(title: "移入废纸篓".localized,
                                message: material.url.path + "\n\n" + "这份原件仍会占用空间，AppPorts 不会清空废纸篓。".localized,
                                action: .deleteSignature(material.id, moveToTrash: true))
                        }
                    }
                }
            }.disabled(operationState.isBusy)
        }.padding(.vertical, 5)
            .accessibilityElement(children: .contain)
    }

    private func path(_ value: String) -> some View {
        HStack(alignment: .top) {
            Text(verbatim: value).font(.caption.monospaced()).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: value)]) }
            label: { Image(systemName: "folder") }
                .help("在访达中显示".localized)
                .accessibilityLabel("在访达中显示".localized)
                .buttonStyle(.borderless)
        }
    }

    private func confirmDataCancellation(_ transfer: DataTransferRecord, preserve: Bool) {
        confirm(title: preserve ? "结束尝试并保留材料".localized : "取消并清理暂存".localized,
            message: preserve ? "确认原数据仍有效后结束本次尝试，保留未确认的材料，并在副本管理中列出。".localized
                : "确认原数据仍有效后，删除本次可确认归属的暂存副本；原数据会保留。".localized,
            action: .cancelData(transfer, preserveMaterials: preserve))
    }

    private func confirm(title: String, message: String, action: CopyManagementModel.Action) {
        confirmation = WarningSheetRequest(title: title, intro: message, onCancel: {},
            actions: [WarningAction(title, style: .destructive) { model.start(action) }])
    }
}
