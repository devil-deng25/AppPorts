import SwiftUI

/// App-data visibility only; execution policy and tool-directory controls remain independent.
struct AppDataVisibilityControls: View {
    @Binding var showZeroByteDirectories: Bool
    @Binding var showLockedStructure: Bool
    @Binding var showNonMigratableDirectories: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            zeroByteDirectoriesToggle
            lockedStructureToggle
            Toggle("显示不支持迁移目录".localized, isOn: $showNonMigratableDirectories)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var zeroByteDirectoriesToggle: some View {
        Toggle("显示零字节目录".localized, isOn: $showZeroByteDirectories)
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .fixedSize()
    }

    private var lockedStructureToggle: some View {
        Toggle("显示锁定目录结构".localized, isOn: $showLockedStructure)
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .fixedSize()
    }
}
