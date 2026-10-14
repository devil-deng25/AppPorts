import SwiftUI

/// The timeline refreshes only this small surface, including during worker
/// syscalls that cannot report a percentage. It never advances work counters.
struct DataDirProgressOverlay: View {
    let title: String
    let progress: DataTransferProgress

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            DataDirProgressContent(title: title, snapshot: progress.snapshot())
        }
    }
}

struct DataDirProgressContent: View {
    let title: String
    let snapshot: DataTransferProgress.Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: title)
                .font(.headline)
                .lineLimit(3)
                .truncationMode(.middle)
                .help(title)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    Text(verbatim: snapshot.stage.title)
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if let fraction = snapshot.fraction {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.system(size: 13, weight: .medium))
                            .monospacedDigit()
                    }
                }

                if let fraction = snapshot.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .accessibilityLabel(snapshot.stage.title)
                }

                Text(verbatim: snapshot.detail.isEmpty ? snapshot.stage.explanation : snapshot.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            statistics

            if !snapshot.currentFile.isEmpty {
                Text(verbatim: snapshot.currentFile)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(snapshot.currentFile)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Text(String(format: "已用时 %@".localized, duration(snapshot.elapsed)))
                Spacer(minLength: 8)
                Text(String(format: "此阶段 %@".localized, duration(snapshot.stageElapsed)))
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .monospacedDigit()

            if snapshot.isWaitingForActivity {
                Text(String(format: "已 %@ 未收到新的文件进度，正在等待当前步骤返回。".localized, duration(snapshot.activityAge)))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 8)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var statistics: some View {
        if snapshot.stage == .copying {
            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.totalBytes > 0
                    ? String(format: "已复制 %@ / %@".localized, bytes(snapshot.copiedBytes), bytes(snapshot.totalBytes))
                    : String(format: "已复制 %@".localized, bytes(snapshot.copiedBytes)))
                Spacer(minLength: 8)
                if let rate = snapshot.visibleCopyRate, rate > 0 {
                    Text(String(format: "%@/秒".localized, bytes(Int64(min(rate, Double(Int64.max / 2))))))
                }
            }
            .font(.system(size: 12))
            .monospacedDigit()
        } else if snapshot.completedItems > 0 || snapshot.readBytes > 0 {
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "本轮已处理 %lld 项".localized, Int64(snapshot.completedItems)))
                Spacer(minLength: 8)
                if snapshot.readBytes > 0 {
                    Text(String(format: "已读取 %@".localized, bytes(snapshot.readBytes)))
                }
            }
            .font(.system(size: 12))
            .monospacedDigit()
        }
    }

    private func bytes(_ value: Int64) -> String {
        LocalizedByteCountFormatter.string(fromByteCount: value)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let value = Int(max(0, seconds))
        if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
