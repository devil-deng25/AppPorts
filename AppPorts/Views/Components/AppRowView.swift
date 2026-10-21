//
//  AppRowView.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/2/6.
//

import SwiftUI
import AppKit

/// 列表行视图
struct AppRowView: View {
    let app: AppItem
    let isSelected: Bool
    let showDeleteLinkButton: Bool
    let showMoveBackButton: Bool
    let onDeleteLink: (AppItem) -> Void
    let onMoveBack: (AppItem) -> Void
    let onResign: ((AppItem) -> Void)?
    let onRestoreSignature: ((AppItem) -> Void)?
    var onMoveOutWholeSymlink: ((AppItem) -> Void)? = nil
    var onRepairDock: ((AppItem) -> Void)? = nil
    /// 签名被替换的应用：打开修复面板
    var onRepairSignature: ((AppItem) -> Void)? = nil
    
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 14) {
            AppIconView(url: app.displayURL)
            
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(app.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(app.size ?? "计算中...".localized)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                        .fixedSize()
                }
                StatusBadge(app: app, onRepairSignature: onRepairSignature)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Text(app.displayName) + Text(", ") +
                Text(AppStatus.localized(app.status)) +
                (app.size.map { Text(", \($0)") } ?? Text(verbatim: ""))
            )
            
            rowActions
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.07) : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .background(AppListSelectionAppearance())
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        // 保留行内按钮，VoiceOver 可以分别选择应用信息和操作。
        .accessibilityElement(children: .contain)
        .contextMenu {
            Button("在 Finder 中显示".localized) {
                NSWorkspace.shared.activateFileViewerSelecting([app.path])
            }

            if app.status == AppStatus.linked || app.status == AppStatus.partialLinked,
               let onRepairDock {
                Divider()
                Button("修复 Dock 图标".localized) {
                    onRepairDock(app)
                }
            }

            if (app.status == AppStatus.local || app.status == AppStatus.pendingMoveOut) && !app.isSystemApp, let onMoveOutWholeSymlink {
                Divider()
                Button("使用传统链接迁移".localized) {
                    onMoveOutWholeSymlink(app)
                }
            }

            if app.status == AppStatus.orphanedLink {
                Divider()
                Button("删除孤立链接".localized) {
                    onDeleteLink(app)
                }
            }

            if app.needsSignatureAttention, let onRepairSignature {
                Divider()
                Button(signatureActionTitle) {
                    onRepairSignature(app)
                }
            }

            // A confirmed re-signed installation offers restoration. Unknown
            // history still permits a fresh service inspection before signing.
            if !app.isResigned,
               !app.isFolder,
               !app.isSystemApp,
               app.status != AppStatus.orphanedLink,
               app.displayURL.pathExtension.lowercased() == "app",
               let onResign {
                Divider()
                Button("重签名此应用".localized) {
                    onResign(app)
                }
                .disabled(app.isRunning)
            }

            if let onRestoreSignature, app.isResigned || app.signatureCheckUnavailable {
                Divider()
                Button("恢复原始签名".localized) {
                    onRestoreSignature(app)
                }
            }
        }
    }

    private var signatureActionTitle: String {
        app.signatureCheckUnavailable ? "检查签名".localized : "查看修复步骤".localized
    }

    private var rowActions: some View {
        HStack(spacing: 8) {
            if app.needsSignatureAttention, let onRepairSignature {
                Button(action: { onRepairSignature(app) }) {
                    Label(app.signatureCheckUnavailable ? "检查签名".localized : "修复".localized,
                          systemImage: app.signatureCheckUnavailable ? "arrow.clockwise" : "wrench.and.screwdriver")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12)))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(signatureActionTitle)
                .help(signatureActionTitle)
            }

            if showMoveBackButton {
                Button(action: { onMoveBack(app) }) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 13))
                        .foregroundColor(.blue)
                        .frame(width: 28, height: 28)
                        .background(Color.blue.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("将应用迁移回本地".localized)
                .help("将应用迁移回本地".localized)
            }

            // 固定末列宽度，其他操作和标签数量不会改变删除按钮的位置。
            if showDeleteLinkButton {
                Group {
                    if app.status == AppStatus.linked || app.status == AppStatus.orphanedLink {
                        Button(action: { onDeleteLink(app) }) {
                            Image(systemName: "trash")
                                .font(.system(size: 13))
                                .foregroundColor(.red)
                                .frame(width: 28, height: 28)
                                .background(Color.red.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("断开此链接并删除文件".localized)
                        .help("断开此链接并删除文件".localized)
                    } else {
                        Color.clear
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: 28, height: 28)
            }
        }
        .frame(height: 28)
    }

}

/// Keep native List keyboard and multiple selection behavior while drawing selection in AppRowView.
private struct AppListSelectionAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> SelectionView { SelectionView() }

    func updateNSView(_ nsView: SelectionView, context: Context) {
        nsView.updateSelectionAppearance()
    }

    final class SelectionView: NSView {
        private weak var configuredTable: NSTableView?
        private var updateScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { configuredTable = nil }
            updateSelectionAppearance()
        }

        func updateSelectionAppearance() {
            guard window != nil, configuredTable == nil, !updateScheduled else { return }
            updateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updateScheduled = false
                var ancestor = self.superview
                while let view = ancestor {
                    if let table = view as? NSTableView {
                        self.configuredTable = table
                        if table.selectionHighlightStyle != .none {
                            table.selectionHighlightStyle = .none
                        }
                        return
                    }
                    ancestor = view.superview
                }
            }
        }
    }
}
