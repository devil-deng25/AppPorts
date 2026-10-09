import SwiftUI

/// A retained copy is ordinary success. Unfinished transactions expose their
/// recorded locations and offer a checked unlock when copying has not started.
struct DataTransferReviewView: View {
    let group: DataTransferGroup
    let onCleanup: () -> Void
    let onUnlock: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var confirmCleanup = false
    @State private var contentHeight: CGFloat = 320

    init(transfer: DataTransferRecord, onCleanup: @escaping () -> Void, onUnlock: (() -> Void)? = nil) {
        self.init(group: DataTransferGroup(transfer: transfer), onCleanup: onCleanup, onUnlock: onUnlock)
    }

    init(group: DataTransferGroup, onCleanup: @escaping () -> Void, onUnlock: (() -> Void)? = nil) {
        self.group = group
        self.onCleanup = onCleanup
        self.onUnlock = onUnlock
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("副本管理".localized).font(.title2.weight(.semibold))
            Text(verbatim: group.displayName)
                .font(.headline)
                .lineLimit(2)
            ScrollView {
                reviewContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 8)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: ReviewContentHeight.self, value: geometry.size.height)
                    })
            }
            .frame(height: min(contentHeight, maximumContentHeight))
            .onPreferenceChange(ReviewContentHeight.self) { contentHeight = $0 }
            HStack {
                Spacer()
                Button("关闭".localized) { dismiss() }.keyboardShortcut(.cancelAction)
                if group.canCleanup {
                    Button("校验并清理这些副本".localized, role: .destructive) { confirmCleanup = true }
                } else if group.unlockTransfer != nil, let onUnlock {
                    Button("检查并解除锁定".localized) { dismiss(); onUnlock() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 580)
        .confirmationDialog("校验并清理这些副本".localized, isPresented: $confirmCleanup, titleVisibility: .visible) {
            Button("校验并清理这些副本".localized, role: .destructive) { dismiss(); onCleanup() }
            Button("取消".localized, role: .cancel) { }
        } message: {
            Text("校验通过后清理所列历史副本，当前数据会保留。".localized)
        }
    }

    /// Keep the decision buttons visible even with long recovery paths or error text.
    private var maximumContentHeight: CGFloat {
        min(520, max(200, (NSScreen.main?.visibleFrame.height ?? 768) - 220))
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(group.statusTitle, systemImage: group.state == .needsAttention ? "exclamationmark.triangle" : "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(group.state == .needsAttention ? Color.orange : Color.green)
            Text(reviewDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            pathRow(title: group.state == .needsAttention ? "最后记录的数据位置".localized : "当前数据".localized,
                    path: group.activePath)
            ForEach(group.retainedCopies) { copy in
                if let path = copy.path {
                    pathRow(title: copy.title, path: path)
                } else if let uuid = copy.volumeUUID {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(copy.title).font(.subheadline.weight(.medium))
                        Text(verbatim: "APFS · " + uuid).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            if group.state == .needsAttention {
                ForEach(group.transfers.filter { ![.awaitingUserVerification, .cleanupRequested].contains($0.phase) || $0.recoverableReason != nil }) { transfer in
                    recoveryDetails(transfer)
                }
            }
        }
    }

    private var reviewDescription: String {
        if group.state != .needsAttention {
            return "数据已就位。以下是保留的历史副本，可以一起校验并清理。".localized
        }
        if group.unlockTransfer != nil {
            return "检查原目录与目标位置；确认尚未生成副本后解除锁定，即可重新迁移。".localized
        }
        return "操作尚需检查，所有已记录的副本都会保留。请先检查这些位置，不要合并或覆盖数据。".localized
    }

    private func recoveryDetails(_ transfer: DataTransferRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text((transfer.direction == .migrate ? "迁移".localized : "还原".localized) + " · " + "需要检查".localized)
                .font(.subheadline.weight(.medium))
            if let backup = transfer.backupPath { pathRow(title: "保留位置".localized, path: backup) }
            if let staging = transfer.stagingPath { pathRow(title: "暂存副本".localized, path: staging) }
            if ![transfer.activePath, transfer.backupPath, transfer.stagingPath].compactMap({ $0 })
                .contains(where: { URL(fileURLWithPath: $0).standardizedFileURL.path == URL(fileURLWithPath: transfer.destinationPath).standardizedFileURL.path }) {
                pathRow(title: "目标副本".localized, path: transfer.destinationPath)
            }
            if let uuid = transfer.createdVolumeUUID ?? transfer.sourceIdentity.volumeUUID {
                Text(verbatim: "Volume UUID: " + uuid).font(.caption.monospaced()).textSelection(.enabled)
            }
            if let reason = transfer.recoverableReason {
                Text(verbatim: reason).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pathRow(title: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.medium))
            HStack(alignment: .top) {
                Text(verbatim: path).font(.caption.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Image(systemName: "folder")
                }
                .help("在访达中显示".localized)
                .accessibilityLabel("在访达中显示".localized)
                .fixedSize()
            }
        }
    }
}

private struct ReviewContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
