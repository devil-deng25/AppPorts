import Darwin
import Foundation

/// Low-level data-tree operations retain originals; complete user flows clean
/// their verified copies after the successful switch has been committed.
/// UI flags never authorize execution; every entry point evaluates real paths and durable topology.
actor DataDirMover {
    struct CompletionResult: Sendable {
        /// The data switch succeeded. A warning refers only to retained-copy cleanup.
        let cleanupWarning: String?
    }

    enum CompletionError: LocalizedError {
        case previousRestoreNeedsCleanup(String)

        var errorDescription: String? {
            switch self {
            case .previousRestoreNeedsCleanup(let details):
                return String(format: "上次还原的旧副本尚未清理，新的迁移尚未开始。请先在副本管理中校验并清理后重试。%@".localized, "\n" + details)
            }
        }
    }

    private let fileManager = FileManager.default
    private let homeDir: URL
    private let store: ContainerMountStore
    private let safety: DataOperationSafety
    private let failSymlinkCreation: Bool
    private var runningMigrations: Set<UUID> = []
    private var runningRestores: Set<UUID> = []
    private var runningCleanups: Set<UUID> = []
    private var completingPaths: Set<String> = []
    private let managedLinkMarkerFileName = ".appports-link-metadata.plist"
    private let managedLinkMetadataSidecarSuffix = ".appports-link-metadata.plist"
    private let managedLinkIdentifier = "com.shimoko.AppPorts"
    private let managedLinkSchemaVersion = 1

    private struct ManagedLinkMetadata: Codable, Sendable {
        let schemaVersion: Int
        let managedBy: String
        let sourcePath: String
        let destinationPath: String
        let dataDirType: String
    }

    init(homeDir: URL = URL(fileURLWithPath: NSHomeDirectory()),
         failSymlinkCreation: Bool = false, failSourceBackupCleanup: Bool = false,
         store: ContainerMountStore = .shared, runner: any ShellCommandRunning = ProcessCommandRunner()) {
        self.homeDir = homeDir.standardizedFileURL
        self.store = store
        self.safety = DataOperationSafety(homeDirectory: homeDir, store: store, runner: runner)
        self.failSymlinkCreation = failSymlinkCreation
        // Kept source-compatible with older callers. Success now always retains the original.
        _ = failSourceBackupCleanup
    }

    /// Complete the ordinary user flow while keeping cleanup failures separate
    /// from a successful data switch. The caller holds the shared operation lock.
    func migrateAndComplete(item: DataDirItem, to externalBaseURL: URL,
                            progressHandler: FileCopier.ProgressHandler?) async throws -> CompletionResult {
        let path = item.path.standardizedFileURL.path
        guard completingPaths.insert(path).inserted else { throw DataOperationSafety.Failure.occupied(path) }
        defer { completingPaths.remove(path) }
        try await completePreviousRestoreIfNeeded(item: item, externalBaseURL: externalBaseURL, progressHandler: progressHandler)
        let operationID = try await migrateRetainingOriginal(item: item, to: externalBaseURL, progressHandler: progressHandler)
        return await completeSuccessfulTransfer(operationID: operationID, direction: .migrate, progressHandler: progressHandler)
    }

    func restoreAndComplete(item: DataDirItem,
                            progressHandler: FileCopier.ProgressHandler?) async throws -> CompletionResult {
        try await completeInterruptedMigrationBeforeRestore(at: item.path, progressHandler: progressHandler)
        let path = item.path.standardizedFileURL.path
        guard completingPaths.insert(path).inserted else { throw DataOperationSafety.Failure.occupied(path) }
        defer { completingPaths.remove(path) }
        let alreadyRestored = !isSymbolicLink(at: item.path)
        let operationID = try await restoreRetainingOriginal(item: item, progressHandler: progressHandler)
        return await completeSuccessfulTransfer(operationID: operationID, direction: .restore,
            progressHandler: progressHandler, requireUnchangedActive: !alreadyRestored)
    }

    /// Low-level recovery callers may deliberately retain the verified original.
    func migrate(item: DataDirItem, to externalBaseURL: URL, progressHandler: FileCopier.ProgressHandler?) async throws {
        _ = try await migrateRetainingOriginal(item: item, to: externalBaseURL, progressHandler: progressHandler)
    }

    private func migrateRetainingOriginal(item: DataDirItem, to externalBaseURL: URL,
                                          progressHandler: FileCopier.ProgressHandler?) async throws -> UUID {
        let source = item.path.standardizedFileURL
        let destination = externalBaseURL.appendingPathComponent(source.lastPathComponent).standardizedFileURL
        try requirePolicy(source)
        guard !isSymbolicLink(at: source) else { throw DataDirError.destinationExists(source) }
        guard !DiskUtility.isMountPoint(source) else { throw DataOperationSafety.Failure.conflict(source.path) }
        guard try !entryExists(destination) else { throw DataDirError.destinationExists(destination) }
        try requireMarker(at: source, for: source, type: item.type, allowOwned: false)
        try await safety.requireNewMigration(at: source, destination: destination, bundleIdentifier: item.associatedBundleIdentifier)
        // Reject known permission failures before reserving a recovery record.
        // Directory creation still happens only after the durable intent below.
        let destinationVolumeUUID = try preflightWritePermission(at: externalBaseURL)
        let id = UUID()
        let backup = source.deletingLastPathComponent().appendingPathComponent(".appports-migration-backup-\(source.lastPathComponent)-\(id)")
        var transfer = DataTransferRecord(operationID: id, mode: .symlink, direction: .migrate, sourceID: item.id,
            appName: item.associatedAppName ?? item.name, bundleIdentifier: item.associatedBundleIdentifier,
            dataDirType: item.type.rawValue, originalPath: source.path, activePath: source.path,
            destinationPath: destination.path, backupPath: backup.path,
            sourceIdentity: try DataPathIdentity.capture(source), destinationVolumeUUID: destinationVolumeUUID)
        try store.beginTransfer(transfer)
        runningMigrations.insert(id)
        defer { runningMigrations.remove(id) }
        do {
            try checkWritePermission(at: externalBaseURL)
            if let destinationVolumeUUID {
                try requireDestinationVolume(at: externalBaseURL, expected: destinationVolumeUUID)
            }
            transfer.phase = .copying
            try store.updateTransfer(transfer)
            let baseline = try await copy(from: source, to: destination, final: destination, progress: progressHandler)
            try requireMarker(at: source, for: source, type: item.type, allowOwned: false)
            try installMarker(source: source, destination: destination, type: item.type, baseline: baseline)
            transfer.destinationIdentity = try DataPathIdentity.capture(destination)
            transfer.baseline = try PropertyListEncoder().encode(baseline)
            transfer.phase = .verified
            try store.updateTransfer(transfer)
            await progressHandler?(.init(copiedBytes: baseline.logicalBytes, totalBytes: baseline.logicalBytes, currentFile: "正在切换本地入口...".localized))
            try await safety.requireNoKnownWriters(at: source, bundleIdentifier: item.associatedBundleIdentifier)
            try requireIdentity(source, transfer.sourceIdentity)
            try requireMarker(at: source, for: source, type: item.type, allowOwned: false)
            try TreeCopySession.verifyUnchanged(at: source, against: baseline)
            try TreeCopySession.verifyCopy(at: destination, against: baseline)
            transfer.phase = .switching
            try store.updateTransfer(transfer)
            try DataTreeRelocator.move(source, to: backup)
            transfer.backupIdentity = try DataPathIdentity.capture(backup)
            try requireIdentity(backup, transfer.sourceIdentity)
            try store.updateTransfer(transfer)
            await progressHandler?(.init(copiedBytes: baseline.logicalBytes, totalBytes: baseline.logicalBytes, currentFile: "正在创建符号链接...".localized))
            try requireMarker(at: backup, for: source, type: item.type, allowOwned: false)
            try TreeCopySession.verifyUnchanged(at: backup, against: baseline)
            do { try createSymbolicLink(at: source, withDestinationURL: destination) }
            catch {
                // The backup is still complete; never overwrite a competing entry during rollback.
                if try !entryExists(source) { try DataTreeRelocator.move(backup, to: source) }
                throw DataDirError.symlinkFailed(error)
            }
            transfer.activePath = destination.path
            try requireMarker(at: backup, for: source, type: item.type, allowOwned: false)
            try TreeCopySession.verifyUnchanged(at: backup, against: baseline)
            try TreeCopySession.verifyCopy(at: destination, against: baseline)
            try store.commitMigration(record: nil, transfer: transfer)
            invalidateSizeCache(for: source)
            invalidateSizeCache(for: destination)
            return id
        } catch {
            // A copier preflight can fail before it creates anything. Retrying
            // such an operation needs no recovery once absence is proven.
            if removeUnstartedIntentIfSafe(transfer) { throw error }
            try recordFailure(&transfer, error: error)
        }
    }

    func restore(item: DataDirItem, progressHandler: FileCopier.ProgressHandler?) async throws {
        try await completeInterruptedMigrationBeforeRestore(at: item.path, progressHandler: progressHandler)
        _ = try await restoreRetainingOriginal(item: item, progressHandler: progressHandler)
    }

    private func completeInterruptedMigrationBeforeRestore(at local: URL, progressHandler: FileCopier.ProgressHandler?) async throws {
        let transfers = try store.transfers()
        let pending = transfers.filter { $0.mode == .symlink && $0.direction == .migrate && $0.originalPath == local.standardizedFileURL.path
            && $0.isVerifiedSwitchRecoverable }
        for transfer in pending {
            guard !transfers.contains(where: { $0.priorOperationID == transfer.operationID }) else { continue }
            _ = try await resumeVerifiedTransfer(operationID: transfer.operationID, progressHandler: progressHandler)
        }
    }

    private func restoreRetainingOriginal(item: DataDirItem,
                                          progressHandler: FileCopier.ProgressHandler?) async throws -> UUID {
        let local = item.path.standardizedFileURL
        try finishUnstartedRestoreIfNeeded(at: local)
        let indexed = try store.managedLink(forOriginalPath: local.path)
        let existingTransfers = try store.transfers()
        if !isSymbolicLink(at: local), indexed == nil,
           let completed = existingTransfers.last(where: { $0.direction == .restore && $0.originalPath == local.path && [.awaitingUserVerification, .cleanupRequested].contains($0.phase) }),
           let identity = completed.destinationIdentity, let current = try? DataPathIdentity.capture(local), identity.matchesFilesystemObject(current) { return completed.operationID }
        let linkIdentity: DataPathIdentity?
        let external: URL
        if isSymbolicLink(at: local) {
            linkIdentity = try DataPathIdentity.capture(local)
            external = local.resolvingSymlinksInPath()
        } else if let indexed, try !entryExists(local) {
            linkIdentity = nil
            external = URL(fileURLWithPath: indexed.destinationPath)
        } else { throw DataDirError.notASymlink(local) }
        guard fileManager.fileExists(atPath: external.path), !isSymbolicLink(at: external) else { throw DataDirError.externalNotFound(external) }
        let sourceIdentity = try DataPathIdentity.capture(external)
        if let indexed {
            guard DataPathTopology.relationship(indexed.destinationPath, external.path) == .same,
                  indexed.destinationIdentity.matchesFilesystemObject(sourceIdentity) else { throw DataOperationSafety.Failure.conflict(external.path) }
        }
        try requireMarker(at: external, for: local, type: item.type, allowOwned: true)
        let prior = indexed?.operationID ?? existingTransfers.last(where: {
            $0.direction == .migrate && $0.originalPath == local.path && $0.destinationIdentity?.matchesFilesystemObject(sourceIdentity) == true
        })?.operationID
        let ownedIDs = prior.map { transferAncestors(of: $0, transfers: existingTransfers) } ?? []
        try safety.requireNoOverlap(at: local, ownedTransferIDs: ownedIDs, ownedLinkPath: indexed?.originalPath)
        try safety.requireNoOverlap(at: external, ownedTransferIDs: ownedIDs, ownedLinkPath: indexed?.originalPath)
        try requireLocalRestoreParent(local)
        try await safety.requireNoKnownWriters(at: external, bundleIdentifier: item.associatedBundleIdentifier ?? indexed?.bundleIdentifier)
        let id = UUID()
        let staging = local.deletingLastPathComponent().appendingPathComponent(".appports-restore-\(id)")
        let copyURL = staging.appendingPathComponent("data")
        var transfer = DataTransferRecord(operationID: id, mode: .symlink, direction: .restore, sourceID: item.id,
            appName: item.associatedAppName ?? item.name, bundleIdentifier: item.associatedBundleIdentifier ?? indexed?.bundleIdentifier,
            dataDirType: item.type.rawValue, originalPath: local.path, activePath: external.path, destinationPath: local.path,
            backupPath: external.path, stagingPath: staging.path, sourceIdentity: sourceIdentity,
            backupIdentity: sourceIdentity, priorOperationID: prior)
        try store.beginTransfer(transfer)
        runningRestores.insert(id)
        defer { runningRestores.remove(id) }
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            transfer.phase = .copying
            try store.updateTransfer(transfer)
            let baseline = try await copy(from: external, to: copyURL, final: local, progress: progressHandler)
            transfer.destinationIdentity = try DataPathIdentity.capture(copyURL)
            transfer.baseline = try PropertyListEncoder().encode(baseline)
            transfer.phase = .verified
            try store.updateTransfer(transfer)
            try await safety.requireNoKnownWriters(at: external, bundleIdentifier: transfer.bundleIdentifier)
            try requireIdentity(external, sourceIdentity)
            try requireMarker(at: external, for: local, type: item.type, allowOwned: true)
            try TreeCopySession.verifyUnchanged(at: external, against: baseline)
            try TreeCopySession.verifyCopy(at: copyURL, against: baseline)
            try requireLocalRestoreParent(local)
            try store.beginRestore(transfer: transfer, removingMount: nil)
            transfer.phase = .switching
            try requireIdentity(copyURL, transfer.destinationIdentity!)
            try switchEntry(local: local, expectedLink: linkIdentity, replacement: copyURL, staging: staging)
            try TreeCopySession.applyRootMetadata(at: local, from: baseline, ownershipRole: .destination)
            transfer.activePath = local.path
            try TreeCopySession.verifyUnchanged(at: external, against: baseline)
            try TreeCopySession.verifyCopy(at: local, against: baseline)
            try store.updateTransfer(transfer)
            try store.finalizeTransfer(operationID: id, baseline: transfer.baseline!)
            invalidateSizeCache(for: local)
            invalidateSizeCache(for: external)
            return id
        } catch {
            if removeUnstartedRestoreIntentIfSafe(transfer) { throw error }
            try recordFailure(&transfer, error: error)
        }
    }

    /// Attach existing data without replacing a different entry. The source index is durable intent.
    func createLink(localPath: URL, externalPath: URL, bundleIdentifier: String? = nil, appName: String? = nil) async throws {
        let local = localPath.standardizedFileURL
        let external = externalPath.standardizedFileURL
        try requirePolicy(local)
        guard existingDirectory(at: external), !isSymbolicLink(at: external) else { throw DataDirError.externalNotFound(external) }
        let old = try store.managedLink(forOriginalPath: local.path)
        let externalIdentity = try DataPathIdentity.capture(external)
        if let old {
            guard old.destinationIdentity.matchesFilesystemObject(externalIdentity),
                  DataPathTopology.relationship(old.destinationPath, external.path) == .same else { throw DataOperationSafety.Failure.conflict(local.path) }
            if isSymbolicLink(at: local), DataPathTopology.relationship(local.path, external.path) == .same { return }
        }
        let adoptedEntry: DataPathIdentity?
        if isSymbolicLink(at: local), DataPathTopology.relationship(local.path, external.path) == .same {
            adoptedEntry = try DataPathIdentity.capture(local)
        } else {
            guard try !entryExists(local) else { throw DataDirError.destinationExists(local) }
            adoptedEntry = nil
        }
        let type = try managedType(for: local, external: external, indexedType: old?.dataDirType)
        try requireMarker(at: external, for: local, type: type, allowOwned: true)
        let history = try store.transfers()
        let owned = old.map { transferAncestors(of: $0.operationID, transfers: history) } ?? []
        try safety.requireNoOverlap(at: local, ownedTransferIDs: owned, ownedLinkPath: old?.originalPath)
        try safety.requireNoOverlap(at: external, ownedTransferIDs: owned, ownedLinkPath: old?.originalPath)
        try safety.requireNoManagedFileSystemAncestor(at: local)
        if adoptedEntry == nil && DataPathTopology.overlaps(DataPathTopology.relationship(local.path, external.path)) {
            throw DataOperationSafety.Failure.conflict(local.path)
        }
        try safety.requireNoManagedDescendants(at: external)
        try await safety.requireNoKnownWriters(at: external, bundleIdentifier: bundleIdentifier ?? old?.bundleIdentifier)
        let baseline = try TreeCopySession.snapshot(at: external, excludingRootEntries: [managedLinkMarkerFileName])
        let index = old ?? ManagedDataLinkRecord(operationID: UUID(), originalPath: local.path, destinationPath: external.path,
            destinationIdentity: externalIdentity, appName: appName ?? local.lastPathComponent, bundleIdentifier: bundleIdentifier ?? inferredBundleIdentifier(local), dataDirType: type.rawValue)
        try store.upsertManagedLink(index)
        try fileManager.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try installMarker(source: local, destination: external, type: type, baseline: baseline, ownershipRole: .source)
        try TreeCopySession.verifyUnchanged(at: external, against: baseline)
        if let adoptedEntry {
            try requireIdentity(local, adoptedEntry)
            guard DataPathTopology.relationship(local.path, external.path) == .same else { throw DataOperationSafety.Failure.conflict(local.path) }
            return
        }
        do { try createSymbolicLink(at: local, withDestinationURL: external) }
        catch { throw DataDirError.symlinkFailed(error) }
    }

    /// Disconnecting an entry keeps its index so the now-missing original remains recoverable.
    func deleteLink(localPath: URL) async throws {
        guard isSymbolicLink(at: localPath) else { throw DataDirError.notASymlink(localPath) }
        let identity = try DataPathIdentity.capture(localPath)
        let indexed = try store.managedLink(forOriginalPath: localPath.path)
        let history = try store.transfers()
        let owned = indexed.map { transferAncestors(of: $0.operationID, transfers: history) } ?? []
        try safety.requireNoOverlap(at: localPath, ownedTransferIDs: owned, ownedLinkPath: indexed?.originalPath)
        try safety.requireNoManagedFileSystemAncestor(at: localPath)
        let target = localPath.resolvingSymlinksInPath()
        try await safety.requireNoKnownWriters(at: target)
        try requireIdentity(localPath, identity)
        try fileManager.removeItem(at: localPath)
    }

    func normalizeManagedLinkAndComplete(localPath: URL, currentExternalPath: URL, normalizedExternalPath: URL,
                                         progressHandler: FileCopier.ProgressHandler? = nil) async throws -> CompletionResult {
        let path = localPath.standardizedFileURL.path
        guard completingPaths.insert(path).inserted else { throw DataOperationSafety.Failure.occupied(path) }
        defer { completingPaths.remove(path) }
        guard let operationID = try await normalizeRetainingOriginal(localPath: localPath,
            currentExternalPath: currentExternalPath, normalizedExternalPath: normalizedExternalPath,
            progressHandler: progressHandler) else { return CompletionResult(cleanupWarning: nil) }
        return await completeSuccessfulTransfer(operationID: operationID, direction: .migrate, progressHandler: progressHandler)
    }

    func normalizeManagedLink(localPath: URL, currentExternalPath: URL, normalizedExternalPath: URL) async throws {
        _ = try await normalizeRetainingOriginal(localPath: localPath, currentExternalPath: currentExternalPath,
                                                 normalizedExternalPath: normalizedExternalPath, progressHandler: nil)
    }

    private func normalizeRetainingOriginal(localPath: URL, currentExternalPath: URL, normalizedExternalPath: URL,
                                            progressHandler: FileCopier.ProgressHandler?) async throws -> UUID? {
        let local = localPath.standardizedFileURL
        let source = currentExternalPath.standardizedFileURL
        let destination = normalizedExternalPath.standardizedFileURL
        try requirePolicy(local)
        guard existingDirectory(at: source), !isSymbolicLink(at: source) else { throw DataDirError.externalNotFound(source) }
        guard isSymbolicLink(at: local), DataPathTopology.relationship(local.path, source.path) == .same else { throw DataDirError.invalidSymlink(local) }
        if DataPathTopology.relationship(source.path, destination.path) == .same { return nil }
        guard try !entryExists(destination) else { throw DataDirError.destinationExists(destination) }
        let old = try store.managedLink(forOriginalPath: local.path)
        let type = try managedType(for: local, external: source, indexedType: old?.dataDirType)
        try requireMarker(at: source, for: local, type: type, allowOwned: true)
        let sourceIdentity = try DataPathIdentity.capture(source)
        if let old { try requireIdentity(source, old.destinationIdentity) }
        let history = try store.transfers()
        let owned = old.map { transferAncestors(of: $0.operationID, transfers: history) } ?? []
        try safety.requireNoOverlap(at: local, ownedTransferIDs: owned, ownedLinkPath: old?.originalPath)
        try safety.requireNoOverlap(at: source, ownedTransferIDs: owned, ownedLinkPath: old?.originalPath)
        try safety.requireNoOverlap(at: destination)
        try safety.requireNoManagedFileSystemAncestor(at: local)
        try safety.requireNoManagedDescendants(at: source)
        try await safety.requireNoKnownWriters(at: source, bundleIdentifier: old?.bundleIdentifier)
        try requireIdentity(source, sourceIdentity)
        let id = UUID()
        let staging = local.deletingLastPathComponent().appendingPathComponent(".appports-normalize-\(id)")
        let linkIdentity = try DataPathIdentity.capture(local)
        var transfer = DataTransferRecord(operationID: id, mode: .symlink, direction: .migrate, sourceID: local.path,
            appName: old?.appName ?? local.lastPathComponent, bundleIdentifier: old?.bundleIdentifier ?? inferredBundleIdentifier(local),
            dataDirType: type.rawValue, originalPath: local.path, activePath: source.path, destinationPath: destination.path,
            backupPath: source.path, stagingPath: staging.path, sourceIdentity: sourceIdentity, backupIdentity: sourceIdentity,
            priorOperationID: old?.operationID)
        try store.beginTransfer(transfer)
        do {
            try checkWritePermission(at: destination.deletingLastPathComponent())
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            transfer.phase = .copying
            try store.updateTransfer(transfer)
            let baseline = try await copy(from: source, to: destination, final: destination, progress: progressHandler)
            try installMarker(source: local, destination: destination, type: type, baseline: baseline)
            transfer.destinationIdentity = try DataPathIdentity.capture(destination)
            transfer.baseline = try PropertyListEncoder().encode(baseline)
            transfer.phase = .verified
            try store.updateTransfer(transfer)
            try await safety.requireNoKnownWriters(at: source, bundleIdentifier: transfer.bundleIdentifier)
            try requireIdentity(source, sourceIdentity)
            try TreeCopySession.verifyUnchanged(at: source, against: baseline)
            let newLink = staging.appendingPathComponent("new-link")
            try createSymbolicLink(at: newLink, withDestinationURL: destination)
            transfer.phase = .switching
            try store.updateTransfer(transfer)
            try switchEntry(local: local, expectedLink: linkIdentity, replacement: newLink, staging: staging)
            transfer.activePath = destination.path
            try requireIdentity(source, sourceIdentity)
            try TreeCopySession.verifyUnchanged(at: source, against: baseline)
            try TreeCopySession.verifyCopy(at: destination, against: baseline)
            try store.commitMigration(record: nil, transfer: transfer)
            invalidateSizeCache(for: source)
            invalidateSizeCache(for: destination)
            return id
        } catch { try recordFailure(&transfer, error: error) }
    }

    /// Release a failed initial migration without deleting or moving any files.
    /// The caller holds the same outer operation lock used by migration itself.
    func cancelUnstartedMigration(operationID: UUID) async throws {
        guard !runningMigrations.contains(operationID) else {
            throw DataOperationSafety.Failure.occupied(operationID.uuidString)
        }
        guard let expected = try store.transfer(operationID: operationID) else {
            throw ContainerMountStore.StoreError.missingTransfer(operationID)
        }
        try store.cancelUnstartedMigration(expected) {
            try requireUnstartedMigrationFilesystem(expected)
        }
    }

    func cancelUnstartedRestore(operationID: UUID) async throws {
        guard !runningRestores.contains(operationID) else { throw DataOperationSafety.Failure.occupied(operationID.uuidString) }
        guard let expected = try store.transfer(operationID: operationID) else {
            throw ContainerMountStore.StoreError.missingTransfer(operationID)
        }
        try cancelUnstartedRestore(expected)
    }

    /// Continue a copy that was already verified before a switch or ledger write
    /// failed. Reuse its operation ID; never create a second copy or reservation.
    func resumeVerifiedTransfer(operationID: UUID, progressHandler: FileCopier.ProgressHandler?) async throws -> String? {
        guard var transfer = try store.transfer(operationID: operationID) else { return nil }
        guard transfer.mode == .symlink,
              !runningMigrations.contains(operationID), !runningRestores.contains(operationID),
              completingPaths.insert(transfer.originalPath).inserted else {
            throw DataOperationSafety.Failure.occupied(transfer.originalPath)
        }
        defer { completingPaths.remove(transfer.originalPath) }
        if transfer.isDataSwitchComplete {
            return await completeSuccessfulTransfer(operationID: operationID, direction: transfer.direction,
                progressHandler: progressHandler, requireUnchangedActive: false).cleanupWarning
        }
        guard transfer.isVerifiedSwitchRecoverable, let encoded = transfer.baseline else {
            throw DataOperationSafety.Failure.inspection(transfer.originalPath)
        }
        let baseline = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: encoded)
        if try store.transfers().contains(where: { $0.priorOperationID == operationID }) {
            return try await finishRestoredPredecessor(transfer, baseline: baseline, progressHandler: progressHandler)
        }
        let local = URL(fileURLWithPath: transfer.originalPath)
        let backup = URL(fileURLWithPath: transfer.backupPath!)
        var lastSaved = transfer
        do {
            await progressHandler?(.init(copiedBytes: 0, totalBytes: 0, currentFile: "重试".localized, showsByteProgress: false))
            let before = try verifiedSwitchState(transfer, baseline: baseline)
            if transfer.direction != .restore || !before.alreadySwitched {
                try await safety.requireNoKnownWriters(at: before.source, bundleIdentifier: transfer.bundleIdentifier)
            }
            try await safety.requireNoKnownWriters(at: before.destination, bundleIdentifier: transfer.bundleIdentifier)
            guard try store.transfer(operationID: operationID) == transfer,
                  try verifiedSwitchState(transfer, baseline: baseline) == before else {
                throw DataOperationSafety.Failure.conflict(local.path)
            }
            transfer.phase = .switching
            transfer.recoverableReason = nil
            if transfer.direction == .restore { try store.beginRestore(transfer: transfer, removingMount: nil) }
            else { try store.updateTransfer(transfer) }
            lastSaved = transfer
            guard try verifiedSwitchState(transfer, baseline: baseline) == before else {
                throw DataOperationSafety.Failure.conflict(local.path)
            }

            if transfer.direction == .migrate, transfer.stagingPath == nil {
                if before.source == local {
                    try DataTreeRelocator.move(local, to: backup)
                }
                try requireIdentity(backup, transfer.sourceIdentity)
                transfer.backupIdentity = try transfer.backupIdentity ?? DataPathIdentity.capture(backup)
                try store.updateTransfer(transfer)
                lastSaved = transfer
                _ = try verifiedSwitchState(transfer, baseline: baseline)
                if !isSymbolicLink(at: local) {
                    guard try !entryExists(local) else { throw DataDirError.destinationExists(local) }
                    try createSymbolicLink(at: local, withDestinationURL: before.destination)
                }
            } else {
                let staging = URL(fileURLWithPath: transfer.stagingPath!)
                if !before.alreadySwitched {
                    let replacement: URL
                    if transfer.direction == .restore {
                        replacement = staging.appendingPathComponent("data")
                    } else {
                        replacement = staging.appendingPathComponent("new-link")
                        if try !entryExists(replacement) {
                            try createSymbolicLink(at: replacement, withDestinationURL: before.destination)
                        }
                    }
                    try switchEntry(local: local, expectedLink: before.localLinkIdentity, replacement: replacement, staging: staging)
                }
                try finishRecoveredStaging(staging, source: backup, original: local)
            }
            if transfer.direction == .restore {
                try TreeCopySession.applyRootMetadata(at: local, from: baseline, ownershipRole: .destination)
                transfer.activePath = local.path
            } else { transfer.activePath = transfer.destinationPath }
            let switched = try verifiedSwitchState(transfer, baseline: baseline)
            guard switched.alreadySwitched else { throw DataOperationSafety.Failure.inspection(local.path) }
            if transfer.direction == .restore {
                try store.updateTransfer(transfer)
                lastSaved = transfer
                try store.finalizeTransfer(operationID: operationID, baseline: encoded)
            } else { try store.commitMigration(record: nil, transfer: transfer) }
            invalidateSizeCache(for: local)
            invalidateSizeCache(for: backup)
        } catch {
            guard try store.transfer(operationID: operationID) == lastSaved else { throw error }
            try recordFailure(&transfer, error: error)
        }
        return await completeSuccessfulTransfer(operationID: operationID, direction: transfer.direction,
            progressHandler: progressHandler).cleanupWarning
    }

    /// Older builds could restore a switched migration whose final record save
    /// had failed. The committed restore proves the current entry; completing
    /// its ancestor must never reinstall the old external link.
    private func finishRestoredPredecessor(_ expected: DataTransferRecord, baseline: TreeCopySnapshot,
                                           progressHandler: FileCopier.ProgressHandler?) async throws -> String? {
        let history = try store.transfers()
        guard let group = DataTransferGroup.groups(from: history).first(where: { $0.resumeTransfer?.operationID == expected.operationID }),
              group.currentTransfer.direction == .restore, group.currentTransfer.isDataSwitchComplete,
              expected.direction == .migrate, let backupPath = expected.backupPath,
              let backupIdentity = expected.backupIdentity,
              let activeIdentity = group.currentTransfer.destinationIdentity else {
            throw DataOperationSafety.Failure.inspection(expected.originalPath)
        }
        let local = URL(fileURLWithPath: expected.originalPath)
        let backup = URL(fileURLWithPath: backupPath)
        func verify() throws {
            guard !isSymbolicLink(at: local), !DiskUtility.isMountPoint(local),
                  !isSymbolicLink(at: backup), !DiskUtility.isMountPoint(backup),
                  try store.managedLink(forOriginalPath: local.path) == nil else {
                throw DataOperationSafety.Failure.conflict(local.path)
            }
            try requireIdentity(local, activeIdentity)
            try requireIdentity(backup, backupIdentity)
            try verifyRetainedTree(backup, identity: backupIdentity, baseline: baseline)
        }
        try verify()
        try await safety.requireNoKnownWriters(at: local, bundleIdentifier: expected.bundleIdentifier)
        try await safety.requireNoKnownWriters(at: backup, bundleIdentifier: expected.bundleIdentifier)
        guard try store.transfers() == history else { throw DataOperationSafety.Failure.conflict(local.path) }
        try verify()
        var completed = expected
        completed.phase = .awaitingUserVerification
        completed.recoverableReason = nil
        try store.updateTransfer(completed)
        return await completeSuccessfulTransfer(operationID: group.currentTransfer.operationID, direction: .restore,
            progressHandler: progressHandler, requireUnchangedActive: false).cleanupWarning
    }

    private struct VerifiedSwitchState: Equatable {
        let source: URL
        let destination: URL
        let alreadySwitched: Bool
        let localLinkIdentity: DataPathIdentity?
    }

    /// This performs no mutation and is repeated after every suspending check.
    private func verifiedSwitchState(_ transfer: DataTransferRecord, baseline: TreeCopySnapshot) throws -> VerifiedSwitchState {
        guard transfer.mode == .symlink, transfer.isVerifiedSwitchRecoverable,
              let destinationIdentity = transfer.destinationIdentity, let backupPath = transfer.backupPath else {
            throw DataOperationSafety.Failure.inspection(transfer.originalPath)
        }
        let local = URL(fileURLWithPath: transfer.originalPath)
        let backup = URL(fileURLWithPath: backupPath)
        let destination = URL(fileURLWithPath: transfer.destinationPath)
        let type = DataDirType(rawValue: transfer.dataDirType) ?? .custom
        if transfer.direction == .restore { try requireLocalRestoreParent(local) }
        else { try safety.requireNoManagedFileSystemAncestor(at: local) }
        let history = try store.transfers()
        guard !history.contains(where: { $0.priorOperationID == transfer.operationID }) else {
            throw DataOperationSafety.Failure.conflict(local.path)
        }
        let owned = transferAncestors(of: transfer.operationID, transfers: history)
        guard history.filter({ owned.contains($0.operationID) && $0.operationID != transfer.operationID })
            .allSatisfy(\.isDataSwitchComplete) else { throw DataOperationSafety.Failure.conflict(local.path) }
        let indexed = try store.managedLink(forOriginalPath: local.path)
        if let indexed {
            guard indexed.operationID == transfer.priorOperationID,
                  indexed.destinationIdentity.matchesFilesystemObject(transfer.sourceIdentity),
                  indexed.destinationPath == backup.path else { throw DataOperationSafety.Failure.conflict(local.path) }
        }
        for path in Set([local.path, backup.path, destination.path] + [transfer.stagingPath].compactMap { $0 }) {
            try safety.requireNoOverlap(at: URL(fileURLWithPath: path), ownedTransferIDs: owned,
                ownedLinkPath: indexed?.originalPath, ownedRetainedPath: path)
        }
        let source: URL
        let copy: URL
        let switched: Bool
        let localLink = isSymbolicLink(at: local) ? try DataPathIdentity.capture(local) : nil
        if transfer.direction == .migrate, transfer.stagingPath == nil {
            let expectedBackup = local.deletingLastPathComponent()
                .appendingPathComponent(".appports-migration-backup-\(local.lastPathComponent)-\(transfer.operationID)")
            guard backup == expectedBackup, destination != local,
                  destination.lastPathComponent == local.lastPathComponent else { throw DataOperationSafety.Failure.conflict(local.path) }
            if try entryExists(backup) {
                source = backup
                guard try !entryExists(local) || localLink != nil && linkPoints(local, to: destination) else {
                    throw DataOperationSafety.Failure.conflict(local.path)
                }
            } else {
                source = local
                guard localLink == nil, !DiskUtility.isMountPoint(local) else { throw DataOperationSafety.Failure.conflict(local.path) }
            }
            switched = localLink != nil
            copy = destination
        } else {
            let prefix = transfer.direction == .restore ? ".appports-restore-" : ".appports-normalize-"
            let staging = local.deletingLastPathComponent().appendingPathComponent(prefix + transfer.operationID.uuidString)
            guard transfer.stagingPath == staging.path, backup != local,
                  transfer.backupIdentity?.matchesFilesystemObject(transfer.sourceIdentity) == true else {
                throw DataOperationSafety.Failure.conflict(local.path)
            }
            source = backup
            if transfer.direction == .restore {
                guard destination == local else { throw DataOperationSafety.Failure.conflict(local.path) }
                switched = localLink == nil && (try? DataPathIdentity.capture(local))
                    .map(destinationIdentity.matchesFilesystemObject) == true
                copy = switched ? local : staging.appendingPathComponent("data")
            } else {
                guard destination != backup, destination != local else { throw DataOperationSafety.Failure.conflict(local.path) }
                switched = localLink != nil && linkPoints(local, to: destination)
                copy = destination
            }
            if !switched {
                guard try !entryExists(local) || localLink != nil && linkPoints(local, to: backup) else {
                    throw DataOperationSafety.Failure.conflict(local.path)
                }
            }
            if try entryExists(staging) {
                guard existingDirectory(at: staging), !isSymbolicLink(at: staging), !DiskUtility.isMountPoint(staging) else {
                    throw DataOperationSafety.Failure.conflict(staging.path)
                }
                let names = Set(try fileManager.contentsOfDirectory(atPath: staging.path))
                let replacementName = transfer.direction == .restore ? "data" : "new-link"
                guard names.isSubset(of: [replacementName, "previous-entry"]),
                      !switched || !names.contains(replacementName) else { throw DataOperationSafety.Failure.conflict(staging.path) }
                let previous = staging.appendingPathComponent("previous-entry")
                if names.contains("previous-entry") {
                    guard linkPoints(previous, to: backup, originallyAt: local), localLink == nil || switched else {
                        throw DataOperationSafety.Failure.conflict(previous.path)
                    }
                }
                if transfer.direction == .migrate, names.contains("new-link"), !linkPoints(staging.appendingPathComponent("new-link"), to: destination) {
                    throw DataOperationSafety.Failure.conflict(staging.path)
                }
            } else if !switched { throw DataOperationSafety.Failure.inspection(staging.path) }
        }
        guard !isSymbolicLink(at: copy),
              transfer.direction != .restore || !DiskUtility.isMountPoint(copy) else {
            throw DataOperationSafety.Failure.conflict(copy.path)
        }
        try requireIdentity(copy, destinationIdentity)
        if transfer.direction != .restore || !switched {
            guard !isSymbolicLink(at: source) else { throw DataOperationSafety.Failure.conflict(source.path) }
            try requireIdentity(source, transfer.sourceIdentity)
            try requireMarker(at: source, for: local, type: type, allowOwned: transfer.stagingPath != nil)
            try verifyRetainedTree(source, identity: transfer.sourceIdentity, baseline: baseline)
        }
        if transfer.direction == .migrate { try requireMarker(at: copy, for: local, type: type, allowOwned: true) }
        try TreeCopySession.verifyCopy(at: copy, against: baseline)
        return VerifiedSwitchState(source: source, destination: copy, alreadySwitched: switched, localLinkIdentity: localLink)
    }

    private func linkPoints(_ link: URL, to destination: URL, originallyAt original: URL? = nil) -> Bool {
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else { return false }
        let resolved = target.hasPrefix("/") ? URL(fileURLWithPath: target)
            : (original ?? link).deletingLastPathComponent().appendingPathComponent(target)
        return DataPathTopology.relationship(resolved.path, destination.path) == .same
    }

    private func finishRecoveredStaging(_ staging: URL, source: URL, original: URL) throws {
        guard try entryExists(staging) else { return }
        let names = try fileManager.contentsOfDirectory(atPath: staging.path)
        guard Set(names).isSubset(of: ["previous-entry"]) else { throw DataOperationSafety.Failure.conflict(staging.path) }
        if names.contains("previous-entry") {
            let previous = staging.appendingPathComponent("previous-entry")
            guard linkPoints(previous, to: source, originallyAt: original), unlink(previous.path) == 0 else { throw DataOperationSafety.Failure.conflict(previous.path) }
        }
        guard rmdir(staging.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func finishUnstartedRestoreIfNeeded(at local: URL) throws {
        let candidates = try store.transfers().filter { $0.originalPath == local.path && $0.isUnstartedSymlinkRestore }
        for expected in candidates {
            guard !runningRestores.contains(expected.operationID) else { throw DataOperationSafety.Failure.occupied(local.path) }
            try cancelUnstartedRestore(expected)
        }
    }

    private func removeUnstartedRestoreIntentIfSafe(_ transfer: DataTransferRecord) -> Bool {
        guard transfer.isUnstartedSymlinkRestore else { return false }
        do {
            guard let saved = try store.transfer(operationID: transfer.operationID), saved.isUnstartedSymlinkRestore else { return false }
            try cancelUnstartedRestore(saved)
            return true
        } catch { return false }
    }

    private func cancelUnstartedRestore(_ expected: DataTransferRecord) throws {
        let indexed = try store.managedLink(forOriginalPath: expected.originalPath)
        try store.cancelUnstartedSymlinkRestore(expected) {
            guard let backupPath = expected.backupPath, let stagingPath = expected.stagingPath else {
                throw DataOperationSafety.Failure.inspection(expected.originalPath)
            }
            let source = URL(fileURLWithPath: backupPath)
            let local = URL(fileURLWithPath: expected.originalPath)
            let staging = URL(fileURLWithPath: stagingPath)
            // The indexed source may legitimately be an external volume root.
            // Cancellation only removes our empty local staging directory.
            guard !isSymbolicLink(at: source) else {
                throw DataOperationSafety.Failure.conflict(source.path)
            }
            try requireIdentity(source, expected.sourceIdentity)
            if isSymbolicLink(at: local) {
                guard DataPathTopology.relationship(local.path, source.path) == .same else {
                    throw DataOperationSafety.Failure.conflict(local.path)
                }
            } else {
                guard try !entryExists(local), let indexed,
                      indexed.operationID == expected.priorOperationID,
                      indexed.destinationPath == source.path,
                      indexed.destinationIdentity.matchesFilesystemObject(expected.sourceIdentity) else {
                    throw DataOperationSafety.Failure.conflict(local.path)
                }
            }
            if try entryExists(staging) {
                guard existingDirectory(at: staging), !isSymbolicLink(at: staging), !DiskUtility.isMountPoint(staging),
                      try fileManager.contentsOfDirectory(atPath: staging.path).isEmpty else {
                    throw DataOperationSafety.Failure.conflict(staging.path)
                }
                // rmdir is atomic and refuses any file arriving after inspection.
                guard rmdir(staging.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            try requireIdentity(source, expected.sourceIdentity)
        }
    }

    /// Explicit cleanup may follow normal application edits to the active data.
    /// Keep every predecessor until its own retained copy has been removed.
    func cleanupRetainedLineage(operationID: UUID) async throws {
        let lineage = try retainedLineage(endingAt: operationID)
        for transfer in lineage {
            try await cleanupRetainedTransfer(operationID: transfer.operationID)
        }
    }

    private func completeSuccessfulTransfer(operationID: UUID, direction: DataTransferRecord.Direction,
                                             progressHandler: FileCopier.ProgressHandler?, requireUnchangedActive: Bool = true) async -> CompletionResult {
        do {
            await progressHandler?(.init(copiedBytes: 0, totalBytes: 0, currentFile: "正在清理旧副本...".localized,
                                        showsByteProgress: false))
            let lineage = try retainedLineage(endingAt: operationID)
            try await verifyAutomaticCleanup(lineage, requireUnchangedActive: requireUnchangedActive)
            try await cleanupRetainedLineage(operationID: operationID)
            return CompletionResult(cleanupWarning: nil)
        } catch {
            // This runs after commit/finalize. Never turn successful migration
            // into recovery just because an old copy could not be removed.
            let message = direction == .restore
                ? "数据已还原到本地，但旧副本尚未全部清理。%@".localized
                : "迁移已完成，但旧副本尚未全部清理。%@".localized
            return CompletionResult(cleanupWarning: String(format: message, "\n" + error.localizedDescription))
        }
    }

    private func completePreviousRestoreIfNeeded(item: DataDirItem, externalBaseURL: URL,
                                                progressHandler: FileCopier.ProgressHandler?) async throws {
        let local = item.path.standardizedFileURL
        guard !isSymbolicLink(at: local) else { return }
        let transfers = try store.transfers()
        let related = transfers.filter { $0.originalPath == local.path }
        let terminalRestores = related.filter { transfer in
            transfer.mode == .symlink && transfer.direction == .restore
                && [.awaitingUserVerification, .cleanupRequested].contains(transfer.phase)
                && !transfers.contains(where: { $0.priorOperationID == transfer.operationID })
        }
        guard !terminalRestores.isEmpty else { return }
        guard terminalRestores.count == 1, let terminal = terminalRestores.first else {
            throw DataOperationSafety.Failure.conflict(local.path)
        }
        let lineage = try retainedLineage(endingAt: terminal.operationID)
        guard Set(lineage.map(\.operationID)) == Set(related.map(\.operationID)) else {
            throw DataOperationSafety.Failure.conflict(local.path)
        }

        // A same-named directory is only reclaimable when it is the recorded
        // retained source in this completed chain; never adopt arbitrary data.
        let destination = externalBaseURL.appendingPathComponent(local.lastPathComponent).standardizedFileURL
        if try entryExists(destination), !lineage.contains(where: { $0.backupPath == destination.path }) {
            throw DataDirError.destinationExists(destination)
        }
        do {
            await progressHandler?(.init(copiedBytes: 0, totalBytes: 0, currentFile: "正在清理旧副本...".localized,
                                        showsByteProgress: false))
            try requirePolicy(local)
            guard !DiskUtility.isMountPoint(local) else { throw DataOperationSafety.Failure.conflict(local.path) }
            _ = try preflightWritePermission(at: externalBaseURL)
            try await verifyAutomaticCleanup(lineage, requireUnchangedActive: false)
            try await cleanupRetainedLineage(operationID: terminal.operationID)
        } catch {
            // No new intent exists until the old, independently verified copies
            // are handled; normal edits to restored local data are permitted.
            throw CompletionError.previousRestoreNeedsCleanup(error.localizedDescription)
        }
    }

    /// Oldest first, following durable identities instead of timestamps or path
    /// names. A missing predecessor was already cleaned and ends the chain.
    private func retainedLineage(endingAt operationID: UUID) throws -> [DataTransferRecord] {
        let transfers = try store.transfers()
        guard var current = transfers.first(where: { $0.operationID == operationID }) else { return [] }
        let originalPath = current.originalPath
        var visited: Set<UUID> = []
        var lineage: [DataTransferRecord] = []
        while true {
            guard visited.insert(current.operationID).inserted,
                  current.mode == .symlink, current.originalPath == originalPath,
                  [.awaitingUserVerification, .cleanupRequested].contains(current.phase),
                  current.baseline != nil, current.destinationIdentity != nil,
                  current.backupPath != nil, current.backupIdentity != nil else {
                throw DataOperationSafety.Failure.inspection(originalPath)
            }
            lineage.append(current)
            guard let priorID = current.priorOperationID,
                  let prior = transfers.first(where: { $0.operationID == priorID }) else { break }
            guard prior.direction == .migrate,
                  let identity = prior.destinationIdentity,
                  identity.matchesFilesystemObject(current.sourceIdentity) else {
                throw DataOperationSafety.Failure.conflict(originalPath)
            }
            current = prior
        }
        return Array(lineage.reversed())
    }

    /// Newly switched data is checked against the just-copied content. An older
    /// completed restore can have ordinary edits while retaining its identity.
    private func verifyAutomaticCleanup(_ lineage: [DataTransferRecord], requireUnchangedActive: Bool = true) async throws {
        guard let terminal = lineage.last else { return }
        guard !(try store.transfers()).contains(where: { $0.priorOperationID == terminal.operationID }),
              let activeIdentity = terminal.destinationIdentity, let encoded = terminal.baseline else {
            throw DataOperationSafety.Failure.conflict(terminal.originalPath)
        }
        let active = URL(fileURLWithPath: terminal.activePath)
        let local = URL(fileURLWithPath: terminal.originalPath)
        if terminal.direction == .restore {
            guard terminal.activePath == terminal.originalPath, terminal.destinationPath == terminal.originalPath,
                  !isSymbolicLink(at: local), try store.managedLink(forOriginalPath: terminal.originalPath) == nil else {
                throw DataOperationSafety.Failure.conflict(local.path)
            }
        } else {
            guard let link = try store.managedLink(forOriginalPath: terminal.originalPath),
                  link.operationID == terminal.operationID, link.destinationPath == terminal.destinationPath,
                  terminal.activePath == terminal.destinationPath,
                  link.destinationIdentity.matchesFilesystemObject(activeIdentity),
                  isSymbolicLink(at: local),
                  DataPathTopology.relationship(local.path, active.path) == .same else {
                throw DataOperationSafety.Failure.conflict(local.path)
            }
        }
        try requireIdentity(active, activeIdentity)
        try await safety.requireNoKnownWriters(at: active, bundleIdentifier: terminal.bundleIdentifier)
        try requireIdentity(active, activeIdentity)
        if requireUnchangedActive {
            let baseline = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: encoded)
            try TreeCopySession.verifyCopy(at: active, against: baseline)
        }
        // Check every retained source before removing the first one, so a
        // modified later backup does not cause an avoidable partial cleanup.
        for transfer in lineage { try verifyRetainedForCleanup(transfer) }
        try requireIdentity(active, activeIdentity)
    }

    /// A checkpoint authorizes missing entries only on the same online parent.
    /// Every remaining entry still has to match the original inode and content.
    private func verifyRetainedForCleanup(_ transfer: DataTransferRecord) throws {
        guard let path = transfer.backupPath, let identity = transfer.backupIdentity,
              let encoded = transfer.baseline else { throw DataOperationSafety.Failure.inspection(transfer.originalPath) }
        let root = URL(fileURLWithPath: path)
        let baseline = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: encoded)
        if let expectedParent = transfer.cleanupParentIdentity {
            try requireIdentity(root.deletingLastPathComponent().resolvingSymlinksInPath(), expectedParent)
            guard let retained = try TreeCopySession.retainedRemovalURL(at: root, removalID: transfer.operationID) else { return }
            try requireIdentity(retained, identity)
            try TreeCopySession.verifyRemovalRemainder(at: root, against: baseline,
                expectedVolumeUUID: identity.volumeUUID, removalID: transfer.operationID)
        } else {
            try requireIdentity(root, identity)
            try verifyRetainedTree(root, identity: identity, baseline: baseline)
        }
    }

    private struct CleanupContext {
        let activeURL: URL
        let identity: DataPathIdentity
        let lineage: Set<UUID>
        let activeLinkPath: String?
    }

    private func cleanupContext(for transfer: DataTransferRecord) throws -> CleanupContext {
        let transfers = try store.transfers()
        let descendants = transferDescendants(of: transfer.operationID, transfers: transfers)
        let lineage = descendants.reduce(into: Set<UUID>()) { $0.formUnion(transferAncestors(of: $1, transfers: transfers)) }
        let activeLink = try store.managedLinks().first { $0.originalPath == transfer.originalPath && descendants.contains($0.operationID) }
        let activeRestore = transfers.last { descendants.contains($0.operationID) && $0.direction == .restore && $0.isDataSwitchComplete }
        let active = URL(fileURLWithPath: activeLink?.destinationPath ?? activeRestore?.destinationPath ?? transfer.activePath)
        guard let identity = activeLink?.destinationIdentity ?? activeRestore?.destinationIdentity ?? transfer.destinationIdentity else {
            throw DataOperationSafety.Failure.inspection(active.path)
        }
        try requireIdentity(active, identity)
        let local = URL(fileURLWithPath: transfer.originalPath)
        if let activeLink {
            if isSymbolicLink(at: local) {
                guard DataPathTopology.relationship(local.path, active.path) == .same else { throw DataOperationSafety.Failure.conflict(local.path) }
            } else if try entryExists(local) { throw DataOperationSafety.Failure.conflict(local.path) }
            guard activeLink.destinationIdentity.matchesFilesystemObject(identity) else { throw DataOperationSafety.Failure.conflict(active.path) }
        } else if activeRestore != nil {
            guard !isSymbolicLink(at: local), !DiskUtility.isMountPoint(local), active.path == local.path else {
                throw DataOperationSafety.Failure.conflict(local.path)
            }
        }
        return CleanupContext(activeURL: active, identity: identity, lineage: lineage, activeLinkPath: activeLink?.originalPath)
    }

    /// The only operation that removes an original. Cleanup is an idempotent
    /// continuation of a successful switch, including after process termination.
    func cleanupRetainedTransfer(operationID: UUID) async throws {
        guard runningCleanups.insert(operationID).inserted else { throw DataOperationSafety.Failure.occupied(operationID.uuidString) }
        defer { runningCleanups.remove(operationID) }
        guard var transfer = try store.transfer(operationID: operationID) else { return }
        guard transfer.mode == .symlink, transfer.isDataSwitchComplete,
              let encoded = transfer.baseline, let retainedPath = transfer.backupPath,
              let retainedIdentity = transfer.backupIdentity else { throw DataOperationSafety.Failure.inspection(operationID.uuidString) }
        let retained = URL(fileURLWithPath: retainedPath)
        let parent = retained.deletingLastPathComponent().resolvingSymlinksInPath()
        let baseline = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: encoded)
        let deletionPreviouslyStarted = transfer.cleanupParentIdentity != nil
        var requestedCleanup = false
        do {
            let context = try cleanupContext(for: transfer)
            guard !DiskUtility.isMountPoint(retained) else { throw DataOperationSafety.Failure.conflict(retained.path) }
            try verifyRetainedForCleanup(transfer)
            try safety.requireNoOverlap(at: retained, ownedTransferIDs: context.lineage,
                ownedLinkPath: context.activeLinkPath, ownedRetainedPath: retained.path)
            if let actual = try TreeCopySession.retainedRemovalURL(at: retained, removalID: operationID) {
                try await safety.requireNoKnownWriters(at: actual, bundleIdentifier: transfer.bundleIdentifier)
            }
            try await safety.requireNoKnownWriters(at: context.activeURL, bundleIdentifier: transfer.bundleIdentifier)
            // Process inspection suspends this actor. Revalidate the current
            // entry and lineage after those awaits, before any removal begins.
            let fresh = try cleanupContext(for: transfer)
            guard fresh.activeURL == context.activeURL, fresh.identity == context.identity,
                  fresh.lineage == context.lineage, try store.transfer(operationID: operationID) == transfer else {
                throw DataOperationSafety.Failure.conflict(context.activeURL.path)
            }
            try verifyRetainedForCleanup(transfer)
            try store.requestCleanup(operationID: operationID)
            transfer.phase = .cleanupRequested
            transfer.recoverableReason = nil
            requestedCleanup = true
            if let actual = try TreeCopySession.retainedRemovalURL(at: retained, removalID: operationID) {
                let parentIdentity = try DataPathIdentity.capture(parent)
                try store.beginCleanupDeletion(operationID: operationID, parentIdentity: parentIdentity)
                transfer.cleanupParentIdentity = transfer.cleanupParentIdentity ?? parentIdentity
                try requireIdentity(actual, retainedIdentity)
                let type = DataDirType(rawValue: transfer.dataDirType) ?? .custom
                if try entryExists(markerURL(for: retained)) {
                    try requireMarker(at: retained, for: URL(fileURLWithPath: transfer.originalPath), type: type, allowOwned: true)
                    try removeManagedLinkMetadata(in: retained)
                    if actual.path == retained.path { try TreeCopySession.applyRootMetadata(at: retained, from: baseline) }
                }
                try requireIdentity(context.activeURL, context.identity)
                try TreeCopySession.removeVerifiedCopy(at: retained, against: baseline, allowPartialRemoval: deletionPreviouslyStarted,
                    expectedVolumeUUID: retainedIdentity.volumeUUID, removalID: operationID)
            } else {
                guard let expectedParent = transfer.cleanupParentIdentity else { throw DataOperationSafety.Failure.inspection(retained.path) }
                try requireIdentity(parent, expectedParent)
            }
            guard try TreeCopySession.retainedRemovalURL(at: retained, removalID: operationID) == nil else {
                throw DataOperationSafety.Failure.inspection(retained.path)
            }
            try store.finishTransfer(operationID: operationID, deletionConfirmed: true)
            invalidateSizeCache(for: retained)
        } catch {
            // The switch is still complete. The immutable manifest and cleanup
            // checkpoint make another attempt safe without blocking local data.
            if requestedCleanup {
                transfer.recoverableReason = error.localizedDescription
                do { try store.updateTransfer(transfer) }
                catch { AppLogger.shared.logError("无法更新副本清理恢复记录，原事务仍保留", error: error) }
            }
            throw error
        }
    }

    private func transferAncestors(of id: UUID, transfers: [DataTransferRecord]) -> Set<UUID> {
        var result: Set<UUID> = [id]
        var current = id
        while let prior = transfers.first(where: { $0.operationID == current })?.priorOperationID,
              result.insert(prior).inserted { current = prior }
        return result
    }

    private func transferDescendants(of id: UUID, transfers: [DataTransferRecord]) -> Set<UUID> {
        var ids: Set<UUID> = [id]
        var previous = -1
        while ids.count != previous {
            previous = ids.count
            for candidate in transfers where candidate.priorOperationID.map(ids.contains) == true { ids.insert(candidate.operationID) }
        }
        return ids
    }

    private func requirePolicy(_ path: URL) throws {
        do { try safety.requirePolicy(at: path) }
        catch DataOperationSafety.Failure.protectedPath { throw DataDirError.protectedPath(path) }
    }

    private func copy(from source: URL, to destination: URL, final: URL, progress: FileCopier.ProgressHandler?) async throws -> TreeCopySnapshot {
        do { return try await TreeCopySession().copy(from: source, to: destination,
            excludingRootEntries: [managedLinkMarkerFileName], finalDestination: final, progressHandler: progress) }
        catch { throw DataDirError.copyFailed(error) }
    }

    private func installMarker(source: URL, destination: URL, type: DataDirType, baseline: TreeCopySnapshot,
                               ownershipRole: TreeCopySession.OwnershipRole = .destination) throws {
        try requireMarker(at: destination, for: source, type: type, allowOwned: true)
        do {
            try writeManagedLinkMetadata(sourcePath: source, destinationPath: destination, type: type)
            try TreeCopySession.applyRootMetadata(at: destination, from: baseline, ownershipRole: ownershipRole)
            try TreeCopySession.verifyCopy(at: destination, against: baseline)
        } catch { throw DataDirError.metadataWriteFailed(error) }
    }

    private func requireMarker(at root: URL, for source: URL, type: DataDirType, allowOwned: Bool) throws {
        let marker = markerURL(for: root)
        guard try entryExists(marker) else { return }
        guard allowOwned, !isSymbolicLink(at: marker),
              let data = try? Data(contentsOf: marker),
              let metadata = try? PropertyListDecoder().decode(ManagedLinkMetadata.self, from: data),
              metadata.schemaVersion == managedLinkSchemaVersion, metadata.managedBy == managedLinkIdentifier,
              metadata.dataDirType == type.rawValue,
              DataPathTopology.relationship(metadata.sourcePath, source.path) == .same,
              DataPathTopology.relationship(metadata.destinationPath, root.path) == .same else {
            throw DataDirError.metadataWriteFailed(DataOperationSafety.Failure.conflict(marker.path))
        }
    }

    private func recordFailure(_ transfer: inout DataTransferRecord, error: Error) throws -> Never {
        transfer.phase = .needsRecovery
        transfer.recoverableReason = error.localizedDescription
        // If this write fails, the previous durable phase still reserves all known copies.
        try store.updateTransfer(transfer)
        throw error
    }

    private func removeUnstartedIntentIfSafe(_ transfer: DataTransferRecord) -> Bool {
        guard transfer.isUnstartedSymlinkMigration else { return false }
        do {
            try store.cancelUnstartedMigration(transfer) {
                try requireUnstartedMigrationFilesystem(transfer)
            }
            return true
        } catch { return false }
    }

    private func requireUnstartedMigrationFilesystem(_ transfer: DataTransferRecord) throws {
        guard transfer.isUnstartedSymlinkMigration, let backupPath = transfer.backupPath else {
            throw DataOperationSafety.Failure.inspection(transfer.originalPath)
        }
        let source = URL(fileURLWithPath: transfer.originalPath)
        let destination = URL(fileURLWithPath: transfer.destinationPath)
        let backup = URL(fileURLWithPath: backupPath)
        let original = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard original >= 0 else { throw DataOperationSafety.Failure.inspection(source.path) }
        defer { close(original) }
        var originalInfo = stat()
        guard fstat(original, &originalInfo) == 0 else { throw DataOperationSafety.Failure.inspection(source.path) }
        let currentSourceIdentity = try DataPathIdentity.capture(source)
        guard [S_IFDIR, S_IFREG].contains(originalInfo.st_mode & S_IFMT),
              transfer.sourceIdentity.matchesFilesystemObject(currentSourceIdentity),
              currentSourceIdentity.device == UInt64(UInt32(bitPattern: originalInfo.st_dev)),
              currentSourceIdentity.inode == UInt64(originalInfo.st_ino) else {
            throw DataOperationSafety.Failure.conflict(source.path)
        }

        // An absent child alone proves nothing about an offline or inaccessible
        // external volume. Open its existing parent before interpreting ENOENT.
        let parent = destination.deletingLastPathComponent()
        let targetParent = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard targetParent >= 0 else { throw DataOperationSafety.Failure.inspection(parent.path) }
        defer { close(targetParent) }
        var parentInfo = stat()
        guard fstat(targetParent, &parentInfo) == 0 else { throw DataOperationSafety.Failure.inspection(parent.path) }
        if let expectedVolume = transfer.destinationVolumeUUID {
            try requireDestinationVolume(at: parent, expected: expectedVolume)
        } else {
            // Historical intents did not record their target volume. Only an
            // independently identified live volume can distinguish that case
            // from an unmounted disk's empty directory on the source filesystem.
            guard let sourceVolume = currentSourceIdentity.volumeUUID,
                  let destinationVolume = try volumeUUID(at: parent),
                  !sourceVolume.isEmpty, !destinationVolume.isEmpty,
                  sourceVolume.caseInsensitiveCompare(destinationVolume) != .orderedSame else {
                throw DataOperationSafety.Failure.inspection(parent.path)
            }
        }
        var targetInfo = stat()
        if fstatat(targetParent, destination.lastPathComponent, &targetInfo, AT_SYMLINK_NOFOLLOW) == 0 {
            throw DataOperationSafety.Failure.conflict(destination.path)
        }
        guard errno == ENOENT else { throw DataOperationSafety.Failure.inspection(destination.path) }
        guard try !entryExists(backup) else { throw DataOperationSafety.Failure.conflict(backup.path) }
        // A sidecar can outlive its data entry after external changes. Preserve
        // the record if any marker remains rather than treating it as untouched.
        let sidecar = parent.appendingPathComponent(".\(destination.lastPathComponent)\(managedLinkMetadataSidecarSuffix)")
        guard try !entryExists(sidecar) else { throw DataOperationSafety.Failure.conflict(sidecar.path) }
        guard try !entryExists(markerURL(for: source)) else {
            throw DataOperationSafety.Failure.conflict(source.path)
        }
        var currentParent = stat()
        guard stat(parent.path, &currentParent) == 0,
              currentParent.st_dev == parentInfo.st_dev, currentParent.st_ino == parentInfo.st_ino else {
            throw DataOperationSafety.Failure.inspection(parent.path)
        }
        try requireIdentity(source, transfer.sourceIdentity)
    }

    private func requireIdentity(_ url: URL, _ identity: DataPathIdentity) throws {
        guard try identity.matchesFilesystemObject(DataPathIdentity.capture(url)) else { throw DataOperationSafety.Failure.conflict(url.path) }
    }

    private func entryExists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func renameWithoutReplacing(_ source: URL, _ destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// The old entry stays inside the recorded staging directory until the replacement is installed.
    private func switchEntry(local: URL, expectedLink: DataPathIdentity?, replacement: URL, staging: URL) throws {
        let oldEntry = staging.appendingPathComponent("previous-entry")
        if let expectedLink {
            try requireIdentity(local, expectedLink)
            try renameWithoutReplacing(local, oldEntry)
            try requireIdentity(oldEntry, expectedLink)
        } else if try entryExists(local) { throw DataDirError.destinationExists(local) }
        do {
            if isSymbolicLink(at: replacement) { try renameWithoutReplacing(replacement, local) }
            else { try DataTreeRelocator.move(replacement, to: local) }
        }
        catch {
            if let expectedLink, try !entryExists(local) {
                try requireIdentity(oldEntry, expectedLink)
                try renameWithoutReplacing(oldEntry, local)
            }
            throw error
        }
        if let expectedLink {
            try requireIdentity(oldEntry, expectedLink)
            guard isSymbolicLink(at: oldEntry) else { throw DataOperationSafety.Failure.conflict(oldEntry.path) }
            try fileManager.removeItem(at: oldEntry)
        }
        if try fileManager.contentsOfDirectory(atPath: staging.path).isEmpty { try fileManager.removeItem(at: staging) }
    }

    private func verifyRetainedTree(_ root: URL, identity: DataPathIdentity, baseline: TreeCopySnapshot) throws {
        if let volumeUUID = identity.volumeUUID {
            try TreeCopySession.verifyUnchanged(at: root, against: baseline, expectedVolumeUUID: volumeUUID)
        } else {
            try TreeCopySession.verifyUnchanged(at: root, against: baseline)
        }
    }

    private func requireLocalRestoreParent(_ local: URL) throws {
        try safety.requireLocalRestoreParent(at: local)
    }

    private func checkWritePermission(at url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) { try fileManager.createDirectory(at: url, withIntermediateDirectories: true) }
        guard fileManager.isWritableFile(atPath: url.path) else { throw DataDirError.permissionDenied(url) }
    }

    /// Inspect the nearest existing directory without creating missing parents.
    private func preflightWritePermission(at url: URL) throws -> String? {
        var ancestor = url.standardizedFileURL
        while try !entryExists(ancestor), ancestor.path != "/" { ancestor.deleteLastPathComponent() }
        guard existingDirectory(at: ancestor), fileManager.isWritableFile(atPath: ancestor.path),
              fileManager.isExecutableFile(atPath: ancestor.path) else { throw DataDirError.permissionDenied(ancestor) }
        return try volumeUUID(at: ancestor)
    }

    private func volumeUUID(at url: URL) throws -> String? {
        var actual = url.resolvingSymlinksInPath()
        actual.removeAllCachedResourceValues()
        return try actual.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    }

    private func requireDestinationVolume(at url: URL, expected: String) throws {
        guard let actual = try volumeUUID(at: url), !actual.isEmpty,
              expected.caseInsensitiveCompare(actual) == .orderedSame else {
            throw DataOperationSafety.Failure.inspection(url.path)
        }
    }

    private func createSymbolicLink(at localPath: URL, withDestinationURL externalPath: URL) throws {
        if failSymlinkCreation { throw CocoaError(.fileWriteUnknown) }
        try fileManager.createSymbolicLink(at: localPath, withDestinationURL: externalPath)
    }
    private func isSymbolicLink(at url: URL) -> Bool { (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil }
    private func existingDirectory(at url: URL) -> Bool {
        var directory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }
    private func inferredBundleIdentifier(_ local: URL) -> String? {
        let base = homeDir.appendingPathComponent("Library/Containers").path
        guard local.path.hasPrefix(base + "/") else { return nil }
        return String(local.path.dropFirst(base.count + 1)).split(separator: "/").first.map(String.init)
    }

    private func writeManagedLinkMetadata(sourcePath: URL, destinationPath: URL, type: DataDirType) throws {
        let metadata = ManagedLinkMetadata(
            schemaVersion: managedLinkSchemaVersion,
            managedBy: managedLinkIdentifier,
            sourcePath: sourcePath.standardizedFileURL.path,
            destinationPath: destinationPath.standardizedFileURL.path,
            dataDirType: type.rawValue
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary

        let markerURL = markerURL(for: destinationPath)
        let data = try encoder.encode(metadata)
        try withWritableMetadataParent(for: markerURL) {
            try data.write(to: markerURL, options: .atomic)
        }
    }

    private func removeManagedLinkMetadata(in directoryURL: URL) throws {
        let markerURL = markerURL(for: directoryURL)
        guard fileManager.fileExists(atPath: markerURL.path) else { return }
        try withWritableMetadataParent(for: markerURL) {
            try fileManager.removeItem(at: markerURL)
        }
    }

    /// Metadata work uses an open no-follow parent and restores the complete original mode.
    private func withWritableMetadataParent(for markerURL: URL, operation: () throws -> Void) throws {
        let parent = markerURL.deletingLastPathComponent()
        let descriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) == 0 else { throw POSIXError(.EPERM) }
        let identity = try DataPathIdentity.capture(parent)
        guard identity.device == UInt64(UInt32(bitPattern: info.st_dev)), identity.inode == UInt64(info.st_ino) else {
            throw DataOperationSafety.Failure.conflict(parent.path)
        }
        let permissions = info.st_mode & 0o7777
        let needsWrite = permissions & 0o200 == 0
        func restorePermissions() throws {
            guard !needsWrite || fchmod(descriptor, permissions) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var current = stat()
            guard fstat(descriptor, &current) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard current.st_mode & 0o7777 == permissions else { throw POSIXError(.EPERM) }
        }
        if needsWrite, fchmod(descriptor, permissions | 0o200) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            try requireIdentity(parent, identity)
            try operation()
            try requireIdentity(parent, identity)
        } catch {
            try restorePermissions()
            throw error
        }
        try restorePermissions()
    }

    private func markerURL(for directoryURL: URL) -> URL {
        let standardizedURL = directoryURL.standardizedFileURL
        let values = try? standardizedURL.resourceValues(forKeys: [.isDirectoryKey])

        if values?.isDirectory == true {
            return standardizedURL.appendingPathComponent(managedLinkMarkerFileName)
        }

        return standardizedURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(standardizedURL.lastPathComponent)\(managedLinkMetadataSidecarSuffix)")
    }

    /// Type is part of a validated historical record, not a classification of its path.
    private func managedType(for local: URL, external: URL, indexedType: String?) throws -> DataDirType {
        if let indexedType, let type = DataDirType(rawValue: indexedType) { return type }
        let marker = markerURL(for: external)
        if try entryExists(marker) {
            guard !isSymbolicLink(at: marker),
                  let data = try? Data(contentsOf: marker),
                  let metadata = try? PropertyListDecoder().decode(ManagedLinkMetadata.self, from: data),
                  let type = DataDirType(rawValue: metadata.dataDirType) else {
                throw DataDirError.metadataWriteFailed(DataOperationSafety.Failure.conflict(marker.path))
            }
            try requireMarker(at: external, for: local, type: type, allowOwned: true)
            return type
        }
        return inferType(for: local) ?? .custom
    }

    private func inferType(for localPath: URL) -> DataDirType? {
        let path = localPath.standardizedFileURL.path
        let libraryRoot = homeDir.appendingPathComponent("Library")

        let mappings: [(URL, DataDirType)] = [
            (libraryRoot.appendingPathComponent("Application Support"), .applicationSupport),
            (libraryRoot.appendingPathComponent("Preferences"), .preferences),
            (libraryRoot.appendingPathComponent("Containers"), .containers),
            (libraryRoot.appendingPathComponent("Group Containers"), .groupContainers),
            (libraryRoot.appendingPathComponent("Application Scripts"), .applicationScripts),
            (libraryRoot.appendingPathComponent("Caches"), .caches),
            (libraryRoot.appendingPathComponent("WebKit"), .webKit),
            (libraryRoot.appendingPathComponent("HTTPStorages"), .httpStorages),
            (libraryRoot.appendingPathComponent("Logs"), .logs),
            (libraryRoot.appendingPathComponent("Saved Application State"), .savedState)
        ]

        for (baseURL, type) in mappings where path.hasPrefix(baseURL.standardizedFileURL.path + "/") {
            return type
        }

        if path.hasPrefix(homeDir.standardizedFileURL.path + "/.") {
            return .dotFolder
        }

        return .custom
    }
}

// MARK: - 错误类型

/// 数据目录迁移操作中的错误类型
enum DataDirError: LocalizedError {
    case permissionDenied(URL)
    case destinationExists(URL)
    case deletionFailed(Error)
    case symlinkFailed(Error)
    case copyFailed(Error)
    case metadataWriteFailed(Error)
    case notASymlink(URL)
    case invalidSymlink(URL)
    case externalNotFound(URL)
    case protectedPath(URL)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let url):
            return String(format: "没有写入权限：%@".localized, url.path)
        case .destinationExists(let url):
            return String(format: "目标路径已存在真实目录，无法覆盖：%@".localized, url.lastPathComponent)
        case .deletionFailed(let error):
            return String(format: "删除原目录失败：%@".localized, error.localizedDescription)
        case .symlinkFailed(let error):
            return String(format: "创建符号链接失败：%@".localized, error.localizedDescription)
        case .copyFailed(let error):
            return String(format: "复制失败：%@".localized, error.localizedDescription)
        case .metadataWriteFailed(let error):
            return String(format: "写入 AppPorts 链接标记失败：%@".localized, error.localizedDescription)
        case .notASymlink(let url):
            return String(format: "该目录不是符号链接，无法还原：%@".localized, url.lastPathComponent)
        case .invalidSymlink(let url):
            return String(format: "无法读取符号链接目标：%@".localized, url.lastPathComponent)
        case .externalNotFound(let url):
            return String(format: "外部存储目录不存在：%@".localized, url.path)
        case .protectedPath(let url):
            return String(format: "该目录受 macOS 系统保护，无法迁移：%@。请改为迁移容器内的子目录。".localized, url.lastPathComponent)
        }
    }
}
