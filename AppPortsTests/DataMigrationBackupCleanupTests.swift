import Foundation
import Testing
@testable import AppPorts

/// Regression for the removed migration → full backup → signing coupling.
/// The historical materials are deliberately unrelated to the transferred data.
struct DataMigrationBackupCleanupTests {
    @Test("Data round trips do not create, rewrite or delete signing materials", arguments: [false, true])
    func historyIndependentOfDataCompletion(existingHistory: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MigrationNoSigning-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Home")
        let local = home.appendingPathComponent("Payload")
        let external = root.appendingPathComponent("External")
        let history = home.appendingPathComponent("Library/Application Support/AppPorts/signature-backups")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let bytes = Data("User data".utf8)
        try bytes.write(to: local.appendingPathComponent("data"))
        if existingHistory {
            try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
            try Data("Unrelated historical original".utf8).write(to: history.appendingPathComponent("historical-material"))
        }
        let before = existingHistory ? try TreeCopySession.snapshot(at: history) : nil
        let store = ContainerMountStore(fileURL: root.appendingPathComponent("records.plist"))
        let mover = DataDirMover(homeDir: home, store: store)
        let item = DataDirItem(name: "Payload", path: local, type: .applicationSupport, priority: .critical, description: "Fixture data", status: DataDirStatus.local, sizeBytes: Int64(bytes.count))
        let migrated = try await DataMigrationWorkflow.run {
            try await mover.migrateAndComplete(item: item, to: external, progressHandler: nil)
        }
        #expect(migrated.cleanupWarning == nil)
        try Data("New active content".utf8).write(to: local.appendingPathComponent("new"))
        let restored = try await mover.restoreAndComplete(item: item, progressHandler: nil)
        #expect(restored.cleanupWarning == nil)
        #expect(try Data(contentsOf: local.appendingPathComponent("data")) == bytes)
        #expect(try String(contentsOf: local.appendingPathComponent("new"), encoding: .utf8) == "New active content")
        #expect(try store.transfers().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: external.appendingPathComponent("Payload").path))
        if let before { #expect(try TreeCopySession.snapshot(at: history) == before) }
        else { #expect(!FileManager.default.fileExists(atPath: history.path)) }
    }
}
