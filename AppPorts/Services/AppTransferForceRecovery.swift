import Foundation

/// Explicit user recovery: bypass content verification, retain every real copy.
/// The caller owns the application mutation coordinator and the operation lock.
struct AppTransferForceRecovery {
    let store: AppTransferStore

    func run(operationID: UUID, restore: Bool, progress: DataTransferProgress) async throws -> String {
        if !restore {
            let archive = try archiveIncomplete(operationID)
            return "已忽略错误，将原任务归档为未完成；已解除迁移记录占用，所有文件保持原样。".localized
                + "\n" + archive.path
        }

        let record = try store.record(operationID)
        let external = URL(fileURLWithPath: record.direction == .restore ? record.sourcePath : record.destinationPath).standardizedFileURL
        let local = URL(fileURLWithPath: record.direction == .restore ? record.destinationPath : record.sourcePath).standardizedFileURL
        let externalParent = record.direction == .restore ? record.sourceParentIdentity : record.destinationParentIdentity
        let localParent = record.direction == .restore ? record.destinationParentIdentity : record.sourceParentIdentity
        guard external.path != local.path,
              !local.path.hasPrefix(external.path + "/"),
              !external.path.hasPrefix(local.path + "/"),
              try DataPathIdentity.capture(external.deletingLastPathComponent()).matchesFilesystemObject(externalParent),
              try DataPathIdentity.capture(local.deletingLastPathComponent()).matchesFilesystemObject(localParent) else {
            throw AppTransferTransaction.failure("原磁盘或目录位置已改变，请连接迁移时使用的磁盘后重试。".localized, at: external)
        }
        guard try AppTransferStore.exists(external) else {
            throw AppTransferTransaction.failure("外置盘上的应用不存在，无法强制回迁。".localized, at: external)
        }
        let externalRunning = await MigrationApplicationState.isRunning(appURL: external, bundleIdentifier: CodeSigner.bundleIdentifier(at: external))
        let localRunning = await MigrationApplicationState.isRunning(appURL: local, bundleIdentifier: nil)
        if externalRunning || localRunning {
            throw AppTransferTransaction.failure("请先退出应用，再强制回迁。".localized, at: local)
        }

        let fm = FileManager.default
        let stage = local.deletingLastPathComponent().appendingPathComponent(".appports-force-restore-" + UUID().uuidString, isDirectory: true)
        let candidate = stage.appendingPathComponent(local.lastPathComponent)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        // A receipt survives a crash independently of the original cleanup journal.
        let receipt = ["operationID": operationID.uuidString, "externalPath": external.path,
                       "localPath": local.path, "state": "incomplete-unverified"]
        try DurableFileIO.write(try PropertyListEncoder().encode(receipt), to: stage.appendingPathComponent("recovery.plist"))
        progress.setDirectory(external)
        progress.begin(.copying, detail: "正在强制回迁，不进行内容校验；外置盘原文件会保留。".localized)
        do {
            _ = try await FileCopier().copyDirectory(from: external, to: candidate, progressHandler: { progress.update($0) })
            try MigrationExecution.checkpoint()
            // Recheck locations, not file contents, before replacing a local entry.
            guard try DataPathIdentity.capture(local.deletingLastPathComponent()).matchesFilesystemObject(localParent),
                  try DataPathIdentity.capture(external.deletingLastPathComponent()).matchesFilesystemObject(externalParent) else {
                throw AppTransferTransaction.failure("复制期间目录位置发生变化，已保留副本。".localized, at: stage)
            }
            let externalRunning = await MigrationApplicationState.isRunning(appURL: external, bundleIdentifier: CodeSigner.bundleIdentifier(at: external))
            let localRunning = await MigrationApplicationState.isRunning(appURL: local, bundleIdentifier: nil)
            if externalRunning || localRunning {
                throw AppTransferTransaction.failure("应用正在运行，已保留复制结果，请退出应用后重试。".localized, at: stage)
            }
            progress.begin(.switching, detail: "正在替换本地入口，并将原迁移记录归档为未完成。".localized)
            // Archive before switching: old automatic cleanup must never act on the new local copy.
            _ = try archiveIncomplete(operationID)
            if try AppTransferStore.exists(local) {
                try AppTransferTransaction.exchange(candidate, local)
                // Only remove a symlink. Existing real apps/portals stay in the recovery folder.
                if (try? fm.destinationOfSymbolicLink(atPath: candidate.path)) != nil {
                    try fm.removeItem(at: candidate)
                }
            } else {
                try AppTransferTransaction.moveExclusively(candidate, local)
            }
            try DurableFileIO.syncDirectory(at: local.deletingLastPathComponent())
            progress.begin(.cleaning, detail: "强制回迁已完成，正在更新应用入口记录。".localized)
            try AppSearchRecordStore.shared.markRestored(localURL: local, remainingExternal: true)
            return "强制回迁已完成，未进行内容校验。外置盘原文件已保留，原任务已归档为未完成。".localized
                + "\n" + "保留材料：".localized + stage.path
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppTransferTransaction.failure(error.localizedDescription + "\n" + "已保留复制材料：".localized + stage.path, at: local)
        }
    }

    private func archiveIncomplete(_ operationID: UUID) throws -> URL {
        // Archiving must also work when the original record cannot be decoded.
        guard let archive = try store.archive(operationID, incomplete: true) else {
            throw AppTransferTransaction.failure("未找到需要归档的迁移记录。".localized, at: store.directoryURL)
        }
        return archive
    }
}
