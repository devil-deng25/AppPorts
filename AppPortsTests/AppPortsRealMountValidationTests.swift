import Darwin
import Foundation
import XCTest
@testable import AppPorts

/// The coordinator creates the image. Ordinary regression runs skip this test.
/// All disk commands are real, but their mutation authority is restricted to
/// freshly created volumes in that exact private image's APFS container.
final class AppPortsRealMountValidationTests: XCTestCase {
    func testPrivateAPFSMountMigrationAndRestore() async throws {
        let fixture = try RealMountFixture()
        let runner = PrivateImageDiskRunner(fixture: fixture)
        do {
            let initial = try await runner.inventory()
            try requireRealMount(Set(initial.volumes.map(\.uuid)) == [fixture.record.initialVolumeUUID.uppercased()],
                                 "The private image must start with exactly its coordinator-created volume")
            try requireRealMount(DiskUtility.isMountPoint(fixture.external), "The coordinator volume is not mounted")
            let initialFlags = try XCTUnwrap(DiskUtility.mountFlags(at: fixture.external))
            try requireRealMount(initialFlags & UInt32(MNT_IGNORE_OWNERSHIP) != 0, "The selected private APFS volume must use noowners")
            let sentinel = fixture.external.appendingPathComponent("coordinator-sentinel.txt")
            try requireRealMount(try String(contentsOf: sentinel, encoding: .utf8) == fixture.record.nonce,
                                 "The coordinator's volume sentinel changed")
            let source = fixture.home.appendingPathComponent("Library/Containers/org.appports.synthetic.mount/Data/Library/Application Support/Business")
            let nested = source.appendingPathComponent("nested")
            let payload = nested.appendingPathComponent("payload")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try Data(repeating: 0x53, count: 64 * 1024).write(to: payload)
            try requireRealMount(link(payload.path, source.appendingPathComponent("second").path) == 0, "Cannot create fixture hard link")
            try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path,
                                                       withDestinationPath: "nested/payload")
            let attribute = Data([0, 255, 12, 128])
            let attributeStatus = attribute.withUnsafeBytes {
                setxattr(source.path, "org.appports.real-mount-fixture", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
            }
            try requireRealMount(attributeStatus == 0 && chmod(source.path, 0o750) == 0 && chmod(payload.path, 0o640) == 0,
                                 "Cannot establish the fixture's native metadata")
            let original = try TreeCopySession.snapshot(at: source, excludingRootEntries: Self.volumeArtifacts)
            let store = ContainerMountStore(fileURL: fixture.root.appendingPathComponent("data-records.plist"))
            let disk = DiskUtility(runner: runner, commandTimeout: 90, administratorRunner: nil)
            let migrator = ContainerVolumeMigrator(disk: disk, store: store,
                stagingMountRootURL: fixture.privateMounts, synchronizeAgent: { _ in }, homeDirectory: fixture.home)
            let item = DataDirItem(name: "Business", path: source, type: .containers, priority: .recommended,
                                   description: "Private APFS mount validation")
            let moved = try await migrator.migrateAndComplete(item: item, externalRootURL: fixture.external,
                appName: "Synthetic Mount", bundleIdentifier: "org.appports.synthetic.mount", progressHandler: nil)
            try requireRealMount(moved.cleanupWarning == nil, moved.cleanupWarning?.message ?? "Migration cleanup failed")
            try requireRealMount(DiskUtility.isMountPoint(source), "The production migration did not establish a real kernel mount")
            let mounted = try await disk.volumeInfo(for: source.path)
            try requireRealMount(mounted.volumeUUID?.uppercased() == moved.record.volumeUUID.uppercased(), "Mounted UUID does not match the committed record")
            try requireRealMount(mounted.apfsContainerReference == fixture.record.containerReference,
                                 "The data volume escaped the private image container")
            let mountedFlags = try XCTUnwrap(DiskUtility.mountFlags(at: source))
            try requireRealMount(mountedFlags & UInt32(MNT_IGNORE_OWNERSHIP) == 0, "The data volume must preserve real ownership")
            try TreeCopySession.verifyCopy(at: source, against: original)
            try requireRealMount(try store.recordsStrict() == [moved.record] && store.transfers().isEmpty,
                                 "Migration did not finish its record and retained-source cleanup")
            let liveInventory = try await runner.inventory()
            try requireRealMount(Set(liveInventory.volumes.map(\.uuid)) ==
                [fixture.record.initialVolumeUUID.uppercased(), moved.record.volumeUUID.uppercased()],
                "Migration must create exactly one dedicated volume")

            // These are real writes through the newly mounted original path.
            try Data("written after activation".utf8).write(to: source.appendingPathComponent("new-file"))
            let handle = try FileHandle(forWritingTo: payload)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data("updated active hard-linked payload".utf8))
            try handle.synchronize()
            try handle.close()
            let current = try TreeCopySession.snapshot(at: source, excludingRootEntries: Self.volumeArtifacts)
            try DurableFileIO.write(try JSONSerialization.data(withJSONObject: ["nonce": fixture.record.nonce,
                "createdVolumeUUID": moved.record.volumeUUID, "stage": "active-write-verified"]),
                to: fixture.root.appendingPathComponent("real-mount-progress.json"))
            let warning = try await migrator.restoreAndComplete(record: moved.record,
                estimatedTotalBytes: current.logicalBytes, progressHandler: nil)
            try requireRealMount(warning == nil, warning?.message ?? "Restore cleanup failed")
            try requireRealMount(!DiskUtility.isMountPoint(source), "The restored original path is still a mount")
            try requireRealMount(try RealMountFileIdentity.capture(source).kind == UInt32(S_IFDIR), "The restored root is not a real directory")
            try TreeCopySession.verifyCopy(at: source, against: current)
            try requireRealMount(try String(contentsOf: source.appendingPathComponent("new-file"), encoding: .utf8) == "written after activation",
                                 "The activation-time write was not restored")
            try requireRealMount(try store.recordsStrict().isEmpty && store.transfers().isEmpty && store.managedLinks().isEmpty
                && store.pendingCleanups().isEmpty && store.preservedMaterials().isEmpty, "Production cleanup left records or materials")
            try requireRealMount(try FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path) == ["Business"],
                                 "The source parent still contains staging or retained originals")
            if FileManager.default.fileExists(atPath: fixture.privateMounts.path) {
                try requireRealMount(try FileManager.default.contentsOfDirectory(atPath: fixture.privateMounts.path).isEmpty,
                                     "Private mount staging was not cleaned up")
            }
            try Self.requireNoImmutableNodes(at: source)
            let finished = try await runner.inventory()
            try requireRealMount(Set(finished.volumes.map(\.uuid)) == [fixture.record.initialVolumeUUID.uppercased()],
                                 "The dedicated data volume remains after restore cleanup")
            try requireRealMount(try String(contentsOf: sentinel, encoding: .utf8) == fixture.record.nonce,
                                 "The coordinator's original volume was changed")
            let finalFlags = try XCTUnwrap(DiskUtility.mountFlags(at: fixture.external))
            try requireRealMount(finalFlags & UInt32(MNT_IGNORE_OWNERSHIP) != 0, "The coordinator's noowners option was changed")
            let report: [String: Any] = ["status": "passed", "nonce": fixture.record.nonce, "pid": getpid(),
                "containerUUID": fixture.record.containerUUID, "createdVolumeUUID": moved.record.volumeUUID,
                "realKernelMountVerified": true, "activeWritesRestored": true, "dedicatedVolumeDeleted": true,
                "recordsAndMaterialsCleaned": true, "immutableAbsent": true, "baseVolumeRemainsNoowners": true]
            try DurableFileIO.write(try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
                                    to: fixture.root.appendingPathComponent("real-mount-result.json"))
        } catch {
            // Preserve the fixture and its attachment for the coordinator to inspect.
            let report = ["status": "failed", "nonce": fixture.record.nonce, "error": String(describing: error)]
            try? DurableFileIO.write(try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
                                    to: fixture.root.appendingPathComponent("real-mount-result.json"))
            throw error
        }
    }

    private static let volumeArtifacts: Set<String> = [ContainerVolumeMigrator.volumeMarkerFileName,
        ContainerVolumeMigrator.neverIndexFileName, ".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems",
        ".DocumentRevisions-V100", ".PKInstallSandboxManager", ".PKInstallSandboxManager-SystemSoftware"]

    private static func requireNoImmutableNodes(at root: URL) throws {
        let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var urls = [root]
        while let url = entries?.nextObject() as? URL { urls.append(url) }
        for url in urls {
            var info = stat()
            try requireRealMount(lstat(url.path, &info) == 0, "Cannot inspect restored fixture flags")
            try requireRealMount(info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) == 0, "An immutable flag remained on restored fixture data")
        }
    }
}

private func requireRealMount(_ condition: Bool, _ message: String) throws {
    guard condition else { throw NSError(domain: "AppPorts.PrivateAPFSValidation", code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]) }
}

private struct RealMountFileIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let uid: UInt32
    let kind: UInt32

    static func capture(_ url: URL) throws -> Self {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return .init(device: UInt64(UInt32(bitPattern: value.st_dev)), inode: UInt64(value.st_ino),
                     uid: value.st_uid, kind: UInt32(value.st_mode & S_IFMT))
    }
}

private struct RealMountFixture: Sendable {
    struct Record: Codable, Sendable {
        let nonce: String
        let rootPath: String
        let imagePath: String
        let externalPath: String
        let rootIdentity: RealMountFileIdentity
        let imageIdentity: RealMountFileIdentity
        let containerReference: String
        let containerUUID: String
        let initialVolumeUUID: String
        let initialVolumeDevice: String
    }
    let record: Record
    let root: URL
    let image: URL
    let external: URL
    let home: URL
    let privateMounts: URL
    private let recordBytes: Data

    init() throws {
        guard let path = ProcessInfo.processInfo.environment["APPPORTS_REAL_MOUNT_ROOT"], !path.isEmpty else {
            throw XCTSkip("Use the private APFS coordinator and APPPORTS_REAL_MOUNT_ROOT to enable real mount validation")
        }
        root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        try requireRealMount(root.deletingLastPathComponent().path == temporary.path && root.lastPathComponent.hasPrefix("AppPortsRealMount-"),
                             "The fixture root must be a dedicated directory under this host's NSTemporaryDirectory")
        recordBytes = try Self.readRecord(at: root.appendingPathComponent("coordinator-owner.json"))
        record = try JSONDecoder().decode(Record.self, from: recordBytes)
        image = root.appendingPathComponent("fixture.sparseimage")
        external = root.appendingPathComponent("External")
        home = root.appendingPathComponent("Home")
        privateMounts = root.appendingPathComponent("PrivateMounts")
        try requireRealMount(root.lastPathComponent == "AppPortsRealMount-" + record.nonce && UUID(uuidString: record.nonce) != nil,
                             "The fixture name and creation nonce do not match")
        // pathlib preserves /private/var while Foundation may use /var for the
        // same directory. Compare resolved paths, then verify the recorded
        // filesystem identities before allowing any private-image command.
        try requireRealMount(URL(fileURLWithPath: record.rootPath).standardizedFileURL.resolvingSymlinksInPath() == root
            && URL(fileURLWithPath: record.imagePath).standardizedFileURL.resolvingSymlinksInPath() == image
            && URL(fileURLWithPath: record.externalPath).standardizedFileURL.resolvingSymlinksInPath() == external,
                             "The manifest points outside its private fixture")
        try requireRealMount(record.containerReference.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil
            && UUID(uuidString: record.containerUUID) != nil && UUID(uuidString: record.initialVolumeUUID) != nil,
            "The coordinator did not record an APFS container and volume identity")
        try requireOwnedFiles()
        try requireRealMount(!FileManager.default.fileExists(atPath: home.path)
            && !FileManager.default.fileExists(atPath: root.appendingPathComponent("data-records.plist").path),
            "A real mount test cannot reuse prior data or a prior ledger")
    }

    func requireOwnedFiles() throws {
        try requireRealMount(try RealMountFileIdentity.capture(root) == record.rootIdentity
            && record.rootIdentity.uid == geteuid() && record.rootIdentity.kind == UInt32(S_IFDIR), "The private fixture root changed")
        try requireRealMount(try RealMountFileIdentity.capture(image) == record.imageIdentity
            && record.imageIdentity.uid == geteuid() && record.imageIdentity.kind == UInt32(S_IFREG), "The private image file changed")
        try requireRealMount(try Self.readRecord(at: root.appendingPathComponent("coordinator-owner.json")) == recordBytes,
                             "The coordinator's ownership manifest changed")
    }

    private static func readRecord(at url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var value = stat()
        try requireRealMount(fstat(descriptor, &value) == 0 && value.st_mode & S_IFMT == S_IFREG
            && value.st_uid == geteuid() && value.st_size <= 65536, "The coordinator manifest is not a small user-owned regular file")
        return try handle.readToEnd() ?? Data()
    }
}

private actor PrivateImageDiskRunner: ShellCommandRunning {
    struct Volume: Sendable { let uuid: String; let device: String }
    struct Inventory: Sendable { let volumes: [Volume] }
    private struct Command: Codable { let executable: String; let arguments: [String]; let status: Int32; let timedOut: Bool }
    let fixture: RealMountFixture
    private var commands: [Command] = []

    init(fixture: RealMountFixture) { self.fixture = fixture }

    func inventory() async throws -> Inventory {
        try fixture.requireOwnedFiles()
        let attachments = try await plist("/usr/bin/hdiutil", ["info", "-plist"])
        let images = (attachments["images"] as? [[String: Any]] ?? []).filter {
            guard let path = $0["image-path"] as? String else { return false }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == fixture.image.path
        }
        try requireRealMount(images.count == 1, "The image has no unique live hdiutil attachment")
        let devices = Set((images[0]["system-entities"] as? [[String: Any]] ?? []).compactMap {
            ($0["dev-entry"] as? String).map { $0.replacingOccurrences(of: "/dev/", with: "") }
        })
        let listing = try await plist("/usr/sbin/diskutil", ["apfs", "list", "-plist", fixture.record.containerReference])
        let containers = listing["Containers"] as? [[String: Any]] ?? []
        try requireRealMount(containers.count == 1, "The private APFS container is unavailable or ambiguous")
        let container = containers[0]
        try requireRealMount(container["ContainerReference"] as? String == fixture.record.containerReference
            && (container["APFSContainerUUID"] as? String)?.uppercased() == fixture.record.containerUUID.uppercased(),
            "The APFS container identity changed")
        let physicalStores = (container["PhysicalStores"] as? [[String: Any]] ?? []).compactMap { $0["DeviceIdentifier"] as? String }
        try requireRealMount(!physicalStores.isEmpty && physicalStores.allSatisfy(devices.contains),
                             "The APFS physical stores are not backed exclusively by the coordinator's image")
        let volumes = try (container["Volumes"] as? [[String: Any]] ?? []).map { entry -> Volume in
            guard let uuid = entry["APFSVolumeUUID"] as? String, let device = entry["DeviceIdentifier"] as? String,
                  device.range(of: "^" + fixture.record.containerReference + #"s[0-9]+$"#, options: .regularExpression) != nil else {
                throw NSError(domain: "AppPorts.PrivateAPFSValidation", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Incomplete private volume inventory"])
            }
            return Volume(uuid: uuid.uppercased(), device: device)
        }
        try requireRealMount(volumes.contains { $0.uuid == fixture.record.initialVolumeUUID.uppercased()
            && $0.device == fixture.record.initialVolumeDevice }, "The coordinator's baseline volume disappeared or changed")
        try fixture.requireOwnedFiles()
        return Inventory(volumes: volumes)
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
        try fixture.requireOwnedFiles()
        let readOnly = executable == "/usr/sbin/diskutil" &&
            ((arguments.count == 3 && Array(arguments.prefix(2)) == ["info", "-plist"])
             || (Array(arguments.prefix(3)) == ["apfs", "list", "-plist"] && [3, 4].contains(arguments.count)))
        if !readOnly {
            let current = try await inventory()
            if executable == "/sbin/newfs_apfs" {
                try requireRealMount(arguments.count == 9 && Array(arguments.prefix(7)) ==
                    ["-A", "-w", "-U", String(getuid()), "-G", String(getgid()), "-v"]
                    && arguments[7].hasPrefix("AppPorts-org.appports.synthetic.mount-Business-")
                    && arguments[8] == fixture.record.containerReference && current.volumes.count == 1,
                    "Refusing volume creation outside the fresh private container")
            } else if executable == "/usr/sbin/diskutil", arguments.count == 7, arguments[0] == "mount" {
                try requireRealMount(Array(arguments.prefix(3)) == ["mount", "nobrowse", "-mountPoint"]
                    && Array(arguments[4...5]) == ["-mountOptions", "owners"], "Unexpected private mount options")
                try requirePrivateVolume(arguments[6], in: current)
                let destination = URL(fileURLWithPath: arguments[3]).standardizedFileURL
                try requireRealMount(destination.path.hasPrefix(fixture.root.path + "/")
                    && destination.deletingLastPathComponent().resolvingSymlinksInPath().path.hasPrefix(fixture.root.path + "/"),
                    "The mount destination escaped the private fixture")
            } else if executable == "/usr/sbin/diskutil", arguments.count == 2, arguments[0] == "unmount" {
                try await requirePrivateMountedVolume(at: arguments[1], inventory: current)
            } else if executable == "/usr/sbin/diskutil", arguments.count == 3,
                      Array(arguments.prefix(2)) == ["apfs", "deleteVolume"] {
                try requirePrivateVolume(arguments[2], in: current)
            } else if executable == "/sbin/mount", arguments.count == 4,
                      Array(arguments.prefix(2)) == ["-u", "-o"] {
                let allowed: Set<String> = ["nobrowse", "owners", "noowners", "rdonly", "nodev", "nosuid", "noexec"]
                try requireRealMount(Set(arguments[2].split(separator: ",").map(String.init)).isSubset(of: allowed),
                                     "Unexpected mount update options")
                try await requirePrivateMountedVolume(at: arguments[3], inventory: current)
            } else {
                throw NSError(domain: "AppPorts.PrivateAPFSValidation", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Refusing unrecognized disk mutation: " + executable + " " + arguments.joined(separator: " ")])
            }
        }
        let result = try await ProcessCommandRunner().run(executable: executable, arguments: arguments, timeout: timeout)
        commands.append(Command(executable: executable, arguments: arguments, status: result.status, timedOut: result.timedOut))
        try DurableFileIO.write(try JSONEncoder().encode(commands), to: fixture.root.appendingPathComponent("real-disk-commands.json"))
        return result
    }

    private func requirePrivateVolume(_ target: String, in inventory: Inventory) throws {
        try requireRealMount(inventory.volumes.contains { $0.uuid != fixture.record.initialVolumeUUID.uppercased()
            && ($0.uuid == target.uppercased() || $0.device == target) }, "Disk mutation did not target the private data volume")
    }

    private func requirePrivateMountedVolume(at path: String, inventory: Inventory) async throws {
        let info = try await plist("/usr/sbin/diskutil", ["info", "-plist", path])
        let reportedMount = try XCTUnwrap(info["MountPoint"] as? String)
        try requireRealMount(URL(fileURLWithPath: reportedMount).standardizedFileURL.resolvingSymlinksInPath()
            == URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath(),
            "The unmount/update target is not the actual volume root")
        try requirePrivateVolume(info["VolumeUUID"] as? String ?? "", in: inventory)
        try requireRealMount(info["APFSContainerReference"] as? String == fixture.record.containerReference,
                             "The mounted volume no longer belongs to the private container")
    }

    private func plist(_ executable: String, _ arguments: [String]) async throws -> [String: Any] {
        let result = try await ProcessCommandRunner().run(executable: executable, arguments: arguments, timeout: 45)
        try requireRealMount(result.status == 0 && !result.timedOut,
                             executable + " " + arguments.joined(separator: " ") + ": " + result.combinedText)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: result.standardOutput, format: nil) as? [String: Any])
    }
}
