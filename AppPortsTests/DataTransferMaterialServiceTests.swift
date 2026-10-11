import Darwin
import Foundation
import Testing
@testable import AppPorts

struct DataTransferMaterialServiceTests {
    @Test("Explicitly removing a preserved record keeps every file and unknown volume reference", arguments: [false, true])
    func explicitRemovalIsOnlyBookkeeping(mount: Bool) async throws {
        let fixture = try Fixture(mount: mount)
        defer { fixture.remove() }
        let source = try TreeCopySession.snapshot(at: fixture.source)
        let materialTree = try TreeCopySession.snapshot(at: fixture.candidate)
        let unrelated = ContainerMountRecord(appName: "Other", bundleIdentifier: "org.appports.fixture.other",
            dataDirType: "Containers", mountPointPath: fixture.root.appendingPathComponent("Other").path,
            volumeUUID: UUID().uuidString, volumeName: "Other", externalRootPath: fixture.external.path)
        try fixture.store.upsert(unrelated)
        let reopened = ContainerMountStore(fileURL: fixture.ledger)
        let service = DataTransferMaterialService(store: reopened)

        #expect(try await service.removePreservedMaterialRecord(id: fixture.material.id,
            confirmation: .keepAllFilesAndVolumes) == .recordRemoved)

        #expect(try reopened.preservedMaterials().isEmpty)
        #expect(try reopened.transfers().isEmpty)
        #expect(try reopened.recordsStrict() == [unrelated])
        #expect(try TreeCopySession.snapshot(at: fixture.source) == source)
        #expect(try TreeCopySession.snapshot(at: fixture.candidate) == materialTree)
        let saved = try Data(contentsOf: fixture.ledger)
        #expect(try await service.removePreservedMaterialRecord(id: fixture.material.id,
            confirmation: .keepAllFilesAndVolumes) == .alreadyRemoved)
        #expect(try await service.recheckPreservedMaterial(id: fixture.material.id) == .recordAlreadyRemoved)
        #expect(try Data(contentsOf: fixture.ledger) == saved)
    }

    @Test("Rechecking listed content is read-only and leaves the summary visible")
    func recheckExistingContentDoesNotRemoveRecord() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bytes = try Data(contentsOf: fixture.ledger)
        let service = DataTransferMaterialService(store: fixture.store)
        #expect(try await service.recheckPreservedMaterial(id: fixture.material.id) == .listedPathsStillExist([fixture.candidate.path]))
        #expect(try Data(contentsOf: fixture.ledger) == bytes)
        #expect(try fixture.store.preservedMaterials() == [fixture.material])
        #expect(try String(contentsOf: fixture.candidate.appendingPathComponent("payload"), encoding: .utf8) == "unknown material")
    }

    @Test("Missing locations, moved material, and offline parents do not prove deletion",
          arguments: ["deleted", "moved", "offline", "replaced-parent"])
    func missingPathsRequireExplicitRecordRemoval(scenario: String) async throws {
        let fixture = try Fixture(mount: true)
        defer { fixture.remove() }
        let retained = fixture.root.appendingPathComponent("HandledInFinder")
        switch scenario {
        case "deleted": try FileManager.default.removeItem(at: fixture.candidate)
        case "moved": try FileManager.default.moveItem(at: fixture.candidate, to: retained)
        default:
            try FileManager.default.moveItem(at: fixture.external, to: retained)
            if scenario == "replaced-parent" {
                try FileManager.default.createDirectory(at: fixture.external, withIntermediateDirectories: false)
            }
        }
        let bytes = try Data(contentsOf: fixture.ledger)
        let reopened = ContainerMountStore(fileURL: fixture.ledger)
        let service = DataTransferMaterialService(store: reopened)
        #expect(try await service.recheckPreservedMaterial(id: fixture.material.id) == .absenceUnverified)
        #expect(try Data(contentsOf: fixture.ledger) == bytes)
        #expect(try reopened.preservedMaterials() == [fixture.material])
        #expect(try await service.removePreservedMaterialRecord(id: fixture.material.id,
            confirmation: .keepAllFilesAndVolumes) == .recordRemoved)
        if scenario != "deleted" {
            let payload = scenario == "moved" ? retained.appendingPathComponent("payload") : retained.appendingPathComponent("Candidate/payload")
            #expect(try String(contentsOf: payload, encoding: .utf8) == "unknown material")
        }
        #expect(try String(contentsOf: fixture.source.appendingPathComponent("payload"), encoding: .utf8) == "authoritative source")
    }

    @Test("A directory read failure never finishes the preserved record", .enabled(if: geteuid() != 0))
    func inaccessibleParentDoesNotProveAbsence() async throws {
        let fixture = try Fixture()
        defer { _ = chmod(fixture.external.path, 0o700); fixture.remove() }
        let bytes = try Data(contentsOf: fixture.ledger)
        try #require(chmod(fixture.external.path, 0o000) == 0)
        let service = DataTransferMaterialService(store: fixture.store)
        await #expect(throws: DataOperationSafety.Failure.self) {
            try await service.recheckPreservedMaterial(id: fixture.material.id)
        }
        #expect(try Data(contentsOf: fixture.ledger) == bytes)
        #expect(try fixture.store.preservedMaterials() == [fixture.material])
    }

    @Test("A replaced parent that is not a directory is an inspection error")
    func nonDirectoryParentDoesNotProveAbsence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let retained = fixture.root.appendingPathComponent("RetainedParent")
        try FileManager.default.moveItem(at: fixture.external, to: retained)
        try Data("unrelated replacement".utf8).write(to: fixture.external)
        let bytes = try Data(contentsOf: fixture.ledger)
        await #expect(throws: DataOperationSafety.Failure.self) {
            try await DataTransferMaterialService(store: fixture.store).recheckPreservedMaterial(id: fixture.material.id)
        }
        #expect(try Data(contentsOf: fixture.ledger) == bytes)
        #expect(try String(contentsOf: retained.appendingPathComponent("Candidate/payload"), encoding: .utf8) == "unknown material")
        #expect(try String(contentsOf: fixture.external, encoding: .utf8) == "unrelated replacement")
    }

    @Test("Failed summary saves preserve the old ledger and all physical material")
    func failedRemovalSaveIsRetryable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bytes = try Data(contentsOf: fixture.ledger)
        let failing = ContainerMountStore(fileURL: fixture.ledger, writeData: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        await #expect(throws: (any Error).self) {
            try await DataTransferMaterialService(store: failing).removePreservedMaterialRecord(id: fixture.material.id,
                confirmation: .keepAllFilesAndVolumes)
        }
        #expect(try Data(contentsOf: fixture.ledger) == bytes)
        #expect(try fixture.store.preservedMaterials() == [fixture.material])
        #expect(try String(contentsOf: fixture.candidate.appendingPathComponent("payload"), encoding: .utf8) == "unknown material")
        #expect(try await DataTransferMaterialService(store: fixture.store).removePreservedMaterialRecord(id: fixture.material.id,
            confirmation: .keepAllFilesAndVolumes) == .recordRemoved)
    }

    @Test("A stale material value cannot remove a newer summary with the same operation ID")
    func storeRequiresExactSummary() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.store.beginTransfer(fixture.transfer)
        try fixture.store.endUnswitchedTransfer(fixture.transfer, preserving: "newer summary") { }
        let newer = try #require(try fixture.store.preservedMaterial(id: fixture.material.id))
        #expect(newer != fixture.material)
        let bytes = try Data(contentsOf: fixture.ledger)
        #expect(throws: ContainerMountStore.StoreError.self) { try fixture.store.removePreservedMaterialRecord(fixture.material) }
        #expect(try Data(contentsOf: fixture.ledger) == bytes)
        #expect(try fixture.store.preservedMaterials() == [newer])
    }

    @Test("Corrupt records cannot be discarded through an old material row")
    func corruptLedgerCannotBeDismissed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let corrupt = Data("unreadable record contents".utf8)
        try corrupt.write(to: fixture.ledger)
        let service = DataTransferMaterialService(store: fixture.store)
        await #expect(throws: ContainerMountStore.StoreError.self) {
            try await service.removePreservedMaterialRecord(id: fixture.material.id, confirmation: .keepAllFilesAndVolumes)
        }
        #expect(try Data(contentsOf: fixture.ledger) == corrupt)
        #expect(try String(contentsOf: fixture.candidate.appendingPathComponent("payload"), encoding: .utf8) == "unknown material")
    }

    private struct Fixture {
        let root: URL
        let external: URL
        let source: URL
        let candidate: URL
        let ledger: URL
        let store: ContainerMountStore
        let transfer: DataTransferRecord
        let material: DataTransferMaterial

        init(mount: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsMaterials-\(UUID())").resolvingSymlinksInPath()
            external = root.appendingPathComponent("External")
            source = root.appendingPathComponent("Local/Data")
            candidate = external.appendingPathComponent("Candidate")
            ledger = root.appendingPathComponent("records.plist")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
            try Data("authoritative source".utf8).write(to: source.appendingPathComponent("payload"))
            try Data("unknown material".utf8).write(to: candidate.appendingPathComponent("payload"))
            store = ContainerMountStore(fileURL: ledger)
            var value = DataTransferRecord(mode: mount ? .mount : .symlink, direction: .migrate, appName: "Fixture",
                dataDirType: "custom", originalPath: source.path, activePath: source.path,
                destinationPath: mount ? source.path : external.appendingPathComponent("Final").path,
                backupPath: source.deletingLastPathComponent().appendingPathComponent("UnusedBackup").path,
                stagingPath: mount ? candidate.path : nil, sourceIdentity: try DataPathIdentity.capture(source),
                createdVolumeUUID: mount ? UUID().uuidString : nil)
            value.preparationPath = candidate.path
            if mount {
                value.volumeCreationContainerUUID = UUID().uuidString
                value.volumeCreationName = "Unclaimed private fixture volume"
            }
            transfer = value
            try store.beginTransfer(transfer)
            try store.endUnswitchedTransfer(transfer, preserving: "user kept unknown material") { }
            material = try #require(try store.preservedMaterial(id: transfer.operationID))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
