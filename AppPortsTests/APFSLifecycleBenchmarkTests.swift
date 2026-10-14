import CryptoKit
import Foundation
import XCTest
@testable import AppPorts

/// Invoked only by benchmark_apfs_lifecycle.py with a newly owned image.
/// The same source is compiled against v1.9.0 and the current implementation.
final class APFSLifecycleBenchmarkTests: XCTestCase {
    func testIsolatedLifecycleBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let dataset = environment["APPPORTS_BENCHMARK_DATASET"], ["small", "large"].contains(dataset) else {
            throw XCTSkip("Requires an explicitly prepared benchmark fixture")
        }
        let fixture = try RealMountFixture()
        let runner = PrivateImageDiskRunner(fixture: fixture)
        let disk = DiskUtility(runner: runner, commandTimeout: 90, administratorRunner: nil)
        let source = fixture.home.appendingPathComponent("Library/Containers/org.appports.synthetic.mount/Data/Documents/Business")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let count = Int(environment["APPPORTS_BENCHMARK_FILE_COUNT"] ?? "") ?? (dataset == "small" ? 20_000 : 4)
        let fileBytes = dataset == "small" ? 4096 : 128 * 1024 * 1024
        try createDataset(at: source, count: count, bytes: fileBytes)
        let original = try contents(at: source) // identical warm-source policy for both versions
        let store = ContainerMountStore(fileURL: fixture.root.appendingPathComponent("benchmark-records.plist"))
        #if APPPORTS_BASELINE
        let migrator = ContainerVolumeMigrator(disk: disk, store: store,
            stagingMountRootURL: fixture.privateMounts, synchronizeAgent: { _ in })
        let revision = "v1.9.0-ef823d1"
        #else
        let migrator = ContainerVolumeMigrator(disk: disk, store: store,
            stagingMountRootURL: fixture.privateMounts, synchronizeAgent: { _ in }, homeDirectory: fixture.home)
        let revision = "codex/apfs-complete-lifecycle"
        #endif
        let item = DataDirItem(name: "Business", path: source, type: .containers, priority: .recommended,
            description: "Independent APFS lifecycle benchmark")
        let migrationSession = DataTransferSession()
        let migrationStarted = ProcessInfo.processInfo.systemUptime
        let result = try await DataTransferSession.$current.withValue(migrationSession) {
            try await DataTransferSession.measure(.preparation) {
                #if APPPORTS_BASELINE
                return try await migrator.migrate(item: item, externalRootURL: fixture.external,
                    appName: "Synthetic Mount", bundleIdentifier: "org.appports.synthetic.mount", progressHandler: nil)
                #else
                return try await migrator.migrateAndComplete(item: item, externalRootURL: fixture.external,
                    appName: "Synthetic Mount", bundleIdentifier: "org.appports.synthetic.mount", progressHandler: nil)
                #endif
            }
        }
        var migration = migrationSession.measurements
        migration["total"] = ProcessInfo.processInfo.systemUptime - migrationStarted
        try requireRealMount(result.cleanupWarning == nil, result.cleanupWarning?.message ?? "Migration did not finish cleanup")
        try requireRealMount(DiskUtility.isMountPoint(source), "Migration did not activate the original path")
        try requireRealMount(try contents(at: source) == original, "Migrated file names or bytes changed")

        // Simulate application use through its unchanged data path. Both an
        // existing file and a newly created document must survive restoration.
        let first = source.appendingPathComponent("bucket-0/file-0")
        let file = try FileHandle(forWritingTo: first)
        try file.seekToEnd()
        try file.write(contentsOf: Data("latest application write".utf8))
        try file.synchronize()
        try file.close()
        try Data("new application document".utf8).write(to: source.appendingPathComponent("new-document"))
        let current = try contents(at: source)
        // APFS shares capacity across volumes. statfs on the unchanged base
        // volume can retain an old free-space value after another volume is
        // deleted; query the verified container itself outside the timed work.
        let availableBeforeRestore = try await runner.inventory().freeBytes
        let restoreSession = DataTransferSession()
        let restoreStarted = ProcessInfo.processInfo.systemUptime
        let warning = try await DataTransferSession.$current.withValue(restoreSession) {
            try await DataTransferSession.measure(.preparation) {
                #if APPPORTS_BASELINE
                return try await migrator.restore(record: result.record, estimatedTotalBytes: Int64(count * fileBytes), progressHandler: nil)
                #else
                return try await migrator.restoreAndComplete(record: result.record, estimatedTotalBytes: Int64(count * fileBytes), progressHandler: nil)
                #endif
            }
        }
        var restore = restoreSession.measurements
        restore["total"] = ProcessInfo.processInfo.systemUptime - restoreStarted
        try requireRealMount(warning == nil, warning?.message ?? "Restoration did not finish cleanup")
        try requireRealMount(!DiskUtility.isMountPoint(source), "Restoration did not return a local directory")
        try requireRealMount(try contents(at: source) == current, "Restoration lost current application data")
        let finalInventory = try await runner.inventory()
        try requireRealMount(finalInventory.volumes.count == 1, "The unused data volume was not deleted")
        try requireRealMount(try store.pendingCleanups().isEmpty, "A legacy cleanup remains")
        #if APPPORTS_BASELINE
        try requireRealMount(store.records().isEmpty, "A legacy mount remains")
        #else
        try requireRealMount(try store.recordsStrict().isEmpty && store.transfers().isEmpty && store.preservedMaterials().isEmpty,
            "The full operation did not finish")
        #endif
        try requireRealMount(try FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path) == ["Business"],
            "A local temporary or retained copy remains")
        let reclaimed = finalInventory.freeBytes - availableBeforeRestore
        let storage: [String: Any] = ["source": "diskutil apfs list CapacityFree of the verified private container",
            "beforeRestoreBytes": availableBeforeRestore, "afterRestoreBytes": finalInventory.freeBytes,
            "reclaimedBytes": reclaimed]
        try DurableFileIO.write(JSONSerialization.data(withJSONObject: storage, options: [.prettyPrinted, .sortedKeys]),
            to: fixture.root.appendingPathComponent("benchmark-storage.json"))
        try requireRealMount(reclaimed > Int64(count * fileBytes / 2),
            "The owned APFS container did not reclaim the restored dataset's storage")
        let report: [String: Any] = ["status": "passed", "nonce": fixture.record.nonce, "revision": revision,
            "dataset": dataset, "files": count, "fileBytes": fileBytes, "logicalBytes": count * fileBytes,
            "cachePolicy": "fresh deterministic dataset, one complete source read before migration and restore",
            "migration": migration, "restore": restore, "currentDataRestored": true, "cleanupComplete": true,
            "restorationReclaimedAPFSBytes": reclaimed, "storageAccounting": storage,
            "localTemporaryEntriesRemaining": 0]
        try DurableFileIO.write(JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
            to: fixture.root.appendingPathComponent("benchmark-result.json"))
    }

    private func createDataset(at root: URL, count: Int, bytes: Int) throws {
        let chunk = Data((0..<min(bytes, 1_048_576)).map { UInt8(truncatingIfNeeded: $0 &* 73 &+ 19) })
        for index in 0..<count {
            let directory = root.appendingPathComponent("bucket-\(index / 100)")
            if index % 100 == 0 { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
            let url = directory.appendingPathComponent("file-\(index)")
            try requireRealMount(FileManager.default.createFile(atPath: url.path, contents: nil), "Cannot create independent dataset")
            let file = try FileHandle(forWritingTo: url)
            var remaining = bytes
            while remaining > 0 {
                let size = min(remaining, chunk.count)
                try file.write(contentsOf: chunk.prefix(size))
                remaining -= size
            }
            try file.close()
        }
    }

    private func contents(at root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where directory.lastPathComponent.hasPrefix("bucket-") {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                result[directory.lastPathComponent + "/" + url.lastPathComponent] = try digest(url)
            }
        }
        let created = root.appendingPathComponent("new-document")
        if FileManager.default.fileExists(atPath: created.path) { result[created.lastPathComponent] = try digest(created) }
        return result
    }

    private func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
