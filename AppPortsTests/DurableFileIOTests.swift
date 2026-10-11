import Darwin
import Foundation
import Testing
@testable import AppPorts

struct DurableFileIOTests {
    @Test("Durable record replacement and tree barriers preserve ordinary files, links and metadata")
    func recordsAndTrees() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = root.appendingPathComponent("record.plist")
        try DurableFileIO.write(Data("first".utf8), to: record)
        try DurableFileIO.write(Data("second".utf8), to: record)
        #expect(try Data(contentsOf: record) == Data("second".utf8))
        let tree = root.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
        try Data("payload".utf8).write(to: tree.appendingPathComponent("data"))
        try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("link").path, withDestinationPath: "data")
        #expect(chmod(tree.path, 0o750) == 0)
        let before = try TreeCopySession.snapshot(at: tree)
        try DurableFileIO.syncTree(at: tree)
        #expect(try TreeCopySession.snapshot(at: tree) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".appports-write-") })
    }

    @Test("A durable writer rejects a symlink or non-regular record without touching its target", arguments: ["symlink", "directory", "fifo", "parent-link"])
    func refusesUnanchoredRecords(kind: String) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let victim = root.appendingPathComponent("victim")
        try Data("keep".utf8).write(to: victim)
        var record = root.appendingPathComponent("record")
        switch kind {
        case "symlink": try FileManager.default.createSymbolicLink(at: record, withDestinationURL: victim)
        case "directory": try FileManager.default.createDirectory(at: record, withIntermediateDirectories: false)
        case "fifo": #expect(mkfifo(record.path, 0o600) == 0)
        default:
            let parent = root.appendingPathComponent("linked-parent")
            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: root)
            record = parent.appendingPathComponent("victim")
        }
        #expect(throws: (any Error).self) { try DurableFileIO.write(Data("replace".utf8), to: record) }
        #expect(try Data(contentsOf: victim) == Data("keep".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".appports-write-") })
    }

    @Test("Unsupported tree nodes propagate synchronization failure and leave payload intact")
    func unsupportedNodeFails() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = root.appendingPathComponent("payload")
        try Data("keep".utf8).write(to: payload)
        let fifo = root.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try DurableFileIO.syncTree(at: root) }
        #expect(try Data(contentsOf: payload) == Data("keep".utf8))
        #expect(FileManager.default.fileExists(atPath: fifo.path))
    }

    @Test("Configured parent aliases require explicit anchoring and tree roots never follow links")
    func parentAliasRequiresOptIn() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("actual")
        let tree = actual.appendingPathComponent("tree")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: tree.appendingPathComponent("payload"))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let baseline = try TreeCopySession.snapshot(at: tree)
        #expect(throws: (any Error).self) { try DurableFileIO.syncDirectory(at: alias) }
        #expect(throws: (any Error).self) { try DurableFileIO.syncTree(at: alias.appendingPathComponent("tree")) }
        try DurableFileIO.syncDirectory(at: alias, resolvingAlias: true)
        try DurableFileIO.syncTree(at: alias.appendingPathComponent("tree"), allowParentAlias: true)
        #expect(throws: (any Error).self) { try DurableFileIO.syncTree(at: alias, allowParentAlias: true) }
        #expect(try TreeCopySession.snapshot(at: tree) == baseline)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path) == actual.path)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsDurability-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
