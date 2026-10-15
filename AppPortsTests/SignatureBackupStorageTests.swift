import Foundation
import Testing
@testable import AppPorts

@Suite("External signature backup storage")
struct SignatureBackupStorageTests {
    @Test("Selection prefers the app's external volume, then the migration volume, then capacity")
    func automaticOrder() {
        func volume(_ id: String, _ bytes: Int64, writable: Bool = true, external: Bool = true,
                    local: Bool = true, physical: Bool = true) -> SignatureBackupStorage.Volume {
            .init(url: URL(fileURLWithPath: "/Volumes/" + id), uuid: id, availableBytes: bytes,
                  isExternal: external, isLocal: local, isWritable: writable, isPhysical: physical)
        }
        let volumes = [volume("internal", 10_000, external: false), volume("readonly", 10_000, writable: false),
                       volume("network", 10_000, local: false), volume("image", 10_000, physical: false),
                       volume("full", 1), volume("roomiest", 9_000), volume("other", 500),
                       volume("migration", 200), volume("app", 100)]
        #expect(SignatureBackupStorage.candidates(volumes, applicationVolume: "APP", knownVolume: "migration", requiredBytes: 100)
            .map(\.uuid) == ["app", "migration", "roomiest", "other"])
        #expect(SignatureBackupStorage.candidates(volumes, applicationVolume: "internal", knownVolume: "readonly", requiredBytes: 300)
            .map(\.uuid) == ["roomiest", "other"])
        #expect(SignatureBackupStorage.candidates(volumes, applicationVolume: nil, knownVolume: nil, requiredBytes: 20_000).isEmpty)
    }

    @Test("Visible backup folder explains recovery and preserves the user's edited explanation")
    func explanation() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent(SignatureBackupStorage.directoryName)
        let location = try SignatureBackupStorage.prepareDirectory(folder)
        try SignatureBackupStorage.writeExplanation(in: folder)
        let readme = folder.appendingPathComponent("README.txt")
        let contents = try String(contentsOf: readme, encoding: .utf8)
        #expect(!folder.lastPathComponent.hasPrefix("."))
        #expect(contents.contains("恢复原始签名") && contents.contains("Finder"))
        #expect(try location.resolve().path == folder.path)
        try Data("owner's explanation".utf8).write(to: readme)
        try SignatureBackupStorage.writeExplanation(in: folder)
        #expect(try String(contentsOf: readme, encoding: .utf8) == "owner's explanation")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["README.txt"])
    }

    @Test("A changed mount name resolves by volume and directory identity, including a volume-root parent", arguments: [false, true])
    func remountedLocation(volumeRoot: Bool) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldMount = root.appendingPathComponent("OldMount")
        let newMount = root.appendingPathComponent("NewMount")
        let directory = volumeRoot ? oldMount : oldMount.appendingPathComponent("AppPorts Backups")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let location = try SignatureDirectoryLocation.capture(directory, volumeRoot: oldMount)
        try FileManager.default.moveItem(at: oldMount, to: newMount)
        #expect(try location.resolve(mountedVolumes: [newMount]).path == (volumeRoot ? newMount : newMount.appendingPathComponent("AppPorts Backups")).path)
    }

    @Test("A same-name replacement directory or symlink cannot inherit a saved location", arguments: [false, true])
    func rejectsSubstitution(symlink: Bool) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("AppPorts Backups")
        let location = try SignatureBackupStorage.prepareDirectory(folder)
        let saved = root.appendingPathComponent("Saved")
        try FileManager.default.moveItem(at: folder, to: saved)
        if symlink { try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: saved) }
        else { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
        #expect(throws: (any Error).self) { try location.resolve(mountedVolumes: []) }
    }

    @Test("Location records reject traversal and a different volume UUID")
    func malformedLocation() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let location = try SignatureDirectoryLocation.capture(root)
        let traversal = SignatureDirectoryLocation(path: location.path, volumeUUID: location.volumeUUID,
            relativePath: "../other", identity: location.identity)
        let wrongVolume = SignatureDirectoryLocation(path: location.path, volumeUUID: UUID().uuidString,
            relativePath: location.relativePath, identity: location.identity)
        #expect(throws: (any Error).self) { try traversal.resolve(mountedVolumes: []) }
        #expect(throws: (any Error).self) { try wrongVolume.resolve(mountedVolumes: []) }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsBackupStorage-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
