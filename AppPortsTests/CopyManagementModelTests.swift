import Foundation
import Testing
@testable import AppPorts

@MainActor
struct CopyManagementModelTests {
    @Test("A completed switch with pending cleanup remains visible and is not a failure")
    func completedSwitchKeepsActionableWarning() async throws {
        let state = AppOperationState(notificationCenter: NotificationCenter())
        let calls = Calls()
        let model = CopyManagementModel(dependencies: .init(load: {
            await calls.record("load")
            return .init(readErrors: ["An offline historical material is still listed"])
        }, execute: { _ in
            await calls.record("retry")
            return "Application restored; old copy still in use"
        }), operationState: state)
        await model.start(.resumeApp(UUID()))?.value
        #expect(!state.isBusy)
        #expect(model.errorMessage == nil)
        #expect(model.notice == "Application restored; old copy still in use")
        #expect(model.snapshot.readErrors.count == 1)
        #expect(await calls.values == ["retry", "load"])
    }

    @Test("Two windows cannot start the same destructive action concurrently")
    func sharedStateRejectsDuplicateClick() async throws {
        let state = AppOperationState(notificationCenter: NotificationCenter())
        let gate = Gate()
        let calls = Calls()
        let dependencies = CopyManagementModel.Dependencies(load: { .init() }, execute: { _ in
            await calls.record("action")
            await gate.wait()
            return nil
        })
        let first = CopyManagementModel(dependencies: dependencies, operationState: state)
        let second = CopyManagementModel(dependencies: dependencies, operationState: state)
        let job = try #require(first.start(.deleteSignature("material", moveToTrash: false)))
        #expect(second.start(.deleteSignature("material", moveToTrash: false)) == nil)
        await gate.open()
        await job.value
        #expect(await calls.values == ["action"])
        #expect(!state.isBusy)
    }

    @Test("A failed action reloads current durable state and releases the operation")
    func failureDoesNotLeaveBusyUI() async {
        let state = AppOperationState(notificationCenter: NotificationCenter())
        let calls = Calls()
        let model = CopyManagementModel(dependencies: .init(load: {
            await calls.record("reload")
            return .init(readErrors: ["Material preserved"])
        }, execute: { _ in throw CocoaError(.fileWriteNoPermission) }), operationState: state)
        await model.start(.cancelSignature("operation"))?.value
        #expect(!state.isBusy)
        #expect(model.errorMessage != nil)
        #expect(model.snapshot.readErrors == ["Material preserved"])
        #expect(await calls.values == ["reload"])
        #expect(state.recordsRevision == 1)
    }

    @Test("Closing a window does not discard the in-flight operation")
    func operationSurvivesViewModelRelease() async throws {
        let state = AppOperationState(notificationCenter: NotificationCenter())
        let gate = Gate()
        var model: CopyManagementModel? = CopyManagementModel(dependencies: .init(load: { .init() }, execute: { _ in
            await gate.wait()
            return nil
        }), operationState: state)
        let job = try #require(model?.start(.resumeSignature("operation")))
        model = nil
        #expect(state.isBusy)
        await gate.open()
        await job.value
        #expect(!state.isBusy)
    }

    @Test("A material-only snapshot is nonempty even when there are no data rows")
    func historicalMaterialWithoutDataIsVisible() {
        let material = SignatureMaterial(id: "history", kind: .orphanSnapshot,
            url: URL(fileURLWithPath: "/fixture/original.app"), appURL: nil, appName: "Original", bundleIdentifier: nil,
            sizeBytes: 1234, detail: "Historical original", canResume: false, canCancel: false, canRestore: false, canDelete: true)
        let snapshot = CopyManagementModel.Snapshot(signatureMaterials: [material])
        #expect(!snapshot.isEmpty)
        #expect(snapshot.dataGroups.isEmpty)
    }

    @Test("A damaged application record remains visible when every valid transfer is complete")
    func damagedApplicationRecordIsNotAnEmptySnapshot() {
        let issue = AppTransferRecordIssue(url: URL(fileURLWithPath: "/fixture/record.plist"),
            appName: "Unfinished application", message: "Record is unreadable", knownPaths: ["/fixture/App.app"])
        let snapshot = CopyManagementModel.Snapshot(appTransferIssues: [issue])
        #expect(!snapshot.isEmpty)
        #expect(snapshot.appTransfers.isEmpty)
    }

    enum LegacyCleanupState: CaseIterable, Sendable {
        case complete, localMissing, stagingPresent, changedRecord
    }

    @Test("Legacy cleanup record removal preserves files and rejects incomplete or stale UI selections",
          arguments: LegacyCleanupState.allCases)
    func legacyCleanupRecordAction(state fixtureState: LegacyCleanupState) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LegacyCleanupAction-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("Restored")
        let retained = root.appendingPathComponent("Retained")
        let staging = root.appendingPathComponent("Staging")
        for path in [local, retained] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try Data(path.lastPathComponent.utf8).write(to: path.appendingPathComponent("document"))
        }
        let retainedBefore = try TreeCopySession.snapshot(at: retained)
        let localBefore = try TreeCopySession.snapshot(at: local)
        if fixtureState == .stagingPresent {
            try FileManager.default.createSymbolicLink(at: staging, withDestinationURL: root.appendingPathComponent("MissingStagingTarget"))
        }
        let mount = ContainerMountRecord(appName: "Synthetic", bundleIdentifier: nil, dataDirType: "custom",
            mountPointPath: local.path, volumeUUID: UUID().uuidString, volumeName: "Offline test volume",
            externalRootPath: root.appendingPathComponent("Offline").path)
        let selected = ContainerCleanupRecord(kind: .restoredVolume, mountRecord: mount, localPath: local.path,
            restoreStagingPath: fixtureState == .stagingPresent ? staging.path : nil)
        let store = ContainerMountStore(fileURL: root.appendingPathComponent("records.plist"))
        var current = selected
        if fixtureState == .changedRecord {
            var object = try #require(try PropertyListSerialization.propertyList(from: PropertyListEncoder().encode(selected), format: nil) as? [String: Any])
            object["localPath"] = retained.path
            current = try PropertyListDecoder().decode(ContainerCleanupRecord.self,
                from: PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0))
        }
        try store.beginRestore(current)
        let saved = root.appendingPathComponent("SavedRestored")
        if fixtureState == .localMissing { try FileManager.default.moveItem(at: local, to: saved) }
        let lock = OperationLock(fileURL: root.appendingPathComponent("operation.lock"))
        let state = AppOperationState(notificationCenter: NotificationCenter())
        let model = CopyManagementModel(dependencies: .init(load: {
            do { return .init(legacyCleanups: try store.pendingCleanups()) }
            catch { return .init(readErrors: [error.localizedDescription]) }
        }, execute: { action in
            try await CopyManagementModel.Dependencies.performDataAction(action, store: store, lock: lock)
        }), operationState: state)
        await model.start(.removeLegacyCleanupRecord(selected, confirmation: .keepAllFilesAndVolumes))?.value
        #expect(!state.isBusy)
        if fixtureState == .complete {
            #expect(model.errorMessage == nil)
            #expect(model.snapshot.isEmpty)
            #expect(try store.pendingCleanups().isEmpty)
            #expect(model.notice == "仅移除了记录。文件和卷均未更改，此操作没有释放存储空间。".localized)
        } else {
            #expect(model.errorMessage != nil)
            #expect(model.snapshot.legacyCleanups == [current])
            #expect(try store.pendingCleanups() == [current])
        }
        #expect(try TreeCopySession.snapshot(at: retained) == retainedBefore)
        #expect(try TreeCopySession.snapshot(at: fixtureState == .localMissing ? saved : local) == localBefore)
        if fixtureState == .stagingPresent {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: staging.path) == root.appendingPathComponent("MissingStagingTarget").path)
            #expect(model.errorMessage == "还原暂存仍存在，未移除恢复记录。请先检查暂存：".localized + staging.path)
        }
        if fixtureState == .localMissing {
            #expect(model.errorMessage == "未确认本地还原目录，未移除记录：".localized + local.path)
        }
    }

    @Test("The visible preserved-material actions use the real service and only remove its record")
    func preservedMaterialActionsRetainAllFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CopyMaterialActions-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source")
        let candidate = root.appendingPathComponent("Candidate")
        for directory in [source, candidate] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(directory.lastPathComponent.utf8).write(to: directory.appendingPathComponent("document"))
        }
        let sourceBefore = try TreeCopySession.snapshot(at: source)
        let candidateBefore = try TreeCopySession.snapshot(at: candidate)
        let store = ContainerMountStore(fileURL: root.appendingPathComponent("records.plist"))
        var record = DataTransferRecord(mode: .symlink, direction: .migrate, appName: "Fixture", dataDirType: "custom",
            originalPath: source.path, activePath: source.path, destinationPath: root.appendingPathComponent("Final").path,
            sourceIdentity: try DataPathIdentity.capture(source))
        record.preparationPath = candidate.path
        try store.beginTransfer(record)
        try store.endUnswitchedTransfer(record, preserving: "User kept the unknown copy") { }
        let id = record.operationID
        let lock = OperationLock(fileURL: root.appendingPathComponent("operation.lock"))
        let state = AppOperationState(notificationCenter: NotificationCenter())
        let model = CopyManagementModel(dependencies: .init(load: {
            do { return .init(dataMaterials: try store.preservedMaterials()) }
            catch { return .init(readErrors: [error.localizedDescription]) }
        }, execute: { action in
            try await CopyManagementModel.Dependencies.performDataAction(action, store: store, lock: lock)
        }), operationState: state)

        await model.start(.recheckDataMaterial(id))?.value
        #expect(model.snapshot.dataMaterials.count == 1)
        #expect(model.notice != nil)
        #expect(model.errorMessage == nil)
        #expect(!state.isBusy)
        await model.start(.removeDataMaterialRecord(id, confirmation: .keepAllFilesAndVolumes))?.value
        #expect(model.snapshot.isEmpty)
        #expect(model.errorMessage == nil)
        #expect(model.notice == "仅移除了记录。文件和卷均未更改，此操作没有释放存储空间。".localized)
        #expect(!state.isBusy)
        #expect(try TreeCopySession.snapshot(at: source) == sourceBefore)
        #expect(try TreeCopySession.snapshot(at: candidate) == candidateBefore)
    }

    private actor Calls {
        var values: [String] = []
        func record(_ value: String) { values.append(value) }
    }
    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            opened = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }
}
