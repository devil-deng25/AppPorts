import Darwin
import Foundation
import Testing
@testable import AppPorts

struct DataTransferOwnershipSchemaTests {
    @Test("Ownership compatibility survives reopen and prevents an older writer from acting", arguments: [false, true])
    func compatibilityRequiresSchemaFive(sourceIgnoresOwnership: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var transfer = try fixture.persist()
        #expect(try fixture.document()["schemaVersion"] as? Int == 3)
        let baseline = try fixture.baseline(sourceIgnoresOwnership: sourceIgnoresOwnership)
        transfer.baseline = try PropertyListEncoder().encode(baseline)
        transfer.destinationIdentity = transfer.sourceIdentity
        transfer.phase = .verified
        try fixture.store.updateTransfer(transfer)
        #expect(try fixture.document()["schemaVersion"] as? Int == 5)
        let reopened = try #require(try ContainerMountStore(fileURL: fixture.file).transfer(operationID: transfer.operationID))
        #expect(reopened == transfer)
        #expect(try PropertyListDecoder().decode(TreeCopySnapshot.self, from: #require(reopened.baseline)) == baseline)
        #expect(throws: ContainerMountStore.StoreError.self) {
            try PropertyListDecoder().decode(SchemaFourReader.self, from: Data(contentsOf: fixture.file))
        }
    }

    @Test("Earlier documents with a compatibility contract are promoted atomically on their next write", arguments: [3, 4])
    func olderDocumentIsPromoted(schema: Int) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var transfer = try fixture.persist()
        transfer.baseline = try PropertyListEncoder().encode(fixture.baseline(sourceIgnoresOwnership: false))
        try fixture.store.updateTransfer(transfer)
        var object = try fixture.document()
        object["schemaVersion"] = schema
        let bytes = try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
        try bytes.write(to: fixture.file)
        let reopened = ContainerMountStore(fileURL: fixture.file)
        #expect(try reopened.transfer(operationID: transfer.operationID) == transfer)
        #expect(try Data(contentsOf: fixture.file) == bytes)
        let failing = ContainerMountStore(fileURL: fixture.file, writeData: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        #expect(throws: (any Error).self) { try failing.updateTransfer(transfer) }
        #expect(try Data(contentsOf: fixture.file) == bytes)
        try reopened.updateTransfer(transfer)
        #expect(try fixture.document()["schemaVersion"] as? Int == 5)
        #expect(try reopened.transfer(operationID: transfer.operationID) == transfer)
    }

    @Test("A malformed explicit ownership contract is rejected without losing the record", arguments: ["wrongType", "missingField"])
    func malformedCompatibilityIsNotDropped(kind: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var transfer = try fixture.persist()
        let before = try Data(contentsOf: fixture.file)
        let compatibility: Any = kind == "wrongType" ? "invalid" : ["sourceIgnoresOwnership": true]
        transfer.baseline = try PropertyListSerialization.data(fromPropertyList: ["ownershipCompatibility": compatibility], format: .binary, options: 0)
        #expect(throws: ContainerMountStore.StoreError.self) { try fixture.store.updateTransfer(transfer) }
        #expect(try Data(contentsOf: fixture.file) == before)

        var object = try fixture.document()
        var transfers = try #require(object["transfers"] as? [[String: Any]])
        transfers[0]["baseline"] = transfer.baseline
        object["transfers"] = transfers
        let malformed = try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
        try malformed.write(to: fixture.file)
        #expect(throws: ContainerMountStore.StoreError.self) { try fixture.store.transfers() }
        #expect(try Data(contentsOf: fixture.file) == malformed)
    }

    @Test("Ordinary and historical opaque baselines retain their existing schema", arguments: [false, true])
    func strictOrOpaqueBaselineKeepsOldSchema(opaque: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var transfer = try fixture.persist()
        transfer.baseline = opaque ? Data("historical opaque baseline".utf8)
            : try PropertyListEncoder().encode(TreeCopySession.snapshot(at: fixture.source))
        try fixture.store.updateTransfer(transfer)
        #expect(try fixture.document()["schemaVersion"] as? Int == 3)
        #expect(try ContainerMountStore(fileURL: fixture.file).transfer(operationID: transfer.operationID) == transfer)
    }

    private struct SchemaFourReader: Decodable {
        enum Keys: String, CodingKey { case schemaVersion }
        init(from decoder: Decoder) throws {
            let schema = try decoder.container(keyedBy: Keys.self).decode(Int.self, forKey: .schemaVersion)
            guard (2...4).contains(schema) else { throw ContainerMountStore.StoreError.unsupportedSchema(schema) }
        }
    }

    private struct Fixture {
        let root: URL
        let source: URL
        let file: URL
        let store: ContainerMountStore

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("DataTransferOwnershipSchema-\(UUID())")
            source = root.appendingPathComponent("Source")
            file = root.appendingPathComponent("records.plist")
            store = ContainerMountStore(fileURL: file)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("original".utf8).write(to: source.appendingPathComponent("payload.txt"))
        }

        func persist() throws -> DataTransferRecord {
            var transfer = DataTransferRecord(mode: .symlink, direction: .migrate,
                appName: "Fixture", dataDirType: DataDirType.custom.rawValue,
                originalPath: source.path, activePath: source.path,
                destinationPath: root.appendingPathComponent("External/Source").path,
                sourceIdentity: try DataPathIdentity.capture(source))
            try store.beginTransfer(transfer)
            transfer.phase = .copying
            try store.updateTransfer(transfer)
            return transfer
        }

        func baseline(sourceIgnoresOwnership: Bool) throws -> TreeCopySnapshot {
            var baseline = try TreeCopySession.snapshot(at: source)
            baseline.ownershipCompatibility = .init(sourceIgnoresOwnership: sourceIgnoresOwnership,
                destinationIgnoresOwnership: !sourceIgnoresOwnership,
                projectedSourceOwner: sourceIgnoresOwnership ? .init(uid: geteuid(), gid: getegid()) : nil)
            return baseline
        }

        func document() throws -> [String: Any] {
            try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
