import Darwin
import Foundation
import Testing
@testable import AppPorts

struct DataPreparationRecoveryTests {
    @Test("A partial real copy can be cancelled or restarted after reopening its ledger",
          arguments: ["symlink-migrate", "symlink-restore", "mount-migrate", "mount-restore"], [false, true])
    func partialCopyHasExit(scenario: String, restart: Bool) async throws {
        let fixture = try Fixture(mount: scenario.hasPrefix("mount"))
        defer { fixture.remove() }
        let restore = scenario.hasSuffix("restore")
        if restore { try await fixture.migrateFirst() }
        let authority = fixture.authoritativeSource(restore: restore)
        let original = try TreeCopySession.snapshot(at: authority)
        let operation = Task {
            try await fixture.perform(restore: restore) { progress in
                if progress.currentFile == "a.txt" { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: (any Error).self) { try await operation.value }
        let pending = try #require(try fixture.store.transfers().last)
        #expect(pending.isPreparationRecoverable)
        #expect(pending.sourceBaseline != nil)
        #expect(pending.baseline == nil)
        #expect(pending.destinationIdentity != nil)
        let candidate = URL(fileURLWithPath: try #require(pending.preparationPath))
        #expect(try String(contentsOf: candidate.appendingPathComponent("a.txt"), encoding: .utf8) == "first")
        #expect(!FileManager.default.fileExists(atPath: candidate.appendingPathComponent("b.txt").path))
        #expect(try TreeCopySession.snapshot(at: authority) == original)

        let cold = ContainerMountStore(fileURL: fixture.ledger)
        if restart {
            let warning: String?
            if fixture.mount { warning = try await fixture.mountMover(store: cold).resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil) }
            else { warning = try await fixture.dataMover(store: cold).resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil) }
            #expect(warning == nil)
            #expect(try String(contentsOf: fixture.local.appendingPathComponent("a.txt"), encoding: .utf8) == "first")
            #expect(try String(contentsOf: fixture.local.appendingPathComponent("b.txt"), encoding: .utf8) == "second")
        } else {
            if fixture.mount { try await fixture.mountMover(store: cold).cancelPreparation(operationID: pending.operationID) }
            else { try await fixture.dataMover(store: cold).cancelPreparation(operationID: pending.operationID) }
            #expect(try TreeCopySession.snapshot(at: authority) == original)
            if fixture.mount {
                #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).count == (restore ? 0 : 1))
            }
        }
        #expect(try cold.transfers().isEmpty)
        #expect(try cold.preservedMaterials().isEmpty)
    }

    @Test("Unknown creation windows remain visible after ending their reservation",
          arguments: ["symlink-migrate", "symlink-restore", "mount-migrate", "mount-restore"])
    func unknownCreationIsPreserved(scenario: String) async throws {
        let writer = FaultWriter()
        let fixture = try Fixture(mount: scenario.hasPrefix("mount"), writer: writer)
        defer { fixture.remove() }
        let restore = scenario.hasSuffix("restore")
        if restore { try await fixture.migrateFirst() }
        writer.rejectNext(field: "destinationIdentity")
        await #expect(throws: (any Error).self) { try await fixture.perform(restore: restore, progress: nil) }
        let pending = try #require(try fixture.store.transfers().last)
        #expect(pending.sourceBaseline != nil)
        #expect(pending.destinationIdentity == nil)
        let candidate = URL(fileURLWithPath: try #require(pending.preparationPath))
        try Data("unique material".utf8).write(to: candidate.appendingPathComponent("unclaimed.txt"))
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        await #expect(throws: (any Error).self) {
            if fixture.mount { try await fixture.mountMover(store: cold).cancelPreparation(operationID: pending.operationID) }
            else { try await fixture.dataMover(store: cold).cancelPreparation(operationID: pending.operationID) }
        }
        if fixture.mount { try await fixture.mountMover(store: cold).cancelPreparation(operationID: pending.operationID, preserveUnclaimedMaterials: true) }
        else { try await fixture.dataMover(store: cold).cancelPreparation(operationID: pending.operationID, preserveUnclaimedMaterials: true) }
        #expect(try cold.transfers().isEmpty)
        let material = try #require(try cold.preservedMaterials().first)
        #expect(material.id == pending.operationID)
        #expect(material.paths.contains(candidate.path))
        #expect(try String(contentsOf: candidate.appendingPathComponent("unclaimed.txt"), encoding: .utf8) == "unique material")
        #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
    }

    @Test("A changed source or unknown added payload is never discarded with a partial candidate",
          arguments: [false, true], ["source-write", "extra-file", "root-replaced", "parent-replaced"])
    func partialConflictsPreserveEverything(mount: Bool, conflict: String) async throws {
        let fixture = try Fixture(mount: mount)
        defer { fixture.remove() }
        let task = Task {
            try await fixture.perform(restore: false) { progress in
                if progress.currentFile == "a.txt" { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: (any Error).self) { try await task.value }
        let pending = try #require(try fixture.store.transfers().first)
        let candidate = URL(fileURLWithPath: try #require(pending.preparationPath))
        if conflict == "source-write" { try Data("later source write".utf8).write(to: fixture.local.appendingPathComponent("a.txt")) }
        if conflict == "extra-file" { try Data("unique".utf8).write(to: candidate.appendingPathComponent("new.txt")) }
        if conflict == "root-replaced" {
            try FileManager.default.moveItem(at: candidate, to: fixture.root.appendingPathComponent("saved-candidate"))
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
            try Data("replacement".utf8).write(to: candidate.appendingPathComponent("new.txt"))
        }
        if conflict == "parent-replaced" {
            let parent = candidate.deletingLastPathComponent()
            try FileManager.default.moveItem(at: parent, to: fixture.root.appendingPathComponent("saved-parent"))
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        }
        let source = try TreeCopySession.snapshot(at: fixture.local)
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        await #expect(throws: (any Error).self) {
            if mount { try await fixture.mountMover(store: cold).cancelPreparation(operationID: pending.operationID) }
            else { try await fixture.dataMover(store: cold).cancelPreparation(operationID: pending.operationID) }
        }
        #expect(try TreeCopySession.snapshot(at: fixture.local) == source)
        #expect(try cold.transfer(operationID: pending.operationID) != nil)
        #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
    }

    @Test("A failed verified-baseline save can promote the complete candidate without recopying", arguments: [false, true])
    func completeCandidateSurvivesBaselineSave(mount: Bool) async throws {
        let writer = FaultWriter()
        let fixture = try Fixture(mount: mount, writer: writer)
        defer { fixture.remove() }
        writer.rejectNext(field: "baseline")
        await #expect(throws: (any Error).self) { try await fixture.perform(restore: false, progress: nil) }
        let pending = try #require(try fixture.store.transfers().first)
        let identity = try #require(pending.destinationIdentity)
        #expect(pending.baseline == nil)
        let creations = fixture.runner.commands(prefix: ["-A"])
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        let warning: String?
        if mount { warning = try await fixture.mountMover(store: cold).resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil) }
        else { warning = try await fixture.dataMover(store: cold).resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil) }
        #expect(warning == nil)
        let active = mount ? fixture.local : fixture.external.appendingPathComponent("Payload")
        #expect(try DataPathIdentity.capture(active, volumeUUID: mount ? pending.createdVolumeUUID : nil).matchesFilesystemObject(identity))
        #expect(fixture.runner.commands(prefix: ["-A"]) == creations)
    }

    @Test("A noowners restore partial can cancel or restart without leaving temporary ownership options", arguments: [false, true])
    func noownersPartialRestore(restart: Bool) async throws {
        let fixture = try Fixture(mount: true)
        defer { fixture.remove() }
        try await fixture.migrateFirst()
        let runner = fixture.runner, local = fixture.local
        let flags: @Sendable (URL) -> UInt32? = { url in
            guard url.path == local.path else { return UInt32(MNT_DONTBROWSE) }
            let noowners = runner.commands(prefix: ["-u"]).last.map { $0[2].split(separator: ",").contains("noowners") } ?? true
            return UInt32(MNT_DONTBROWSE | MNT_NODEV | MNT_NOSUID) | (noowners ? UInt32(MNT_IGNORE_OWNERSHIP) : 0)
        }
        let source = try TreeCopySession.snapshot(at: local)
        let record = try #require(try fixture.store.recordsStrict().first)
        let task = Task {
            try await fixture.mountMover(mountFlags: flags).restore(record: record, estimatedTotalBytes: 0) { progress in
                if progress.currentFile == "a.txt" { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: (any Error).self) { try await task.value }
        let pending = try #require(try fixture.store.transfers().first)
        #expect(pending.sourceBaseline != nil)
        #expect(pending.originalSourceMountFlags.map { $0 & UInt32(MNT_IGNORE_OWNERSHIP) != 0 } == true)
        #expect(flags(local).map { $0 & UInt32(MNT_IGNORE_OWNERSHIP) != 0 } == true)
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        if restart {
            #expect(try await fixture.mountMover(store: cold, mountFlags: flags).resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil) == nil)
            #expect(!runner.isMounted(local))
            #expect(try String(contentsOf: local.appendingPathComponent("b.txt"), encoding: .utf8) == "second")
        } else {
            try await fixture.mountMover(store: cold, mountFlags: flags).cancelPreparation(operationID: pending.operationID)
            #expect(flags(local).map { $0 & UInt32(MNT_IGNORE_OWNERSHIP) != 0 } == true)
            #expect(try TreeCopySession.snapshot(at: local) == source)
        }
        #expect(try cold.transfers().isEmpty)
    }

    @Test("Cancellation can finish after its candidate was removed but the final record save failed",
          arguments: ["symlink-migrate", "symlink-restore", "mount-migrate", "mount-restore"])
    func cancelAfterFinalSaveFailure(scenario: String) async throws {
        let writer = FaultWriter()
        let fixture = try Fixture(mount: scenario.hasPrefix("mount"), writer: writer)
        defer { fixture.remove() }
        let restore = scenario.hasSuffix("restore")
        if restore { try await fixture.migrateFirst() }
        let authority = fixture.authoritativeSource(restore: restore)
        let source = try TreeCopySession.snapshot(at: authority)
        let task = Task {
            try await fixture.perform(restore: restore) { progress in
                if progress.currentFile == "a.txt" { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: (any Error).self) { try await task.value }
        let pending = try #require(try fixture.store.transfers().first)
        writer.rejectNextEmptyTransfers()
        await #expect(throws: (any Error).self) {
            if fixture.mount { try await fixture.mountMover().cancelPreparation(operationID: pending.operationID) }
            else { try await fixture.dataMover().cancelPreparation(operationID: pending.operationID) }
        }
        #expect(try fixture.store.transfer(operationID: pending.operationID)?.preparationRemovalParentIdentity != nil)
        let deletions = fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).count
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        if fixture.mount { try await fixture.mountMover(store: cold).cancelPreparation(operationID: pending.operationID) }
        else { try await fixture.dataMover(store: cold).cancelPreparation(operationID: pending.operationID) }
        #expect(try cold.transfers().isEmpty)
        #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).count == deletions)
        #expect(try TreeCopySession.snapshot(at: authority) == source)
    }

    @Test("An inspected restore source with no created candidate can cancel or retry", arguments: [false, true])
    func sourceInspectedWithoutCandidate(restart: Bool) async throws {
        let writer = FaultWriter()
        let fixture = try Fixture(mount: true, writer: writer)
        defer { fixture.remove() }
        try await fixture.migrateFirst()
        writer.rejectNext(field: "sourceBaseline")
        await #expect(throws: (any Error).self) { try await fixture.perform(restore: true, progress: nil) }
        let pending = try #require(try fixture.store.transfers().first)
        #expect(pending.sourceIdentity.isResolved)
        #expect(pending.sourceBaseline == nil)
        #expect(pending.destinationIdentity == nil)
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        if restart { #expect(try await fixture.mountMover(store: cold).resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil) == nil) }
        else { try await fixture.mountMover(store: cold).cancelPreparation(operationID: pending.operationID) }
        #expect(try cold.transfers().isEmpty)
        #expect(try String(contentsOf: fixture.local.appendingPathComponent("b.txt"), encoding: .utf8) == "second")
    }

    @Test("Cancelled restore directories keep their intent until their recorded parent is synchronized",
          arguments: [false, true], ["unchanged", "before-sync", "during-sync"])
    func removedRestoreDirectoryKeepsParentBarrier(mount: Bool, replacement: String) async throws {
        let writer = FaultWriter()
        let fixture = try Fixture(mount: mount, writer: writer)
        defer { fixture.remove() }
        try await fixture.migrateFirst()
        let parent = mount ? fixture.root.appendingPathComponent("mounts") : fixture.home
        let failures = SyncProbe()
        let failSync: @Sendable (URL, Bool) throws -> Void = { directory, alias in
            if directory.path == parent.path {
                failures.record(directory)
                throw POSIXError(.EIO)
            }
            try DurableFileIO.syncDirectory(at: directory, resolvingAlias: alias)
        }
        let sourceSnapshot: TreeCopySnapshot
        if mount {
            let record = try #require(try fixture.store.recordsStrict().first)
            try await fixture.mountMover().unmount(record: record)
            writer.rejectNext(field: "sourceBaseline")
            await #expect(throws: CocoaError(.fileWriteOutOfSpace)) { try await fixture.perform(restore: true, progress: nil) }
            let inspected = try #require(try fixture.store.transfers().first)
            let recovery = URL(fileURLWithPath: try #require(inspected.backupPath))
            #expect(fixture.runner.isMounted(recovery))
            #expect(inspected.sourceIdentity.isResolved)
            #expect(inspected.sourceBaseline == nil)
            #expect(inspected.destinationIdentity == nil)
            #expect(inspected.recoveryMountPointIdentity != nil)
            #expect(!FileManager.default.fileExists(atPath: try #require(inspected.stagingPath)))
            sourceSnapshot = try TreeCopySession.snapshot(at: recovery)
            await #expect(throws: POSIXError(.EIO)) {
                try await fixture.cancelRestore(inspected.operationID, synchronizeDirectory: failSync)
            }
        } else {
            sourceSnapshot = try TreeCopySession.snapshot(at: fixture.external.appendingPathComponent("Payload"))
            // The stage claim is durable before the source baseline save fails.
            // No data candidate exists, so automatic cancellation owns this empty stage.
            writer.rejectNext(field: "sourceBaseline")
            let mover = fixture.dataMover(synchronizeDirectory: { directory, alias in
                if directory.path == parent.path {
                    let hasStage = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                        .contains { $0.hasPrefix(".appports-restore-") }
                    if !hasStage { try failSync(directory, alias); return }
                }
                try DurableFileIO.syncDirectory(at: directory, resolvingAlias: alias)
            })
            do {
                _ = try await mover.restore(item: fixture.item, progressHandler: nil)
                Issue.record("Expected the source baseline save to fail before copying")
            } catch DataDirError.copyFailed(let underlying) {
                let failure = underlying as NSError
                #expect(failure.domain == NSCocoaErrorDomain)
                #expect(failure.code == CocoaError.fileWriteOutOfSpace.rawValue)
            } catch {
                Issue.record("Unexpected source baseline save error: \(error)")
            }
        }
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        let pending = try #require(try cold.transfers().first)
        let removed = URL(fileURLWithPath: try #require(mount ? pending.backupPath : pending.stagingPath))
        let parentIdentity = try #require(pending.stagingParentIdentity)
        let entryIdentity = try DataPathIdentity.capture(fixture.local)
        let entryMode = try fixture.permissions(at: fixture.local)
        if mount { #expect(entryMode == 0) }
        else { #expect(pending.stagingIdentity != nil) }
        #expect(try DataPathIdentity.capture(parent).matchesFilesystemObject(parentIdentity))
        #expect(!FileManager.default.fileExists(atPath: removed.path))
        #expect(failures.paths == [parent.path])
        let source: URL
        if mount {
            let uuid = try #require(pending.sourceIdentity.volumeUUID)
            source = try #require(fixture.runner.detachedContents(for: uuid))
        } else { source = fixture.external.appendingPathComponent("Payload") }
        #expect(try TreeCopySession.snapshot(at: source) == sourceSnapshot)
        let ledger = try Data(contentsOf: fixture.ledger)
        let mounts = fixture.runner.commands(prefix: ["mount"])
        let unmounts = fixture.runner.commands(prefix: ["unmount"])
        await #expect(throws: POSIXError(.EIO)) {
            try await fixture.cancelRestore(pending.operationID, store: cold, synchronizeDirectory: failSync)
        }
        #expect(failures.paths == [parent.path, parent.path])
        #expect(try Data(contentsOf: fixture.ledger) == ledger)
        #expect(try cold.transfer(operationID: pending.operationID) == pending)

        if replacement != "unchanged" {
            let savedParent = fixture.root.appendingPathComponent("saved-cancellation-parent")
            if replacement == "before-sync" { try fixture.replaceCancellationParent(parent, savingTo: savedParent) }
            let attempted = SyncProbe()
            await #expect(throws: DataOperationSafety.Failure.self) {
                try await fixture.cancelRestore(pending.operationID,
                    store: ContainerMountStore(fileURL: fixture.ledger), synchronizeDirectory: { directory, alias in
                        attempted.record(directory)
                        try DurableFileIO.syncDirectory(at: directory, resolvingAlias: alias)
                        if replacement == "during-sync" {
                            try fixture.replaceCancellationParent(parent, savingTo: savedParent)
                        }
                    })
            }
            #expect(attempted.paths == (replacement == "before-sync" ? [] : [parent.path]))
            #expect(try DataPathIdentity.capture(savedParent).matchesFilesystemObject(parentIdentity))
            #expect(try !DataPathIdentity.capture(parent).matchesFilesystemObject(parentIdentity))
            #expect(try Data(contentsOf: fixture.ledger) == ledger)
            try fixture.restoreCancellationParent(parent, from: savedParent)
        }

        let completed = ContainerMountStore(fileURL: fixture.ledger)
        let synchronized = SyncProbe()
        try await fixture.cancelRestore(pending.operationID, store: completed, synchronizeDirectory: { directory, alias in
            synchronized.record(directory)
            try DurableFileIO.syncDirectory(at: directory, resolvingAlias: alias)
        })
        #expect(synchronized.paths == [parent.path])
        #expect(try completed.transfers().isEmpty)
        #expect(try completed.preservedMaterials().isEmpty)
        #expect(try TreeCopySession.snapshot(at: source) == sourceSnapshot)
        #expect(try DataPathIdentity.capture(fixture.local) == entryIdentity)
        #expect(try fixture.permissions(at: fixture.local) == entryMode)
        #expect(fixture.runner.commands(prefix: ["mount"]) == mounts)
        #expect(fixture.runner.commands(prefix: ["unmount"]) == unmounts)
        #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
        if mount { #expect(try completed.recordsStrict().count == 1) }
        else { #expect(try completed.managedLinks().count == 1) }
    }

    @Test("A restore intent saved before directory creation can still cancel",
          arguments: ["symlink", "legacy-symlink", "mount-online", "mount-offline"])
    func uncreatedRestoreDirectoryCanCancel(scenario: String) async throws {
        let writer = FaultWriter()
        let fixture = try Fixture(mount: scenario.hasPrefix("mount"), writer: writer)
        defer { fixture.remove() }
        try await fixture.migrateFirst()
        if scenario == "mount-offline" {
            try await fixture.mountMover().unmount(record: try #require(try fixture.store.recordsStrict().first))
        }
        writer.failAfterNextRestoreIntent()
        await #expect(throws: POSIXError(.EIO)) { try await fixture.perform(restore: true, progress: nil) }
        if scenario == "legacy-symlink" { try fixture.removeRecordedField("stagingParentIdentity") }
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        let pending = try #require(try cold.transfers().first)
        #expect(pending.sourceBaseline == nil)
        #expect(pending.destinationIdentity == nil)
        #expect(pending.stagingIdentity == nil)
        #expect(pending.recoveryMountPointIdentity == nil)
        #expect(!FileManager.default.fileExists(atPath: try #require(pending.stagingPath)))
        if fixture.mount { #expect(!FileManager.default.fileExists(atPath: try #require(pending.backupPath))) }
        let source: URL
        if scenario == "mount-offline" {
            let uuid = try #require(pending.sourceIdentity.volumeUUID)
            source = try #require(fixture.runner.detachedContents(for: uuid))
        } else { source = fixture.authoritativeSource(restore: true) }
        let snapshot = try TreeCopySession.snapshot(at: source)
        let entryIdentity = try DataPathIdentity.capture(fixture.local)
        let entryMode = try fixture.permissions(at: fixture.local)
        if scenario == "mount-offline" { #expect(entryMode == 0) }
        let mounts = fixture.runner.commands(prefix: ["mount"])
        let unmounts = fixture.runner.commands(prefix: ["unmount"])
        let synchronized = SyncProbe()
        try await fixture.cancelRestore(pending.operationID, store: cold, synchronizeDirectory: { directory, alias in
            synchronized.record(directory)
            try DurableFileIO.syncDirectory(at: directory, resolvingAlias: alias)
        })
        #expect(synchronized.paths == (scenario == "symlink" ? [fixture.home.path] : []))
        #expect(try cold.transfers().isEmpty)
        #expect(try TreeCopySession.snapshot(at: source) == snapshot)
        #expect(try DataPathIdentity.capture(fixture.local) == entryIdentity)
        #expect(try fixture.permissions(at: fixture.local) == entryMode)
        #expect(fixture.runner.commands(prefix: ["mount"]) == mounts)
        #expect(fixture.runner.commands(prefix: ["unmount"]) == unmounts)
        #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
    }

    @Test("An unclaimed symlink restore stage is preserved even when empty", arguments: [false, true])
    func unclaimedSymlinkRestoreStageIsPreserved(hasPayload: Bool) async throws {
        let writer = FaultWriter()
        let fixture = try Fixture(mount: false, writer: writer)
        defer { fixture.remove() }
        try await fixture.migrateFirst()
        let source = fixture.external.appendingPathComponent("Payload")
        let sourceSnapshot = try TreeCopySession.snapshot(at: source)
        let entryIdentity = try DataPathIdentity.capture(fixture.local)
        writer.rejectNext(field: "stagingIdentity")
        await #expect(throws: CocoaError(.fileWriteOutOfSpace)) { try await fixture.perform(restore: true, progress: nil) }
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        let pending = try #require(try cold.transfers().first)
        #expect(pending.stagingParentIdentity != nil)
        #expect(pending.stagingIdentity == nil)
        #expect(pending.sourceBaseline == nil)
        #expect(pending.destinationIdentity == nil)
        let staging = URL(fileURLWithPath: try #require(pending.stagingPath))
        #expect(FileManager.default.fileExists(atPath: staging.path))
        if hasPayload { try Data("unclaimed payload".utf8).write(to: staging.appendingPathComponent("new.txt")) }
        let stagedSnapshot = try TreeCopySession.snapshot(at: staging)
        let ledger = try Data(contentsOf: fixture.ledger)
        do {
            try await fixture.dataMover(store: cold).cancelUnstartedRestore(operationID: pending.operationID)
            Issue.record("Expected cancellation to require the durable stage claim")
        } catch let failure as DataOperationSafety.Failure {
            if case .inspection(let path) = failure { #expect(path == staging.path) }
            else { Issue.record("Unexpected unclaimed stage failure: \(failure)") }
        } catch { Issue.record("Unexpected unclaimed stage cancellation error: \(error)") }
        #expect(try Data(contentsOf: fixture.ledger) == ledger)
        #expect(try TreeCopySession.snapshot(at: staging) == stagedSnapshot)
        try await fixture.dataMover(store: cold).cancelPreparation(operationID: pending.operationID, preserveUnclaimedMaterials: true)
        #expect(try cold.transfers().isEmpty)
        let material = try #require(try cold.preservedMaterials().first)
        #expect(material.id == pending.operationID)
        #expect(material.paths.contains(staging.path))
        #expect(try TreeCopySession.snapshot(at: staging) == stagedSnapshot)
        #expect(try TreeCopySession.snapshot(at: source) == sourceSnapshot)
        #expect(try DataPathIdentity.capture(fixture.local) == entryIdentity)
        #expect(try cold.managedLinks().count == 1)
    }

    @Test("A private restore mount is not unmounted without its claim or matching volume",
          arguments: ["missing-claim", "foreign-volume"])
    func privateRestoreCancellationKeepsUnknownMount(conflict: String) async throws {
        let writer = FaultWriter()
        let fixture = try Fixture(mount: true, writer: writer)
        defer { fixture.remove() }
        try await fixture.migrateFirst()
        let record = try #require(try fixture.store.recordsStrict().first)
        try await fixture.mountMover().unmount(record: record)
        writer.rejectNext(field: "sourceBaseline")
        await #expect(throws: CocoaError(.fileWriteOutOfSpace)) { try await fixture.perform(restore: true, progress: nil) }
        if conflict == "missing-claim" { try fixture.removeRecordedField("recoveryMountPointIdentity") }
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        let pending = try #require(try cold.transfers().first)
        let recovery = URL(fileURLWithPath: try #require(pending.backupPath))
        let snapshot = try TreeCopySession.snapshot(at: recovery)
        let ledger = try Data(contentsOf: fixture.ledger)
        let unmounts = fixture.runner.commands(prefix: ["unmount"])
        let runner = fixture.runner
        let mover = fixture.mountMover(store: cold, mountedVolumeUUID: { path in
            if conflict == "foreign-volume", path.path == recovery.path { return "FOREIGN-VOLUME" }
            return runner.mountedUUID(at: path)
        })
        do {
            try await mover.cancelPreparation(operationID: pending.operationID)
            Issue.record("Expected the private mount claim or volume identity to reject cancellation")
        } catch let failure as DataOperationSafety.Failure {
            #expect(conflict == "missing-claim")
            if case .inspection(let path) = failure { #expect(path == recovery.path) }
            else { Issue.record("Unexpected safety failure: \(failure)") }
        } catch let failure as ContainerVolumeMigrator.MigrationError {
            #expect(conflict == "foreign-volume")
            if case .unexpectedMountedVolume(let path) = failure { #expect(path.path == recovery.path) }
            else { Issue.record("Unexpected volume failure: \(failure)") }
        } catch { Issue.record("Unexpected private mount cancellation error: \(error)") }
        #expect(fixture.runner.commands(prefix: ["unmount"]) == unmounts)
        #expect(fixture.runner.isMounted(recovery))
        #expect(try TreeCopySession.snapshot(at: recovery) == snapshot)
        #expect(try Data(contentsOf: fixture.ledger) == ledger)
        #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
    }

    @Test("Guarded restore placeholders still reject data, replacement, and changed permissions",
          arguments: ["nonempty", "replaced", "mode-change"])
    func guardedRestorePlaceholderConflictsKeepIntent(conflict: String) async throws {
        let writer = FaultWriter()
        let fixture = try Fixture(mount: true, writer: writer)
        defer { fixture.remove() }
        try await fixture.migrateFirst()
        let record = try #require(try fixture.store.recordsStrict().first)
        try await fixture.mountMover().unmount(record: record)
        writer.failAfterNextRestoreIntent()
        await #expect(throws: POSIXError(.EIO)) { try await fixture.perform(restore: true, progress: nil) }
        #expect(try fixture.permissions(at: fixture.local) == 0)
        if conflict == "nonempty" {
            // Model a new local write, then restore the actual guarded state
            // before calling cancellation. A locked directory is not proof of emptiness.
            try #require(chmod(fixture.local.path, 0o700) == 0)
            try Data("new local data".utf8).write(to: fixture.local.appendingPathComponent("new.txt"))
            try #require(chmod(fixture.local.path, 0) == 0)
        }
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        let pending = try #require(try cold.transfers().first)
        let uuid = try #require(pending.sourceIdentity.volumeUUID)
        let source = try #require(fixture.runner.detachedContents(for: uuid))
        let snapshot = try TreeCopySession.snapshot(at: source)
        let entryIdentity = try DataPathIdentity.capture(fixture.local)
        let ledger = try Data(contentsOf: fixture.ledger)
        let unmounts = fixture.runner.commands(prefix: ["unmount"])
        let saved = fixture.local.deletingLastPathComponent().appendingPathComponent("saved-local-placeholder")
        let synchronized = SyncProbe()
        let runner = fixture.runner
        let mover = fixture.mountMover(store: cold, makeMountPointLease: { path in
            let lease = try runner.makeMountPointLease(at: path)
            if path.path == fixture.local.path {
                if conflict == "replaced" {
                    // Keep the same parent: macOS needs access to update a
                    // guarded directory's parent when moving it elsewhere.
                    // This rename actually replaces the entry without opening it.
                    try #require(rename(path.path, saved.path) == 0)
                    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
                    try Data("replacement data".utf8).write(to: path.appendingPathComponent("new.txt"))
                    guard chmod(path.path, 0) == 0 else { throw POSIXError(.EACCES) }
                } else if conflict == "mode-change" {
                    guard chmod(path.path, 0o700) == 0 else { throw POSIXError(.EACCES) }
                }
            }
            return lease
        }, synchronizeCleanupParent: { directory in
            synchronized.record(directory)
            try DurableFileIO.syncDirectory(at: directory)
        })
        do {
            try await mover.cancelPreparation(operationID: pending.operationID)
            Issue.record("Expected the changed guarded placeholder to reject cancellation")
        } catch let failure as MountPointLease.Failure {
            switch failure {
            case .notEmpty: #expect(conflict == "nonempty")
            case .replaced: #expect(conflict == "replaced" || conflict == "mode-change")
            case .notDirectory: Issue.record("A real directory was unexpectedly rejected as not a directory")
            }
        } catch { Issue.record("Unexpected guarded placeholder error: \(error)") }
        #expect(synchronized.paths.isEmpty)
        #expect(try Data(contentsOf: fixture.ledger) == ledger)
        #expect(try TreeCopySession.snapshot(at: source) == snapshot)
        #expect(try DataPathIdentity.capture(conflict == "replaced" ? saved : fixture.local) == entryIdentity)
        #expect(try fixture.permissions(at: fixture.local) == (conflict == "mode-change" ? 0o700 : 0))
        #expect(fixture.runner.commands(prefix: ["unmount"]) == unmounts)
        #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
        if conflict != "mode-change" {
            // Read the preserved payload only after proving cancellation kept
            // the placeholder locked and its intent unchanged.
            try #require(chmod(fixture.local.path, 0o700) == 0)
            #expect(try String(contentsOf: fixture.local.appendingPathComponent("new.txt"), encoding: .utf8)
                == (conflict == "nonempty" ? "new local data" : "replacement data"))
        }
    }

    @Test("Normalization uses the same partial cancellation and operation-preserving restart", arguments: [false, true])
    func normalizationPartial(restart: Bool) async throws {
        let fixture = try Fixture(mount: false)
        defer { fixture.remove() }
        try await fixture.migrateFirst()
        let source = fixture.external.appendingPathComponent("Payload")
        let destination = fixture.external.appendingPathComponent("Normalized")
        let original = try TreeCopySession.snapshot(at: source)
        let task = Task {
            try await fixture.dataMover().normalizeManagedLinkAndComplete(localPath: fixture.local,
                currentExternalPath: source, normalizedExternalPath: destination) { progress in
                if progress.currentFile == "a.txt" { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: (any Error).self) { try await task.value }
        let pending = try #require(try fixture.store.transfers().first)
        #expect(pending.sourceBaseline != nil)
        #expect(pending.stagingIdentity != nil)
        let cold = ContainerMountStore(fileURL: fixture.ledger)
        if restart {
            #expect(try await fixture.dataMover(store: cold).resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil) == nil)
            #expect(try cold.managedLink(forOriginalPath: fixture.local.path)?.operationID == pending.operationID)
            #expect(try String(contentsOf: destination.appendingPathComponent("b.txt"), encoding: .utf8) == "second")
        } else {
            try await fixture.dataMover(store: cold).cancelPreparation(operationID: pending.operationID)
            #expect(try TreeCopySession.snapshot(at: source) == original)
        }
        #expect(try cold.transfers().isEmpty)
    }

    private final class FaultWriter: @unchecked Sendable {
        private let lock = NSLock()
        private var field: String?
        private var rejectEmpty = false
        private var stopAfterRestoreIntent = false
        func rejectNext(field: String) { lock.lock(); self.field = field; lock.unlock() }
        func rejectNextEmptyTransfers() { lock.lock(); rejectEmpty = true; lock.unlock() }
        func failAfterNextRestoreIntent() { lock.lock(); stopAfterRestoreIntent = true; lock.unlock() }
        func write(_ bytes: Data, to url: URL) throws {
            lock.lock()
            let document = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any]
            let transfers = document?["transfers"] as? [[String: Any]] ?? []
            let reject = field.map { key in transfers.contains { $0[key] != nil } } == true || rejectEmpty && transfers.isEmpty
            let stopAfterWrite = stopAfterRestoreIntent && transfers.contains {
                $0["direction"] as? String == "restore" && $0["phase"] as? String == "preparing"
            }
            if reject { field = nil; rejectEmpty = false }
            if stopAfterWrite { stopAfterRestoreIntent = false }
            lock.unlock()
            if reject { throw CocoaError(.fileWriteOutOfSpace) }
            try DurableFileIO.write(bytes, to: url)
            if stopAfterWrite { throw POSIXError(.EIO) }
        }
    }

    private final class SyncProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        var paths: [String] { lock.lock(); defer { lock.unlock() }; return values }
        func record(_ directory: URL) { lock.lock(); values.append(directory.path); lock.unlock() }
    }

    private struct Fixture: Sendable {
        let root: URL
        let home: URL
        let local: URL
        let external: URL
        let ledger: URL
        let mount: Bool
        let store: ContainerMountStore
        let runner: FakeDiskCommandRunner

        init(mount: Bool, writer: FaultWriter = FaultWriter()) throws {
            self.mount = mount
            root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsPreparation-\(UUID())").resolvingSymlinksInPath()
            home = root.appendingPathComponent("Home")
            local = home.appendingPathComponent(mount ? "Library/Containers/org.example.fixture/Data/Documents/Payload" : "Payload")
            external = root.appendingPathComponent("External")
            ledger = root.appendingPathComponent("records.plist")
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
            try Data("first".utf8).write(to: local.appendingPathComponent("a.txt"))
            try Data("second".utf8).write(to: local.appendingPathComponent("b.txt"))
            store = ContainerMountStore(fileURL: ledger, writeData: { try writer.write($0, to: $1) })
            runner = FakeDiskCommandRunner(createdVolumeUUID: try DataPathIdentity.capture(local).volumeUUID)
        }

        var item: DataDirItem { .init(name: "Payload", path: local, type: mount ? .containers : .custom, priority: .recommended, description: "") }
        func dataMover(store: ContainerMountStore? = nil,
                       synchronizeDirectory: @escaping @Sendable (URL, Bool) throws -> Void = {
                           try DurableFileIO.syncDirectory(at: $0, resolvingAlias: $1)
                       }) -> DataDirMover {
            DataDirMover(homeDir: home, store: store ?? self.store, runner: SyntheticNoWritersRunner(),
                         synchronizeDirectory: synchronizeDirectory)
        }
        func mountMover(store: ContainerMountStore? = nil,
                        mountFlags: @escaping @Sendable (URL) -> UInt32? = { _ in UInt32(MNT_DONTBROWSE) },
                        mountedVolumeUUID: (@Sendable (URL) -> String?)? = nil,
                        makeMountPointLease: (@Sendable (URL) throws -> any MountPointLeasing)? = nil,
                        synchronizeCleanupParent: @escaping @Sendable (URL) throws -> Void = {
                            try DurableFileIO.syncDirectory(at: $0)
                        }) -> ContainerVolumeMigrator {
            let runner = runner
            let external = external
            return ContainerVolumeMigrator(disk: DiskUtility(runner: runner, commandTimeout: 5), store: store ?? self.store,
                stagingMountRootURL: root.appendingPathComponent("mounts"), isMountPoint: { runner.isMounted($0) },
                mountedVolumePath: { $0.path.hasPrefix(external.path) ? "/SyntheticExternal" : "/" },
                mountedVolumeUUID: mountedVolumeUUID ?? { runner.mountedUUID(at: $0) },
                synchronizeAgent: { _ in }, availableCapacity: { _ in nil }, mountFlags: mountFlags,
                homeDirectory: home, safetyRunner: SyntheticNoWritersRunner(),
                makeMountPointLease: makeMountPointLease ?? { try runner.makeMountPointLease(at: $0) },
                synchronizeCleanupParent: synchronizeCleanupParent)
        }
        func permissions(at path: URL) throws -> mode_t {
            var info = stat()
            guard lstat(path.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return info.st_mode & 0o7777
        }
        func cancelRestore(_ operationID: UUID, store: ContainerMountStore? = nil,
                           synchronizeDirectory: @escaping @Sendable (URL, Bool) throws -> Void) async throws {
            if mount {
                try await mountMover(store: store, synchronizeCleanupParent: { try synchronizeDirectory($0, false) })
                    .cancelPreparation(operationID: operationID)
            } else {
                try await dataMover(store: store, synchronizeDirectory: synchronizeDirectory)
                    .cancelUnstartedRestore(operationID: operationID)
            }
        }
        func replaceCancellationParent(_ parent: URL, savingTo saved: URL) throws {
            try FileManager.default.moveItem(at: parent, to: saved)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            // Keep the original link and source valid so only parent ownership
            // distinguishes this replacement from a legitimate cold retry.
            if !mount { try FileManager.default.moveItem(at: saved.appendingPathComponent(local.lastPathComponent), to: local) }
        }
        func restoreCancellationParent(_ parent: URL, from saved: URL) throws {
            if !mount { try FileManager.default.moveItem(at: local, to: saved.appendingPathComponent(local.lastPathComponent)) }
            try FileManager.default.removeItem(at: parent)
            try FileManager.default.moveItem(at: saved, to: parent)
        }
        func removeRecordedField(_ field: String) throws {
            var document = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: ledger), format: nil) as? [String: Any])
            var transfers = try #require(document["transfers"] as? [[String: Any]])
            #expect(transfers.count == 1)
            transfers[0].removeValue(forKey: field)
            document["transfers"] = transfers
            try DurableFileIO.write(PropertyListSerialization.data(fromPropertyList: document, format: .binary, options: 0), to: ledger)
        }
        func migrateFirst() async throws {
            if mount { _ = try await mountMover().migrateAndComplete(item: item, externalRootURL: external, appName: "Fixture", bundleIdentifier: nil, progressHandler: nil) }
            else { _ = try await dataMover().migrateAndComplete(item: item, to: external, progressHandler: nil) }
        }
        func perform(restore: Bool, progress: FileCopier.ProgressHandler?) async throws {
            if mount {
                if restore {
                    let record = try #require(try store.recordsStrict().first)
                    _ = try await mountMover().restore(record: record, estimatedTotalBytes: 0, progressHandler: progress)
                } else { _ = try await mountMover().migrate(item: item, externalRootURL: external, appName: "Fixture", bundleIdentifier: nil, progressHandler: progress) }
            } else {
                if restore { try await dataMover().restore(item: item, progressHandler: progress) }
                else { try await dataMover().migrate(item: item, to: external, progressHandler: progress) }
            }
        }
        func authoritativeSource(restore: Bool) -> URL { restore && !mount ? external.appendingPathComponent("Payload") : local }
        func remove() {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/chmod")
            task.arguments = ["-R", "u+rwx", root.path]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            if (try? task.run()) != nil { task.waitUntilExit() }
            try? FileManager.default.removeItem(at: root)
        }
    }
}
