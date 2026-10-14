import Darwin
import Foundation
import CoreData

extension ContainerVolumeMigrator {
    enum AutomaticRecoveryError: LocalizedError, CustomNSError {
        case restored(operation: Error, retainedDetails: String?)
        case incomplete(operation: Error, recovery: Error)
        case timedOut

        static var errorDomain: String { "AppPorts.AutomaticRecovery" }
        var errorCode: Int {
            switch self {
            case .restored: return 1
            case .incomplete: return 2
            case .timedOut: return 3
            }
        }
        var errorUserInfo: [String: Any] {
            var result: [String: Any] = [NSLocalizedDescriptionKey: errorDescription ?? ""]
            switch self {
            case .restored(let operation, _):
                result[NSUnderlyingErrorKey] = operation as NSError
            case .incomplete(let operation, let recovery):
                result[NSUnderlyingErrorKey] = operation as NSError
                result[NSDetailedErrorsKey] = [recovery as NSError]
            case .timedOut: break
            }
            return result
        }

        var errorDescription: String? {
            switch self {
            case .restored(let operation, let details):
                return ["本次操作未完成，已撤回本次变更，原数据已保留，可以直接重试。".localized,
                        operation.localizedDescription, details].compactMap { $0 }.joined(separator: "\n\n")
            case .incomplete(let operation, let recovery):
                return ["本次操作未完成，数据已保留。AppPorts 会在条件恢复后继续处理，也可以重试。".localized,
                        operation.localizedDescription, recovery.localizedDescription].joined(separator: "\n\n")
            case .timedOut:
                return "自动恢复暂未完成，已保留恢复记录；再次操作时会继续检查实际数据位置。".localized
            }
        }
    }

    enum AutomaticRecoveryResult: Sendable {
        case completed
        case rolledBack(retainedDetails: String?)
    }

    func pendingMountTransfer(at path: String, direction: DataTransferRecord.Direction) throws -> DataTransferRecord? {
        let pending = try store.transfers().filter {
            $0.mode == .mount && $0.direction == direction && $0.originalPath == path
                && !$0.isDataSwitchComplete && $0.rollbackCompletedAt == nil
        }
        guard pending.count <= 1 else { throw DataOperationSafety.Failure.conflict(path) }
        return pending.first
    }

    /// Called while the outer operation still owns its process-wide lock. A
    /// cancellation stops copying, but must not cancel the work that restores
    /// an application entry. Disk commands have individual recovery deadlines.
    func recoverWithIndependentBudget(_ transfer: DataTransferRecord,
                                      finishPreparedRestore: Bool = true,
                                      timeoutNanoseconds: UInt64 = 0) async throws -> AutomaticRecoveryResult {
        let transfer = try store.adoptLegacyRestoreOwnership(transfer)
        let progress = DataTransferSession.progress
        // Disk commands have their own deadlines. A dataset-sized verification
        // must not restart forever because it exceeds a fixed 10/90s budget.
        if timeoutNanoseconds == 0 {
            return try await Task.detached(priority: .userInitiated) {
                try await DataTransferSession.$progress.withValue(progress) {
                    try await DataTransferSession.run {
                        progress?.begin(.recovering)
                        return try await self.recoverMountOperation(transfer, finishPreparedRestore: finishPreparedRestore)
                    }
                }
            }.value
        }
        return try await Task.detached(priority: .userInitiated) {
            try await DataTransferSession.$progress.withValue(progress) {
                progress?.begin(.recovering)
                return try await withThrowingTaskGroup(of: AutomaticRecoveryResult.self) { group in
                    group.addTask { try await self.recoverMountOperation(transfer, finishPreparedRestore: finishPreparedRestore) }
                    group.addTask {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                        throw AutomaticRecoveryError.timedOut
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
            }
        }.value
    }

    func recoverFailedMountOperation(at path: String, direction: DataTransferRecord.Direction,
                                     operation error: Error) async throws -> DataTransferRecord {
        guard let transfer = try pendingMountTransfer(at: path, direction: direction) else { throw error }
        let result: AutomaticRecoveryResult
        do {
            result = try await recoverWithIndependentBudget(transfer,
                finishPreparedRestore: !Self.operationWasCancelled(error))
        } catch let recovery {
            throw AutomaticRecoveryError.incomplete(operation: error, recovery: recovery)
        }
        switch result {
        case .completed:
            guard let completed = try store.transfer(operationID: transfer.operationID), completed.isDataSwitchComplete else {
                throw AutomaticRecoveryError.incomplete(operation: error,
                    recovery: DataOperationSafety.Failure.inspection(path))
            }
            return completed
        case .rolledBack(let details):
            throw AutomaticRecoveryError.restored(operation: error, retainedDetails: details)
        }
    }

    static func operationWasCancelled(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case MigrationError.ownershipRollbackFailed(_, let operation, _) = error {
            return operationWasCancelled(operation)
        }
        if case MigrationError.copyFailed(let operation) = error { return operationWasCancelled(operation) }
        if case DiskUtility.Failure.administratorPromptCancelled = error { return true }
        let cocoa = error as NSError
        return cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSUserCancelledError
    }

    private func requireRecoveryJournal(_ expected: DataTransferRecord) throws {
        try Task.checkCancellation()
        guard try store.transfer(operationID: expected.operationID) == expected,
              !(try store.transfers()).contains(where: { $0.priorOperationID == expected.operationID }) else {
            throw RecoveryJournalChanged(operation: DataOperationSafety.Failure.conflict(expected.originalPath))
        }
    }

    private func finishVerifiedRecovery(_ transfer: DataTransferRecord) async throws {
        guard transfer.isVerifiedSwitchRecoverable, let encoded = transfer.baseline else {
            throw DataOperationSafety.Failure.inspection(transfer.originalPath)
        }
        var state = VerifiedMountResume(transfer: transfer, transfers: try store.transfers(),
            mounts: try store.recordsStrict(), links: try store.managedLinks(), cleanups: try store.pendingCleanups())
        try requireVerifiedResumeLedger(state)
        try requireVerifiedResumeTopology(state)
        let baseline = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: encoded)
        do {
            if transfer.direction == .migrate { try await resumeVerifiedMountMigration(&state, baseline: baseline) }
            else { try await resumeVerifiedMountRestore(&state, baseline: baseline) }
        } catch {
            do { try requireVerifiedResumeLedger(state) }
            catch { throw RecoveryJournalChanged(operation: error) }
            throw error
        }
        synchronizeAgent(store)
    }

    private func recoverMountOperation(_ expected: DataTransferRecord,
                                       finishPreparedRestore: Bool) async throws -> AutomaticRecoveryResult {
        try requireRecoveryJournal(expected)
        if expected.isDataSwitchComplete { return .completed }
        if expected.rollbackCompletedAt != nil {
            return try await cleanupRolledBackOperation(expected)
        }
        let local = URL(fileURLWithPath: expected.originalPath)
        if expected.direction == .migrate, isMountPoint(local) {
            // A live destination can contain newer data. Never replace it with
            // the old local backup merely because the final journal write failed.
            try await finishVerifiedRecovery(expected)
            return .completed
        }
        if expected.direction == .migrate, expected.isVerifiedSwitchRecoverable, expected.backupIdentity != nil {
            do {
                try await finishVerifiedRecovery(expected)
                return .completed
            } catch {
                try Task.checkCancellation()
                guard !RecoveryJournalChanged.isContained(in: error), !isMountPoint(local) else { throw error }
                // The final mount can fail repeatedly (busy/permissions). If
                // the candidate never became active, restore the local entry.
                // rollBackMountMigration proves its contents before doing so.
            }
        }
        if expected.direction == .restore, !isMountPoint(local), !isSymbolicLink(at: local),
           let identity = try? DataPathIdentity.capture(local),
           expected.destinationIdentity.map({ identity.matchesFilesystemObject($0) }) == true {
            try await finishVerifiedRecovery(expected)
            return .completed
        }
        if expected.direction == .restore, expected.isVerifiedSwitchRecoverable, finishPreparedRestore {
            do {
                try await finishVerifiedRecovery(expected)
                return .completed
            } catch {
                try Task.checkCancellation()
                guard !RecoveryJournalChanged.isContained(in: error) else { throw error }
                // The source is still authoritative. A move/mount failure must
                // fall back to restoring that source's usable entry.
            }
        }
        var transfer = try store.transfer(operationID: expected.operationID) ?? expected
        if transfer.isPreparationRecoverable {
            do {
                try await cancelPreparation(transfer, preserveUnclaimedMaterials: false)
                return .rolledBack(retainedDetails: nil)
            } catch {
                try Task.checkCancellation()
                guard !RecoveryJournalChanged.isContained(in: error) else { throw error }
                transfer = try store.transfer(operationID: expected.operationID) ?? transfer
            }
        }
        if transfer.direction == .migrate { return try await rollBackMountMigration(transfer) }
        return try await rollBackMountRestore(transfer)
    }

    private func requireOriginalLocalData(_ transfer: DataTransferRecord) throws {
        let local = URL(fileURLWithPath: transfer.originalPath)
        guard !isMountPoint(local), !isSymbolicLink(at: local),
              try DataPathIdentity.capture(local).matchesFilesystemObject(transfer.sourceIdentity) else {
            throw DataOperationSafety.Failure.conflict(local.path)
        }
    }

    private func cleanupRolledBackOperation(_ expected: DataTransferRecord) async throws -> AutomaticRecoveryResult {
        var retained: String?
        do {
            if expected.direction == .migrate { try await removeUnactivatedMigrationVolume(expected) }
            else { try await removeUnactivatedRestoreCopy(expected) }
        } catch {
            try Task.checkCancellation()
            guard !RecoveryJournalChanged.isContained(in: error) else { throw error }
            retained = "原数据入口已恢复；自动清理尚未完成：".localized + error.localizedDescription
        }
        guard let current = try store.transfer(operationID: expected.operationID) else { return .rolledBack(retainedDetails: nil) }
        try requireRecoveryJournal(current)
        try store.finishAutomaticMountRollback(current, preserving: retained, verifyingFilesystem: {})
        return .rolledBack(retainedDetails: retained)
    }

    /// Root identity proves that the restored source, or a completed successor,
    /// still supplies the live data. Its contents may legitimately have changed.
    private func currentRollbackSource(_ transfer: DataTransferRecord) async throws -> URL {
        let local = URL(fileURLWithPath: transfer.originalPath)
        if transfer.direction == .migrate, (try? requireOriginalLocalData(transfer)) != nil { return local }
        if transfer.direction == .restore, (try? requireRestoredMount(transfer)) != nil,
           let uuid = transfer.sourceIdentity.volumeUUID {
            try await requireExpectedVolume(uuid, at: local)
            return local
        }
        let successors = try store.transfers().filter {
            $0.rollbackCompletedAt == nil && $0.isDataSwitchComplete && $0.originalPath == transfer.originalPath
                && $0.sourceIdentity.matchesFilesystemObject(transfer.sourceIdentity)
        }
        guard successors.count == 1, let successor = successors.first else {
            throw DataOperationSafety.Failure.inspection(local.path)
        }
        let current = try store.completedLocation(after: successor.operationID)
        try await requireActiveData(for: current)
        return URL(fileURLWithPath: current.activePath)
    }

    private func rollBackMountMigration(_ expected: DataTransferRecord) async throws -> AutomaticRecoveryResult {
        var transfer = expected
        try requireRecoveryJournal(transfer)
        let local = URL(fileURLWithPath: transfer.originalPath)
        guard !isMountPoint(local) else { throw DataOperationSafety.Failure.conflict(local.path) }
        let originalIsLocal = !isSymbolicLink(at: local)
            && (try? DataPathIdentity.capture(local).matchesFilesystemObject(transfer.sourceIdentity)) == true
        if !originalIsLocal {
            guard let path = transfer.backupPath else { throw DataOperationSafety.Failure.inspection(local.path) }
            let backup = URL(fileURLWithPath: path)
            guard backup.deletingLastPathComponent() == local.deletingLastPathComponent(),
                  !isMountPoint(backup), !isSymbolicLink(at: backup),
                  try DataPathIdentity.capture(backup).matchesFilesystemObject(transfer.sourceIdentity) else {
                throw DataOperationSafety.Failure.conflict(path)
            }
            // A final journal failure followed by a reboot can leave a newer
            // destination at an automatic or private mount instead of local.
            // Never reactivate the old backup until redundancy is proven.
            try await requireUnactivatedMigrationDestination(transfer)
            try requireRecoveryJournal(transfer)
            guard !isMountPoint(backup), !isSymbolicLink(at: backup),
                  try DataPathIdentity.capture(backup).matchesFilesystemObject(transfer.sourceIdentity) else {
                throw DataOperationSafety.Failure.conflict(backup.path)
            }
            try safety.requireLocalRestoreParent(at: local, isMountPoint: isMountPoint)
            if try verifiedResumeEntryExists(local) { try removeEmptyMountPoint(at: local) }
            try requireRecoveryJournal(transfer)
            try moveTree(backup, to: local)
            try DurableFileIO.syncDirectory(at: local.deletingLastPathComponent())
        }
        try requireOriginalLocalData(transfer)
        try store.finishAutomaticMountRollback(transfer, preserving: "AppPorts 正在自动清理本次操作的临时数据。".localized) {
            try requireOriginalLocalData(transfer)
        }
        transfer = try store.transfer(operationID: transfer.operationID) ?? transfer
        var retained: String?
        do { try await removeUnactivatedMigrationVolume(transfer) }
        catch {
            try Task.checkCancellation()
            guard !RecoveryJournalChanged.isContained(in: error) else { throw error }
            retained = "原数据入口已恢复；自动清理尚未完成：".localized + error.localizedDescription
        }
        try requireRecoveryJournal(transfer)
        try store.finishAutomaticMountRollback(transfer, preserving: retained) {
            try requireOriginalLocalData(transfer)
        }
        synchronizeAgent(store)
        return .rolledBack(retainedDetails: retained)
    }

    private func requireUnactivatedMigrationDestination(_ transfer: DataTransferRecord) async throws {
        guard let uuid = transfer.createdVolumeUUID, let identity = transfer.destinationIdentity,
              let encoded = transfer.baseline, let stagingPath = transfer.stagingPath,
              stagingPath == stagingMountRootURL.appendingPathComponent(transfer.operationID.uuidString).path else {
            throw DataOperationSafety.Failure.inspection(transfer.originalPath)
        }
        let baseline = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: encoded)
        let info = try await disk.volumeInfo(for: uuid)
        try requireRecoveryJournal(transfer)
        guard info.isAPFS, info.volumeUUID?.caseInsensitiveCompare(uuid) == .orderedSame else {
            throw DataOperationSafety.Failure.conflict(uuid)
        }
        let candidate: URL
        if let path = info.mountPoint, !path.isEmpty {
            candidate = URL(fileURLWithPath: path)
        } else {
            candidate = URL(fileURLWithPath: stagingPath)
            guard let parentIdentity = transfer.stagingParentIdentity,
                  try DataPathIdentity.capture(candidate.deletingLastPathComponent()).matchesFilesystemObject(parentIdentity) else {
                throw DataOperationSafety.Failure.conflict(stagingPath)
            }
            try await mountVolume(uuid, at: candidate, operationID: transfer.operationID.uuidString, allowRelocation: false,
                                  requireOwnership: baseline.ownershipCompatibility?.destinationIgnoresOwnership != true)
        }
        try await safety.requireNoKnownWriters(at: candidate, bundleIdentifier: transfer.bundleIdentifier)
        try await requireExpectedVolume(uuid, at: candidate)
        try requireRecoveryJournal(transfer)
        guard !isSymbolicLink(at: candidate),
              try DataPathIdentity.capture(candidate, volumeUUID: uuid).matchesFilesystemObject(identity) else {
            throw DataOperationSafety.Failure.conflict(candidate.path)
        }
        try TreeCopySession.verifyCopy(at: candidate, against: baseline)
    }

    private func removeUnactivatedMigrationVolume(_ transfer: DataTransferRecord) async throws {
        guard let uuid = transfer.createdVolumeUUID else {
            if let container = transfer.volumeCreationContainerUUID {
                guard let name = transfer.volumeCreationName,
                      try await !disk.hasAPFSVolume(named: name, inContainerUUID: container) else {
                    throw DataOperationSafety.Failure.inspection(transfer.volumeCreationName ?? transfer.originalPath)
                }
                try requireRecoveryJournal(transfer)
            }
            return
        }
        guard let container = transfer.volumeCreationContainerUUID, let stagingPath = transfer.stagingPath,
              stagingPath == stagingMountRootURL.appendingPathComponent(transfer.operationID.uuidString).path else {
            throw DataOperationSafety.Failure.inspection(uuid)
        }
        let baseline = try (transfer.baseline ?? transfer.sourceBaseline).map {
            try PropertyListDecoder().decode(TreeCopySnapshot.self, from: $0)
        }
        if try await !disk.apfsVolumeIsPresent(uuid, inContainer: container) { return }
        let local = try await currentRollbackSource(transfer)
        guard try await disk.apfsContainerUUID(containingVolume: uuid).caseInsensitiveCompare(container) == .orderedSame else {
            throw DataOperationSafety.Failure.conflict(uuid)
        }
        let staging = URL(fileURLWithPath: stagingPath)
        let parent = staging.deletingLastPathComponent()
        if let identity = transfer.stagingParentIdentity {
            guard try DataPathIdentity.capture(parent).matchesFilesystemObject(identity) else {
                throw DataOperationSafety.Failure.conflict(parent.path)
            }
        } else { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
        let info = try await disk.volumeInfo(for: uuid)
        if let current = info.mountPoint, !current.isEmpty, !DiskUtility.pathsMatch(current, stagingPath) {
            throw DataOperationSafety.Failure.conflict(current)
        }
        try requireRecoveryJournal(transfer)
        _ = try await currentRollbackSource(transfer)
        if !isMountPoint(staging) {
            let requiresOwnership = baseline.map { $0.ownershipCompatibility?.destinationIgnoresOwnership != true }
                ?? (transfer.recoveryMountRecord?.ownershipPolicy == .owners)
            try await mountVolume(uuid, at: staging, operationID: transfer.operationID.uuidString,
                                  allowRelocation: false, requireOwnership: requiresOwnership)
        }
        try await requireExpectedVolume(uuid, at: staging)
        try await safety.requireNoKnownWriters(at: staging)
        try await safety.requireNoKnownWriters(at: local, bundleIdentifier: transfer.bundleIdentifier)
        try requireRecoveryJournal(transfer)
        func verifyRedundantVolume() throws {
            if let baseline, let identity = transfer.destinationIdentity {
                guard try DataPathIdentity.capture(staging, volumeUUID: uuid).matchesFilesystemObject(identity) else {
                    throw DataOperationSafety.Failure.conflict(stagingPath)
                }
                if transfer.baseline != nil { try TreeCopySession.verifyCopy(at: staging, against: baseline) }
                else { _ = try TreeCopySession.partialCopySnapshot(at: staging, source: local, against: baseline) }
            } else {
                guard Set(try FileManager.default.contentsOfDirectory(atPath: stagingPath)).isSubset(of: Self.volumeSystemArtifacts) else {
                    throw DataOperationSafety.Failure.conflict(stagingPath)
                }
            }
        }
        try verifyRedundantVolume()
        try DurableFileIO.syncTree(at: local, excludingRootEntries: Self.volumeSystemArtifacts)
        try await requireExpectedVolume(uuid, at: staging)
        try requireRecoveryJournal(transfer)
        try verifyRedundantVolume()
        try await unmountVolume(mountPoint: staging)
        try requireRecoveryJournal(transfer)
        _ = try await currentRollbackSource(transfer)
        guard !isMountPoint(staging) else { throw MigrationError.unmountFailed(staging, "") }
        try await deleteAPFSVolume(uuid)
        guard try await !disk.apfsVolumeIsPresent(uuid, inContainer: container) else {
            throw DataOperationSafety.Failure.inspection(uuid)
        }
        if try verifiedResumeEntryExists(staging) { try removeEmptyMountPoint(at: staging) }
        try DurableFileIO.syncDirectory(at: parent)
    }

    private func requireRestoredMount(_ transfer: DataTransferRecord) throws {
        let local = URL(fileURLWithPath: transfer.originalPath)
        guard isMountPoint(local), let uuid = transfer.sourceIdentity.volumeUUID else {
            throw DataOperationSafety.Failure.conflict(local.path)
        }
        if transfer.sourceIdentity.isResolved {
            guard try DataPathIdentity.capture(local, volumeUUID: uuid).matchesFilesystemObject(transfer.sourceIdentity) else {
                throw DataOperationSafety.Failure.conflict(local.path)
            }
        }
    }

    private func rollBackMountRestore(_ expected: DataTransferRecord) async throws -> AutomaticRecoveryResult {
        var transfer = expected
        guard let record = transfer.recoveryMountRecord else {
            throw DataOperationSafety.Failure.inspection(transfer.originalPath)
        }
        try requireRecoveryJournal(transfer)
        let local = record.mountPointURL
        if !isMountPoint(local) {
            try safety.requireLocalRestoreParent(at: local, isMountPoint: isMountPoint)
            let hint = try await knownMountPoint(for: record, operationID: transfer.operationID.uuidString)
            if case .mounted(let current) = hint {
                try await safety.requireNoKnownWriters(at: current, bundleIdentifier: transfer.bundleIdentifier)
            }
            try requireRecoveryJournal(transfer)
            let requiresOwnership: Bool
            if let encoded = transfer.baseline ?? transfer.sourceBaseline {
                let baseline = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: encoded)
                requiresOwnership = baseline.ownershipCompatibility?.sourceIgnoresOwnership != true
            } else if let flags = transfer.originalSourceMountFlags ?? transfer.legacyMountFlags {
                requiresOwnership = flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0
            } else {
                requiresOwnership = record.ownershipPolicy == .owners || transfer.legacyRootOwnership != nil
            }
            try await mountVolume(record.volumeUUID, at: local, operationID: transfer.operationID.uuidString,
                                  knownMountPoint: hint, requireOwnership: requiresOwnership)
        }
        try await requireExpectedVolume(record.volumeUUID, at: local)
        try requireRestoredMount(transfer)
        if let flags = transfer.originalSourceMountFlags ?? transfer.legacyMountFlags {
            try requireRecoveryJournal(transfer)
            try await restoreOriginalMountOptions(mountPoint: local, volumeUUID: record.volumeUUID, originalFlags: flags)
        }
        try store.finishAutomaticMountRollback(transfer, preserving: "AppPorts 正在自动清理本次操作的临时数据。".localized) {
            try requireRestoredMount(transfer)
        }
        transfer = try store.transfer(operationID: transfer.operationID) ?? transfer
        var retained: String?
        do { try await removeUnactivatedRestoreCopy(transfer) }
        catch {
            try Task.checkCancellation()
            guard !RecoveryJournalChanged.isContained(in: error) else { throw error }
            retained = "原数据入口已恢复；自动清理尚未完成：".localized + error.localizedDescription
        }
        transfer = try store.transfer(operationID: transfer.operationID) ?? transfer
        try await requireExpectedVolume(record.volumeUUID, at: local)
        try requireRecoveryJournal(transfer)
        let removalPath = transfer.stagingPath.flatMap { path in
            (try? TreeCopySession.retainedRemovalURL(at: URL(fileURLWithPath: path), removalID: transfer.operationID))?.path
        }
        try store.finishAutomaticMountRollback(transfer, preserving: retained,
            additionalMaterialPaths: removalPath.map { [$0] } ?? []) {
            try requireRestoredMount(transfer)
        }
        synchronizeAgent(store)
        return .rolledBack(retainedDetails: retained)
    }

    private func removeUnactivatedRestoreCopy(_ transfer: DataTransferRecord) async throws {
        guard let path = transfer.stagingPath else { return }
        let staging = URL(fileURLWithPath: path)
        guard let actual = try TreeCopySession.retainedRemovalURL(at: staging, removalID: transfer.operationID) else { return }
        guard let identity = transfer.destinationIdentity, let encoded = transfer.baseline ?? transfer.sourceBaseline,
              let parentIdentity = transfer.preparationParentIdentity,
              !isMountPoint(actual), !isSymbolicLink(at: actual),
              try DataPathIdentity.capture(actual).matchesFilesystemObject(identity),
              try DataPathIdentity.capture(staging.deletingLastPathComponent()).matchesFilesystemObject(parentIdentity) else {
            throw DataOperationSafety.Failure.conflict(path)
        }
        let local = try await currentRollbackSource(transfer)
        try await safety.requireNoKnownWriters(at: local, bundleIdentifier: transfer.bundleIdentifier)
        try await safety.requireNoKnownWriters(at: actual)
        try requireRecoveryJournal(transfer)
        let baseline = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: encoded)
        // A full candidate/removal manifest proves the obsolete bytes without
        // comparing today's live tree to yesterday's contents. Partial copies
        // still require the matching source bytes to prove their prefixes.
        let removal: TreeCopySnapshot
        let wasRemoving = transfer.preparationRemovalBaseline != nil
        if let saved = transfer.preparationRemovalBaseline {
            removal = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: saved)
        } else if transfer.baseline != nil {
            try TreeCopySession.verifyCopy(at: staging, against: baseline)
            removal = try TreeCopySession.snapshot(at: staging, excludingRootEntries: Self.volumeSystemArtifacts)
        } else {
            removal = try TreeCopySession.partialCopySnapshot(at: staging, source: local, against: baseline,
                sourceVolumeUUID: DiskUtility.mountedVolumeUUID(at: local))
        }
        var removing = transfer
        removing.sourceBaseline = removing.sourceBaseline ?? encoded
        removing.preparationRemovalBaseline = try removing.preparationRemovalBaseline ?? PropertyListEncoder().encode(removal)
        removing.preparationRemovalParentIdentity = removing.preparationRemovalParentIdentity ?? parentIdentity
        try store.updateTransfer(removing)
        try DurableFileIO.syncTree(at: local, excludingRootEntries: Self.volumeSystemArtifacts)
        try TreeCopySession.removeVerifiedCopy(at: staging, against: removal, allowPartialRemoval: wasRemoving,
            expectedVolumeUUID: identity.volumeUUID, removalID: transfer.operationID)
        try DurableFileIO.syncDirectory(at: staging.deletingLastPathComponent())
    }

    /// Runs under the caller's operation lock with a noninteractive DiskUtility.
    /// Failed recovery remains durable; unchanged background failures stay quiet.
    @discardableResult
    func performAutomaticMaintenance() async -> [String] {
        var warnings: [String] = []
        let transfers: [DataTransferRecord]
        do { transfers = try store.transfers() }
        catch { return [error.localizedDescription] }
        for transfer in transfers where transfer.mode == .mount && !transfer.isDataSwitchComplete {
            if Task.isCancelled { return warnings }
            do { _ = try await recoverWithIndependentBudget(transfer, finishPreparedRestore: false) }
            catch {
                warnings.append(transfer.appName + ": " + error.localizedDescription)
                if var current = try? store.transfer(operationID: transfer.operationID), current.recoverableReason != error.localizedDescription {
                    current.recoverableReason = error.localizedDescription
                    try? store.updateTransfer(current)
                }
            }
        }
        guard let completed = try? store.transfers() else { return warnings }
        for transfer in completed where transfer.mode == .mount && transfer.isDataSwitchComplete {
            if Task.isCancelled { return warnings }
            guard let record = transfer.recoveryMountRecord else { continue }
            if let warning = await completeSuccessfulTransfer(operationID: transfer.operationID, direction: transfer.direction,
                record: record, progressHandler: nil) { warnings.append(warning.message) }
        }
        for cleanup in (try? store.pendingCleanups()) ?? [] {
            if let warning = await retryCleanup(.init(cleanup: cleanup, details: "")) { warnings.append(warning.message) }
        }
        warnings += await cleanupPreservedRestoreMaterials()
        return warnings
    }

    /// A claimed restore stage was never an application entry. Once rollback
    /// has restored the active entry, discard this private copy by its saved
    /// inode, without demanding that yesterday's copy equal today's live data.
    /// Unknown material and former active volumes remain outside this rule.
    func cleanupPreservedRestoreMaterials(at originalPath: String? = nil) async -> [String] {
        var warnings: [String] = []
        for material in (try? store.preservedMaterials()) ?? [] {
            guard originalPath == nil || originalPath == material.originalPath,
                  material.mode == .mount, material.direction == .restore,
                  material.volumeUUID == nil, let transfer = material.recoveryRecord,
                  transfer.operationID == material.id, !transfer.isDataSwitchComplete,
                  transfer.mode == material.mode, transfer.direction == material.direction,
                  transfer.originalPath == material.originalPath, transfer.appName == material.appName,
                  let candidateIdentity = transfer.destinationIdentity,
                  let parentIdentity = transfer.preparationParentIdentity,
                  let stagingPath = transfer.stagingPath else { continue }
            do {
                let local = URL(fileURLWithPath: material.originalPath)
                let staging = local.deletingLastPathComponent().appendingPathComponent(".appports-restore-staging-" + material.id.uuidString)
                let recovery = stagingMountRootURL.appendingPathComponent("recovery-" + material.id.uuidString)
                guard staging.path == stagingPath,
                      Set(material.paths).isSubset(of: [staging.path, recovery.path]),
                      existingRealDirectory(at: local), !isSymbolicLink(at: local),
                      try DataPathIdentity.capture(staging.deletingLastPathComponent()).matchesFilesystemObject(parentIdentity),
                      try !DataPathIdentity.capture(local).matchesFilesystemObject(candidateIdentity),
                      try store.transfers().allSatisfy({ $0.originalPath != local.path || $0.rollbackCompletedAt != nil || $0.isDataSwitchComplete }) else {
                    throw DataOperationSafety.Failure.conflict(local.path)
                }
                try await safety.requireNoKnownWriters(at: local, bundleIdentifier: transfer.bundleIdentifier)
                if isMountPoint(local) {
                    guard let record = try store.recordsStrict().first(where: { $0.mountPointPath == local.path }) else {
                        throw DataOperationSafety.Failure.conflict(local.path)
                    }
                    try await requireExpectedVolume(record.volumeUUID, at: local)
                }
                let activeIdentity = try DataPathIdentity.capture(local)
                if let actual = try TreeCopySession.retainedRemovalURL(at: staging, removalID: material.id) {
                    guard !isMountPoint(actual), !isSymbolicLink(at: actual),
                          try DataPathIdentity.capture(actual).matchesFilesystemObject(candidateIdentity) else {
                        throw DataOperationSafety.Failure.conflict(actual.path)
                    }
                    try await safety.requireNoKnownWriters(at: actual)
                    let baseline = try TreeCopySession.snapshot(at: actual)
                    let activeNames = try FileManager.default.contentsOfDirectory(atPath: local.path)
                        .filter { !Self.volumeSystemArtifacts.contains($0) }
                    guard baseline.entries.count == 1 || !activeNames.isEmpty else {
                        throw DataOperationSafety.Failure.inspection(local.path)
                    }
                    try DurableFileIO.syncTree(at: local, excludingRootEntries: Self.volumeSystemArtifacts)
                    guard try store.preservedMaterial(id: material.id) == material,
                          try DataPathIdentity.capture(local) == activeIdentity,
                          try DataPathIdentity.capture(staging.deletingLastPathComponent()).matchesFilesystemObject(parentIdentity) else {
                        throw DataOperationSafety.Failure.conflict(local.path)
                    }
                    try TreeCopySession.removeVerifiedCopy(at: actual, against: baseline,
                        expectedVolumeUUID: candidateIdentity.volumeUUID, removalID: material.id, requireSourceIdentity: true)
                    try DurableFileIO.syncDirectory(at: staging.deletingLastPathComponent())
                }
                if try verifiedResumeEntryExists(recovery) {
                    guard !isMountPoint(recovery), !isSymbolicLink(at: recovery),
                          try FileManager.default.contentsOfDirectory(atPath: recovery.path).isEmpty else {
                        throw DataOperationSafety.Failure.conflict(recovery.path)
                    }
                    try removeEmptyMountPoint(at: recovery)
                }
                try store.removePreservedMaterialRecord(material)
            } catch { warnings.append(material.appName + ": " + error.localizedDescription) }
        }
        return warnings
    }
}
