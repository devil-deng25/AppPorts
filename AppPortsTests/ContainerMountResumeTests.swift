import Darwin
import Foundation
import Testing
@testable import AppPorts

struct ContainerMountResumeTests {
    @Test("Activated mount and restored local trees accept writes before final recovery", arguments: [Checkpoint.migrationCommitted, .restoreFinalized])
    func activeWritesAfterFinalSaveFailure(checkpoint: Checkpoint) async throws {
        let fixture = try Fixture(checkpoint: checkpoint)
        defer { fixture.remove() }
        if checkpoint == .migrationCommitted {
            await #expect(throws: (any Error).self) { try await fixture.migrate() }
        } else {
            let migration = try await fixture.mover().migrateAndComplete(item: fixture.item, externalRootURL: fixture.external,
                appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
            await #expect(throws: (any Error).self) {
                try await fixture.mover().restore(record: migration.record, estimatedTotalBytes: 0, progressHandler: nil)
            }
        }
        let pending = try #require(try fixture.store.transfers().first)
        try Data("new active value".utf8).write(to: fixture.source.appendingPathComponent("payload.txt"))
        try Data("new document".utf8).write(to: fixture.source.appendingPathComponent("created-after-switch.txt"))
        #expect(chmod(fixture.source.path, 0o700) == 0)
        let active = try TreeCopySession.snapshot(at: fixture.source)
        let created = fixture.runner.commands(prefix: ["-A"])
        #expect(try await fixture.mover().resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil) == nil)
        #expect(try TreeCopySession.snapshot(at: fixture.source) == active)
        #expect(fixture.runner.commands(prefix: ["-A"]) == created)
        #expect(try fixture.store.transfers().isEmpty)
    }
    @Test("Verified mount migration resumes its original operation without creating or copying another volume", arguments: [
        Checkpoint.migrationVerified, .migrationUnmounted, .migrationMoved, .migrationCommitted
    ])
    func resumesMigration(checkpoint: Checkpoint) async throws {
        let fixture = try Fixture(checkpoint: checkpoint)
        defer { fixture.remove() }
        await #expect(throws: (any Error).self) { try await fixture.migrate() }
        let pending = try #require(try fixture.store.transfers().first)
        let mount = try #require(pending.recoveryMountRecord)
        #expect(pending.isVerifiedSwitchRecoverable || pending.isPreparationRecoverable)
        let created = fixture.runner.commands(prefix: ["-A"])

        let warning = try await fixture.mover().resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil)

        #expect(warning == nil)
        #expect(try fixture.store.recordsStrict() == [mount])
        #expect(try fixture.store.transfers().isEmpty)
        #expect(fixture.runner.mountedUUID(at: fixture.source) == mount.volumeUUID)
        #expect(fixture.runner.commands(prefix: ["-A"]) == created)
        #expect(try fixture.payload(at: fixture.source) == "original")
        let completedCalls = fixture.runner.calls
        #expect(try await fixture.mover().resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil) == nil)
        #expect(fixture.runner.calls == completedCalls)
    }

    @Test("Verified mount restore finishes a retained staging copy or an already switched local copy", arguments: [
        Checkpoint.restoreVerified, .restoreSwitch, .restoreFinalized
    ])
    func resumesRestore(checkpoint: Checkpoint) async throws {
        let fixture = try Fixture(checkpoint: checkpoint)
        defer { fixture.remove() }
        let migration = try await fixture.migrate()
        await #expect(throws: (any Error).self) {
            try await fixture.mover().restore(record: migration.record, estimatedTotalBytes: 0, progressHandler: nil)
        }
        let pending = try #require(try fixture.store.transfers().first { $0.direction == .restore })
        #expect(pending.isVerifiedSwitchRecoverable || pending.isPreparationRecoverable)
        let copiedIdentity = try #require(pending.destinationIdentity)
        let created = fixture.runner.commands(prefix: ["-A"])

        let warning = try await fixture.mover().resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil)

        #expect(warning == nil)
        #expect(try fixture.store.recordsStrict().isEmpty)
        #expect(try fixture.store.transfers().isEmpty)
        #expect(!fixture.runner.isMounted(fixture.source))
        #expect(try DataPathIdentity.capture(fixture.source).matchesFilesystemObject(copiedIdentity))
        #expect(fixture.runner.commands(prefix: ["-A"]) == created)
        #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).count == 1)
        #expect(try fixture.payload(at: fixture.source) == "original")
    }

    @Test("An already restored local copy can finalize while its old volume is unavailable")
    func finalizesRestoreWithoutOldVolume() async throws {
        let fixture = try Fixture(checkpoint: .restoreFinalized)
        defer { fixture.remove() }
        let migration = try await fixture.mover().migrateAndComplete(item: fixture.item, externalRootURL: fixture.external,
            appName: "Synthetic", bundleIdentifier: nil, progressHandler: nil)
        await #expect(throws: (any Error).self) {
            try await fixture.mover().restore(record: migration.record, estimatedTotalBytes: 0, progressHandler: nil)
        }
        let pending = try #require(try fixture.store.transfers().first)
        let local = try TreeCopySession.snapshot(at: fixture.source)
        let mounts = fixture.runner.commands(prefix: ["mount"])
        fixture.runner.failWhen(prefix: ["info"])

        let warning = try await fixture.mover().resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil)

        #expect(warning != nil)
        #expect(try fixture.store.transfer(operationID: pending.operationID)?.isDataSwitchComplete == true)
        #expect(try fixture.store.recordsStrict().isEmpty)
        #expect(fixture.runner.commands(prefix: ["mount"]) == mounts)
        #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
        #expect(try TreeCopySession.snapshot(at: fixture.source) == local)
        #expect(try await fixture.mover().resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil) != nil)
        #expect(try TreeCopySession.snapshot(at: fixture.source) == local)
        fixture.runner.clearFailure()
        #expect(try await fixture.mover().resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil) == nil)
        #expect(try fixture.store.transfers().isEmpty)
    }

    @Test("Changed verified copies are retained and never overwritten during resume", arguments: [
        Checkpoint.migrationVerified, .restoreVerified
    ])
    func changedCopyBlocksResume(checkpoint: Checkpoint) async throws {
        let fixture = try Fixture(checkpoint: checkpoint)
        defer { fixture.remove() }
        if checkpoint == .migrationVerified {
            await #expect(throws: (any Error).self) { try await fixture.migrate() }
        } else {
            let migration = try await fixture.migrate()
            await #expect(throws: (any Error).self) {
                try await fixture.mover().restore(record: migration.record, estimatedTotalBytes: 0, progressHandler: nil)
            }
        }
        let pending = try #require(try fixture.store.transfers().first { $0.isVerifiedSwitchRecoverable || $0.isPreparationRecoverable })
        let staged = URL(fileURLWithPath: try #require(pending.stagingPath))
        try Data("changed copy".utf8).write(to: staged.appendingPathComponent("payload.txt"))
        let original = try TreeCopySession.snapshot(at: fixture.source)
        let mountCalls = fixture.runner.commands(prefix: ["mount"])
        let unmountCalls = fixture.runner.commands(prefix: ["unmount"])

        await #expect(throws: (any Error).self) {
            try await fixture.mover().resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil)
        }

        #expect(try fixture.payload(at: staged) == "changed copy")
        #expect(try TreeCopySession.snapshot(at: fixture.source) == original)
        #expect(try fixture.store.transfer(operationID: pending.operationID)?.baseline == pending.baseline)
        #expect(fixture.runner.commands(prefix: ["mount"]) == mountCalls)
        #expect(fixture.runner.commands(prefix: ["unmount"]) == unmountCalls)
        #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
    }

    @Test("A ledger change during resume inspection is preserved and stops all disk mutations")
    func changedLedgerBlocksResume() async throws {
        let fixture = try Fixture(checkpoint: .migrationVerified)
        defer { fixture.remove() }
        await #expect(throws: (any Error).self) { try await fixture.migrate() }
        var replacement = try #require(try fixture.store.transfers().first)
        replacement.recoverableReason = "Updated by another operation"
        let expected = replacement
        let store = fixture.store
        let commands = fixture.runner.calls

        await #expect(throws: (any Error).self) {
            try await fixture.mover().resumeVerifiedTransfer(operationID: expected.operationID) { _ in
                try? store.updateTransfer(expected)
            }
        }

        #expect(try store.transfer(operationID: expected.operationID) == expected)
        #expect(fixture.runner.calls == commands)
    }

    @Test("A standard automatic mount resumes only with matching recorded UUID and marker", arguments: [
        "matching", "marker-mismatch", "uuid-mismatch"
    ])
    func automaticMountIdentity(scenario: String) async throws {
        let fixture = try Fixture(checkpoint: .migrationUnmounted)
        defer { fixture.remove() }
        await #expect(throws: (any Error).self) { try await fixture.migrate() }
        let pending = try #require(try fixture.store.transfers().first)
        let mount = try #require(pending.recoveryMountRecord)
        let automatic = URL(fileURLWithPath: "/Volumes").appendingPathComponent(mount.volumeName)
        let detached = try #require(fixture.runner.detachedContents(for: mount.volumeUUID))
        let retainedCopy = try TreeCopySession.snapshot(at: detached)
        // Only the fake mount table uses /Volumes. Its data remains in the
        // private temporary fixture; this test never creates a /Volumes entry.
        fixture.runner.markVolumeMounted(mount.volumeUUID, at: automatic.path)
        let runner = fixture.runner
        let service = fixture.mover(
            volumeUUIDMarker: { $0.path == automatic.path && scenario != "marker-mismatch" ? mount.volumeUUID : "OTHER-UUID" },
            mountedVolumeUUID: { scenario == "uuid-mismatch" && $0.path == automatic.path ? "OTHER-UUID" : runner.mountedUUID(at: $0) },
            mountFlags: { $0.path == automatic.path ? UInt32(MNT_IGNORE_OWNERSHIP) : UInt32(MNT_DONTBROWSE) })
        let unmounts = runner.commands(prefix: ["unmount"])
        let mounts = runner.commands(prefix: ["mount"])
        if scenario == "matching" {
            #expect(try await service.resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil) == nil)
            #expect(runner.commands(prefix: ["unmount"]).contains(["unmount", automatic.path]))
            #expect(runner.commands(prefix: ["-u"]).isEmpty)
            #expect(runner.commands(prefix: ["mount"]).allSatisfy { $0[3].hasPrefix(fixture.root.path + "/") })
            #expect(try fixture.payload(at: fixture.source) == "original")
            #expect(try fixture.store.transfers().isEmpty)
        } else {
            await #expect(throws: (any Error).self) {
                try await service.resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil)
            }
            #expect(runner.commands(prefix: ["unmount"]) == unmounts)
            #expect(runner.commands(prefix: ["mount"]) == mounts)
            #expect(try TreeCopySession.snapshot(at: detached) == retainedCopy)
            #expect(try fixture.payload(at: fixture.source) == "original")
        }
    }

    @Test("The mount helper rechecks the ledger after its disk query before creating or locking a mount point")
    func diskQueryLedgerChangePreventsMount() async throws {
        let fixture = try Fixture(checkpoint: .migrationMoved)
        defer { fixture.remove() }
        await #expect(throws: (any Error).self) { try await fixture.migrate() }
        let pending = try #require(try fixture.store.transfers().first)
        let staging = URL(fileURLWithPath: try #require(pending.stagingPath))
        let backup = URL(fileURLWithPath: try #require(pending.backupPath))
        let unchanged = try TreeCopySession.snapshot(at: backup)
        var replacement = pending
        replacement.recoverableReason = "Changed during disk inspection"
        let expected = replacement
        let store = fixture.store
        let intercepted = DiskInfoInterception(base: fixture.runner, uuid: try #require(pending.createdVolumeUUID), occurrence: 2) {
            try store.updateTransfer(expected)
        }
        let mounts = fixture.runner.commands(prefix: ["mount"])

        await #expect(throws: (any Error).self) {
            try await fixture.mover(diskRunner: intercepted).resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil)
        }

        #expect(try store.transfer(operationID: pending.operationID) == expected)
        #expect(fixture.runner.commands(prefix: ["mount"]) == mounts)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.source.path))
        #expect(try TreeCopySession.snapshot(at: backup) == unchanged)
    }

    @Test("A retained backup changed during the final mount query is not connected or overwritten")
    func diskQueryBackupChangePreventsFinalMount() async throws {
        let fixture = try Fixture(checkpoint: .migrationVerified)
        defer { fixture.remove() }
        await #expect(throws: (any Error).self) { try await fixture.migrate() }
        let pending = try #require(try fixture.store.transfers().first)
        let backup = URL(fileURLWithPath: try #require(pending.backupPath))
        let intercepted = DiskInfoInterception(base: fixture.runner, uuid: try #require(pending.createdVolumeUUID), occurrence: 2) {
            try Data("new retained data".utf8).write(to: backup.appendingPathComponent("payload.txt"))
        }
        let mounts = fixture.runner.commands(prefix: ["mount"])

        await #expect(throws: (any Error).self) {
            try await fixture.mover(diskRunner: intercepted).resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil)
        }

        #expect(fixture.runner.commands(prefix: ["mount"]) == mounts)
        #expect(!FileManager.default.fileExists(atPath: fixture.source.path))
        #expect(try fixture.payload(at: backup) == "new retained data")
        #expect(try fixture.store.transfer(operationID: pending.operationID)?.isVerifiedSwitchRecoverable == true)
        #expect(fixture.runner.commands(prefix: ["apfs", "deleteVolume"]).isEmpty)
    }

    @Test("A replacement volume during the writer probe is rejected before any ownership update")
    func writerProbeVolumeChangePreventsOwnershipUpdate() async throws {
        let fixture = try Fixture(checkpoint: .restoreVerified)
        defer { fixture.remove() }
        let migration = try await fixture.migrate()
        await #expect(throws: (any Error).self) {
            try await fixture.mover().restore(record: migration.record, estimatedTotalBytes: 0, progressHandler: nil)
        }
        let pending = try #require(try fixture.store.transfers().first { $0.direction == .restore })
        let probe = ReplacementVolumeProbe()
        let source = fixture.source
        let runner = fixture.runner
        let service = fixture.mover(
            mountedVolumeUUID: { probe.didProbe && $0.path == source.path ? "REPLACEMENT-UUID" : runner.mountedUUID(at: $0) },
            mountFlags: { $0.path == source.path ? UInt32(MNT_IGNORE_OWNERSHIP) : UInt32(MNT_DONTBROWSE) },
            safetyRunner: probe)

        await #expect(throws: (any Error).self) {
            try await service.resumeVerifiedTransfer(operationID: pending.operationID, progressHandler: nil)
        }

        #expect(probe.didProbe)
        #expect(runner.commands(prefix: ["-u"]).isEmpty)
        #expect(try fixture.payload(at: source) == "original")
        let unchanged = try #require(try fixture.store.transfer(operationID: pending.operationID))
        #expect(unchanged == pending)
        #expect(unchanged.isPreparationRecoverable)
        #expect(unchanged.sourceBaseline != nil && unchanged.baseline == nil)
    }

    private final class DiskInfoInterception: ShellCommandRunning, @unchecked Sendable {
        let base: FakeDiskCommandRunner
        let uuid: String
        let action: @Sendable () throws -> Void
        private let lock = NSLock()
        private var remaining: Int

        init(base: FakeDiskCommandRunner, uuid: String, occurrence: Int, action: @escaping @Sendable () throws -> Void) {
            self.base = base
            self.uuid = uuid
            self.remaining = occurrence
            self.action = action
        }

        private func shouldAct(_ arguments: [String]) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard arguments.first == "info", arguments.last == uuid, remaining > 0 else { return false }
            remaining -= 1
            return remaining == 0
        }

        func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
            let result = try await base.run(executable: executable, arguments: arguments, timeout: timeout)
            if shouldAct(arguments) { try action() }
            return result
        }
    }

    private final class ReplacementVolumeProbe: ShellCommandRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var probed = false
        var didProbe: Bool { lock.lock(); defer { lock.unlock() }; return probed }
        private func markProbed() { lock.lock(); defer { lock.unlock() }; probed = true }
        func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
            markProbed()
            return ShellCommandResult(status: 1, standardOutput: Data(), standardError: Data(), timedOut: false)
        }
    }

    enum Checkpoint: Sendable {
        case migrationVerified, migrationUnmounted, migrationMoved, migrationCommitted
        case restoreVerified, restoreSwitch, restoreFinalized
    }

    private final class InterruptingWriter: @unchecked Sendable {
        let checkpoint: Checkpoint
        private let lock = NSLock()
        private var interrupted = false

        init(_ checkpoint: Checkpoint) { self.checkpoint = checkpoint }

        func write(_ data: Data, to url: URL) throws {
            lock.lock()
            defer { lock.unlock() }
            let document = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            let transfers = document?["transfers"] as? [[String: Any]] ?? []
            let shouldInterrupt = transfers.contains { transfer in
                let direction = transfer["direction"] as? String
                let phase = transfer["phase"] as? String
                switch checkpoint {
                case .migrationVerified: return direction == "migrate" && phase == "verified"
                case .migrationUnmounted: return direction == "migrate" && phase == "switching" && transfer["backupIdentity"] == nil
                case .migrationMoved: return direction == "migrate" && phase == "switching" && transfer["backupIdentity"] != nil
                case .migrationCommitted: return direction == "migrate" && phase == "awaitingUserVerification"
                case .restoreVerified: return direction == "restore" && phase == "verified"
                case .restoreSwitch: return direction == "restore" && phase == "switching"
                case .restoreFinalized: return direction == "restore" && phase == "awaitingUserVerification"
                }
            }
            if !interrupted, shouldInterrupt {
                interrupted = true
                throw CocoaError(.fileWriteNoPermission)
            }
            try data.write(to: url, options: .atomic)
        }
    }

    private struct Fixture {
        let root: URL
        let source: URL
        let external: URL
        let store: ContainerMountStore
        let runner: FakeDiskCommandRunner

        init(checkpoint: Checkpoint) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ContainerMountResumeTests-\(UUID())")
                .resolvingSymlinksInPath()
            source = root.appendingPathComponent("Home/Library/Containers/com.example.resume/Data/Documents/Payload")
            external = root.appendingPathComponent("External/AppPorts")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            try Data("original".utf8).write(to: source.appendingPathComponent("payload.txt"))
            let uuid = try #require(try source.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
            runner = FakeDiskCommandRunner(createdVolumeUUID: uuid)
            let writer = InterruptingWriter(checkpoint)
            store = ContainerMountStore(fileURL: root.appendingPathComponent("records.plist"), writeData: { try writer.write($0, to: $1) })
        }

        var item: DataDirItem {
            DataDirItem(name: "Payload", path: source, type: .containers, priority: .critical, description: "fixture")
        }

        func mover(diskRunner: (any ShellCommandRunning)? = nil,
                   volumeUUIDMarker: (@Sendable (URL) -> String?)? = nil,
                   mountedVolumeUUID: (@Sendable (URL) -> String?)? = nil,
                   mountFlags: (@Sendable (URL) -> UInt32?)? = nil,
                   safetyRunner: any ShellCommandRunning = SyntheticNoWritersRunner()) -> ContainerVolumeMigrator {
            let runner = runner
            let externalPath = external.path
            return ContainerVolumeMigrator(disk: DiskUtility(runner: diskRunner ?? runner, commandTimeout: 5), store: store,
                stagingMountRootURL: root.appendingPathComponent("mounts"),
                isMountPoint: { runner.isMounted($0) },
                mountedVolumePath: { $0.path.hasPrefix(externalPath) ? "/SyntheticExternal" : "/" },
                mountedVolumeUUID: mountedVolumeUUID ?? { runner.mountedUUID(at: $0) }, volumeUUIDMarker: volumeUUIDMarker ?? { _ in nil },
                synchronizeAgent: { _ in }, availableCapacity: { _ in nil },
                mountFlags: mountFlags ?? { _ in UInt32(MNT_DONTBROWSE) }, homeDirectory: root.appendingPathComponent("Home"),
                safetyRunner: safetyRunner, makeMountPointLease: { try runner.makeMountPointLease(at: $0) })
        }

        @discardableResult
        func migrate() async throws -> ContainerVolumeMigrator.MigrationResult {
            try await mover().migrate(item: item, externalRootURL: external, appName: "Synthetic",
                bundleIdentifier: nil, progressHandler: nil)
        }

        func payload(at root: URL) throws -> String {
            try String(contentsOf: root.appendingPathComponent("payload.txt"), encoding: .utf8)
        }

        func remove() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/chmod")
            process.arguments = ["-R", "u+rwx", root.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil { process.waitUntilExit() }
            try? FileManager.default.removeItem(at: root)
        }
    }
}
