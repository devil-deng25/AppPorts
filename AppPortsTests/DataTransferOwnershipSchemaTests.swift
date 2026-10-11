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

    @Test("Every resource-fork baseline upgrades atomically before a schema-seven reader can act",
          arguments: ["baseline", "sourceBaseline", "preparationRemovalBaseline"])
    func resourceForkRequiresSchemaEight(field: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var transfer = try fixture.persist()
        let forkBaseline = try fixture.forkBaseline()
        if field == "baseline" {
            transfer.baseline = forkBaseline
        } else {
            transfer.preparationPath = fixture.root.appendingPathComponent("Candidate").path
            transfer.preparationParentIdentity = try DataPathIdentity.capture(fixture.root)
            transfer.sourceBaseline = field == "sourceBaseline" ? forkBaseline
                : try PropertyListEncoder().encode(TreeCopySession.snapshot(at: fixture.source))
            if field == "preparationRemovalBaseline" {
                transfer.destinationIdentity = transfer.sourceIdentity
                transfer.preparationRemovalParentIdentity = transfer.preparationParentIdentity
                transfer.preparationRemovalBaseline = forkBaseline
            }
        }
        let before = try Data(contentsOf: fixture.file)
        let failing = ContainerMountStore(fileURL: fixture.file, writeData: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        #expect(throws: (any Error).self) { try failing.updateTransfer(transfer) }
        #expect(try Data(contentsOf: fixture.file) == before)
        try fixture.store.updateTransfer(transfer)
        #expect(try fixture.document()["schemaVersion"] as? Int == 8)
        #expect(try ContainerMountStore(fileURL: fixture.file).transfer(operationID: transfer.operationID) == transfer)
        #expect(throws: ContainerMountStore.StoreError.self) {
            try PropertyListDecoder().decode(SchemaSevenReader.self, from: Data(contentsOf: fixture.file))
        }
    }

    @Test("A legacy raw resource fork stays readable and its next write protects the normalized format")
    func legacyResourceForkIsPromotedOnWrite() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var transfer = try fixture.persist()
        let rawBaseline = try fixture.forkBaseline(legacyRaw: true)
        transfer.baseline = rawBaseline
        var document = try fixture.document()
        var records = try #require(document["transfers"] as? [[String: Any]])
        records[0]["baseline"] = rawBaseline
        document["transfers"] = records
        document["schemaVersion"] = 3
        let legacyBytes = try PropertyListSerialization.data(fromPropertyList: document, format: .binary, options: 0)
        try legacyBytes.write(to: fixture.file)
        let reopened = ContainerMountStore(fileURL: fixture.file)
        #expect(try reopened.transfer(operationID: transfer.operationID) == transfer)
        #expect(try Data(contentsOf: fixture.file) == legacyBytes)
        let normalized = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: rawBaseline)
        #expect(normalized.entries.contains { $0.resourceFork != nil })
        #expect(normalized.entries.allSatisfy { $0.extendedAttributes["com.apple.ResourceFork"] == nil })
        try reopened.updateTransfer(transfer)
        #expect(try fixture.document()["schemaVersion"] as? Int == 8)
        // Schema promotion must not silently replace an immutable manifest.
        #expect(try reopened.transfer(operationID: transfer.operationID)?.baseline == rawBaseline)
        #expect(throws: ContainerMountStore.StoreError.self) {
            try PropertyListDecoder().decode(SchemaSevenReader.self, from: Data(contentsOf: fixture.file))
        }
    }

    @Test("Malformed explicit resource-fork metadata is not accepted as an opaque historical baseline",
          arguments: ["wrongType", "negativeSize", "shortDigest"])
    func malformedResourceForkIsNotDropped(kind: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var transfer = try fixture.persist()
        let before = try Data(contentsOf: fixture.file)
        var document = try #require(try PropertyListSerialization.propertyList(from: fixture.forkBaseline(), format: nil) as? [String: Any])
        var entries = try #require(document["entries"] as? [[String: Any]])
        let index = try #require(entries.firstIndex { $0["resourceFork"] != nil })
        if kind == "wrongType" { entries[index]["resourceFork"] = "invalid" }
        else {
            entries[index]["resourceFork"] = ["size": kind == "negativeSize" ? -1 : 42,
                "digest": Data(repeating: 3, count: kind == "shortDigest" ? 1 : 32)]
        }
        document["entries"] = entries
        transfer.baseline = try PropertyListSerialization.data(fromPropertyList: document, format: .binary, options: 0)
        #expect(throws: ContainerMountStore.StoreError.self) { try fixture.store.updateTransfer(transfer) }
        #expect(try Data(contentsOf: fixture.file) == before)
    }

    @Test("A successful validation never hides changed manifest bytes on a later disk read",
          arguments: ["ownershipCompatibility", "resourceFork", "sourceBaseline"])
    func cachedValidationDoesNotSurviveDiskRead(field: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var transfer = try fixture.persist()
        var snapshot = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: fixture.forkBaseline())
        snapshot.ownershipCompatibility = .init(sourceIgnoresOwnership: false,
            destinationIgnoresOwnership: true, projectedSourceOwner: nil)
        let baseline = try PropertyListEncoder().encode(snapshot)
        transfer.baseline = baseline
        transfer.sourceBaseline = baseline
        transfer.preparationPath = fixture.root.appendingPathComponent("Candidate").path
        transfer.preparationParentIdentity = try DataPathIdentity.capture(fixture.root)
        try fixture.store.updateTransfer(transfer)
        #expect(try fixture.store.transfer(operationID: transfer.operationID) == transfer)

        var changed = try #require(try PropertyListSerialization.propertyList(from: baseline, format: nil) as? [String: Any])
        if field == "ownershipCompatibility" { changed[field] = "invalid" }
        else {
            var entries = try #require(changed["entries"] as? [[String: Any]])
            let index = try #require(entries.firstIndex { $0["resourceFork"] != nil })
            if field == "resourceFork" { entries[index]["resourceFork"] = "invalid" }
            else { entries[index]["mode"] = "invalid" }
            changed["entries"] = entries
        }
        let changedBaseline = try PropertyListSerialization.data(fromPropertyList: changed, format: .binary, options: 0)
        var document = try fixture.document()
        var records = try #require(document["transfers"] as? [[String: Any]])
        records[0][field == "sourceBaseline" ? "sourceBaseline" : "baseline"] = changedBaseline
        document["transfers"] = records
        let changedBytes = try PropertyListSerialization.data(fromPropertyList: document, format: .binary, options: 0)
        try changedBytes.write(to: fixture.file)

        #expect(throws: ContainerMountStore.StoreError.self) { try fixture.store.transfers() }
        #expect(try fixture.store.recordsForInspection().validationError != nil)
        #expect(throws: ContainerMountStore.StoreError.self) { try fixture.store.updateTransfer(transfer) }
        #expect(try Data(contentsOf: fixture.file) == changedBytes)
    }

    @Test("Distinct baselines in one mutation cannot borrow the validated source's resource-fork result",
          arguments: ["baseline", "preparationRemovalBaseline"])
    func eachDistinctBaselineIsValidated(field: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var transfer = try fixture.persist()
        let baseline = try fixture.forkBaseline()
        transfer.sourceBaseline = baseline
        transfer.preparationPath = fixture.root.appendingPathComponent("Candidate").path
        transfer.preparationParentIdentity = try DataPathIdentity.capture(fixture.root)
        if field == "preparationRemovalBaseline" { transfer.baseline = baseline }
        try fixture.store.updateTransfer(transfer)
        let before = try Data(contentsOf: fixture.file)

        var changed = try #require(try PropertyListSerialization.propertyList(from: baseline, format: nil) as? [String: Any])
        var entries = try #require(changed["entries"] as? [[String: Any]])
        let index = try #require(entries.firstIndex { $0["resourceFork"] != nil })
        entries[index]["resourceFork"] = ["size": 4096, "digest": Data(repeating: 7, count: 1)]
        changed["entries"] = entries
        let badBaseline = try PropertyListSerialization.data(fromPropertyList: changed, format: .binary, options: 0)
        #expect(badBaseline != baseline)
        transfer.destinationIdentity = transfer.sourceIdentity
        if field == "baseline" {
            transfer.baseline = badBaseline
            transfer.phase = .verified
        } else {
            transfer.preparationRemovalBaseline = badBaseline
            transfer.preparationRemovalParentIdentity = transfer.preparationParentIdentity
        }
        #expect(throws: ContainerMountStore.StoreError.self) { try fixture.store.updateTransfer(transfer) }
        #expect(try Data(contentsOf: fixture.file) == before)
    }

    @Test("A valid first resource fork never hides a malformed later entry")
    func malformedResourceForkAfterValidEntryIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var transfer = try fixture.persist()
        let before = try Data(contentsOf: fixture.file)
        var document = try #require(try PropertyListSerialization.propertyList(from: fixture.forkBaseline(), format: nil) as? [String: Any])
        var entries = try #require(document["entries"] as? [[String: Any]])
        try #require(entries.count >= 2)
        entries[0]["resourceFork"] = ["size": 0, "digest": Data(repeating: 7, count: 32)]
        entries[entries.count - 1]["resourceFork"] = "invalid"
        document["entries"] = entries
        transfer.baseline = try PropertyListSerialization.data(fromPropertyList: document, format: .binary, options: 0)
        #expect(throws: ContainerMountStore.StoreError.self) { try fixture.store.updateTransfer(transfer) }
        #expect(try Data(contentsOf: fixture.file) == before)
    }

    private struct SchemaFourReader: Decodable {
        enum Keys: String, CodingKey { case schemaVersion }
        init(from decoder: Decoder) throws {
            let schema = try decoder.container(keyedBy: Keys.self).decode(Int.self, forKey: .schemaVersion)
            guard (2...4).contains(schema) else { throw ContainerMountStore.StoreError.unsupportedSchema(schema) }
        }
    }

    private struct SchemaSevenReader: Decodable {
        enum Keys: String, CodingKey { case schemaVersion }
        init(from decoder: Decoder) throws {
            let schema = try decoder.container(keyedBy: Keys.self).decode(Int.self, forKey: .schemaVersion)
            guard (2...7).contains(schema) else { throw ContainerMountStore.StoreError.unsupportedSchema(schema) }
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

        func forkBaseline(legacyRaw: Bool = false) throws -> Data {
            let encoded = try PropertyListEncoder().encode(TreeCopySession.snapshot(at: source))
            var document = try #require(try PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any])
            var entries = try #require(document["entries"] as? [[String: Any]])
            let index = try #require(entries.firstIndex { $0["kind"] as? String == "file" })
            if legacyRaw {
                var attributes = try #require(entries[index]["extendedAttributes"] as? [String: Data])
                attributes["com.apple.ResourceFork"] = Data("legacy resource fork".utf8)
                entries[index]["extendedAttributes"] = attributes
            } else {
                entries[index]["resourceFork"] = ["size": 4096, "digest": Data(repeating: 7, count: 32)]
            }
            document["entries"] = entries
            return try PropertyListSerialization.data(fromPropertyList: document, format: .binary, options: 0)
        }

        func document() throws -> [String: Any] {
            try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
