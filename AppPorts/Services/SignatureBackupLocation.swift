import Darwin
import DiskArbitration
import Foundation

/// A path is only a hint. The volume and directory inode must both agree before
/// a remounted backup can be read, published or removed.
struct SignatureDirectoryLocation: Codable, Equatable, Sendable {
    let path: String
    let volumeUUID: String
    let relativePath: String
    let identity: DataPathIdentity

    static func capture(_ directory: URL, volumeRoot: URL? = nil) throws -> Self {
        let directory = directory.standardizedFileURL
        guard directory == directory.resolvingSymlinksInPath(),
              try SignatureSnapshot.info(at: directory).st_mode & S_IFMT == S_IFDIR else {
            throw CodeSigner.SigningError.snapshotInvalid
        }
        let identity = try DataPathIdentity.capture(directory)
        guard let uuid = identity.volumeUUID, !uuid.isEmpty,
              let volumeRootURL = try volumeRoot ?? directory.resourceValues(forKeys: [.volumeURLKey]).volume else {
            throw CodeSigner.SigningError.snapshotInvalid
        }
        let root = volumeRootURL.standardizedFileURL
        let prefix = root.path == "/" ? "/" : root.path + "/"
        guard directory.path == root.path || directory.path.hasPrefix(prefix) else { throw CodeSigner.SigningError.snapshotInvalid }
        return .init(path: directory.path, volumeUUID: uuid,
                     relativePath: directory.path == root.path ? "" : String(directory.path.dropFirst(prefix.count)), identity: identity)
    }

    func resolve(mountedVolumes: [URL]? = nil) throws -> URL {
        guard path.hasPrefix("/"), !relativePath.contains("\0"),
              relativePath.isEmpty || relativePath.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              identity.isResolved, identity.volumeUUID?.caseInsensitiveCompare(volumeUUID) == .orderedSame else {
            throw CodeSigner.SigningError.snapshotInvalid
        }
        let volumes = mountedVolumes ?? FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        let candidates = [URL(fileURLWithPath: path)] + volumes.map { $0.appendingPathComponent(relativePath) }
        for candidate in candidates {
            let url = candidate.standardizedFileURL
            guard url == url.resolvingSymlinksInPath(),
                  (try? SignatureSnapshot.info(at: url).st_mode & S_IFMT) == S_IFDIR,
                  let actual = try? DataPathIdentity.capture(url),
                  actual.volumeUUID?.caseInsensitiveCompare(volumeUUID) == .orderedSame,
                  actual.matchesFilesystemObject(identity) else { continue }
            return url
        }
        throw CodeSigner.SigningError.backupStorageUnavailable
    }

    var displayURL: URL { (try? resolve()) ?? URL(fileURLWithPath: path) }
}

enum SignatureBackupStorage {
    static let directoryName = "AppPorts Backups"

    struct Volume: Sendable {
        let url: URL
        let uuid: String
        let availableBytes: Int64
        let isExternal: Bool
        let isLocal: Bool
        let isWritable: Bool
        var isPhysical = true
    }

    /// Prefer the application's external volume, then an existing migration
    /// volume, then the eligible volume with the most free space. No picker or
    /// new location preference is required, and internal volumes never qualify.
    static func candidates(_ volumes: [Volume], applicationVolume: String?, knownVolume: String?, requiredBytes: Int64,
                           excluding ejection: DiskEjectionPauseStore.Snapshot = .init(pauses: [])) -> [Volume] {
        func rank(_ volume: Volume) -> Int {
            if volume.uuid.caseInsensitiveCompare(applicationVolume ?? "") == .orderedSame { return 0 }
            if volume.uuid.caseInsensitiveCompare(knownVolume ?? "") == .orderedSame { return 1 }
            return 2
        }
        return volumes.filter { $0.isExternal && $0.isLocal && $0.isWritable && $0.isPhysical && !$0.uuid.isEmpty
            && $0.availableBytes >= requiredBytes && !ejection.blocks(volumeUUIDs: [$0.uuid], paths: [$0.url.path]) }
            .sorted {
                if rank($0) != rank($1) { return rank($0) < rank($1) }
                if $0.availableBytes != $1.availableBytes { return $0.availableBytes > $1.availableBytes }
                return $0.uuid < $1.uuid
            }
    }

    static func automaticDestination(for app: URL, requiredBytes: Int64) throws -> SignatureDirectoryLocation {
        let ejection = try DiskEjectionPauseStore().snapshot()
        let keys: Set<URLResourceKey> = [.volumeUUIDStringKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsReadOnlyKey]
        let roots = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: []) ?? []
        let volumes: [Volume] = roots.compactMap { root in
            guard let values = try? root.resourceValues(forKeys: keys), let uuid = values.volumeUUIDString,
                  let available = try? CodeSigner.availableTemporarySpace(at: root) else { return nil }
            return Volume(url: root, uuid: uuid, availableBytes: available,
                          isExternal: values.volumeIsInternal == false, isLocal: values.volumeIsLocal == true,
                          isWritable: values.volumeIsReadOnly == false, isPhysical: isPhysicalExternalVolume(root))
        }
        let appVolume = try DataPathIdentity.capture(app).volumeUUID
        let knownVolume = UserDefaults.standard.string(forKey: "ExternalDrivePath").flatMap {
            try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        }
        for volume in candidates(volumes, applicationVolume: appVolume, knownVolume: knownVolume,
                                 requiredBytes: requiredBytes, excluding: ejection) {
            try Task.checkCancellation()
            do {
                // Re-read after enumeration: an unmounted volume's surviving
                // mountpoint must never become an internal backup destination.
                var root = volume.url
                root.removeAllCachedResourceValues()
                let values = try root.resourceValues(forKeys: keys)
                guard values.volumeUUIDString?.caseInsensitiveCompare(volume.uuid) == .orderedSame,
                      values.volumeIsInternal == false, values.volumeIsLocal == true,
                      values.volumeIsReadOnly == false, isPhysicalExternalVolume(root) else {
                    throw CodeSigner.SigningError.backupStorageUnavailable
                }
                let destination = volume.url.appendingPathComponent(directoryName)
                let location = try prepareDirectory(destination)
                guard location.volumeUUID.caseInsensitiveCompare(volume.uuid) == .orderedSame else {
                    throw CodeSigner.SigningError.backupStorageUnavailable
                }
                try writeExplanation(in: destination)
                return location
            }
            catch is CancellationError { throw CancellationError() }
            catch { AppLogger.shared.logError("无法准备签名备份目录", error: error, relatedURLs: [("volume", volume.url)]) }
        }
        throw CodeSigner.SigningError.backupStorageUnavailable
    }

    private static func isPhysicalExternalVolume(_ root: URL) -> Bool {
        guard let session = DASessionCreate(nil),
              let disk = DADiskCreateFromVolumePath(nil, session, root as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any],
              description[kDADiskDescriptionDeviceInternalKey as String] as? Bool == false,
              let transport = description[kDADiskDescriptionDeviceProtocolKey as String] as? String else { return false }
        return !["disk image", "virtual"].contains(transport.lowercased())
    }

    static func prepareDirectory(_ directory: URL) throws -> SignatureDirectoryLocation {
        let directory = directory.standardizedFileURL
        guard directory == directory.resolvingSymlinksInPath(),
              try SignatureSnapshot.info(at: directory.deletingLastPathComponent()).st_mode & S_IFMT == S_IFDIR else {
            throw CodeSigner.SigningError.snapshotInvalid
        }
        if try !SignatureSnapshot.entryExists(directory) {
            guard mkdir(directory.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try DurableFileIO.syncDirectory(at: directory.deletingLastPathComponent())
        }
        let location = try SignatureDirectoryLocation.capture(directory)
        // Prove writing and synchronization before the live signature changes.
        let probe = directory.appendingPathComponent(".write-check-" + UUID().uuidString)
        let fd = open(probe.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd); _ = unlink(probe.path) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try DurableFileIO.syncDirectory(at: directory)
        return location
    }

    static func writeExplanation(in directory: URL) throws {
        let url = directory.appendingPathComponent("README.txt")
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        if fd < 0, errno == EEXIST { return } // Preserve any explanation the owner has edited.
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        let text = """
        AppPorts 签名原包备份 / Original application backups

        此文件夹由 AppPorts 自动创建，保存手动重签名前的官方应用原包。
        原包存放在外盘，内盘只保留小型索引和操作记录。
        文件名中的 UUID 用来区分不同应用或版本；应用身份和版本保留在每个 .app 包内。

        恢复：连接这块外盘，在 AppPorts 中对当前应用使用“恢复原始签名”。
        AppPorts 会核对当前安装、版本、原包内容和相关数据依赖。
        原包不是用户数据备份；此文件夹不保存聊天记录、文档或其他应用数据。

        清理：确认不再需要恢复旧签名后，可在 Finder 中删除对应 .app 原包。
        删除不会删除当前安装的应用或应用数据，但会失去这份原包提供的离线恢复能力；
        此后可能需要从官方渠道重新安装。AppPorts 也会自动清理已证明冗余的原包。
        移入废纸篓后仍占磁盘空间，清空废纸篓后才可能释放空间。
        不要修改原包内容，也不要将原包当作日常应用启动。
        请保留此文件夹的位置；外盘挂载名称改变时，AppPorts 会按卷身份重新寻找它。
        APFS 克隆可能共享数据块，Finder 显示的大小不等于删除后可释放的空间。

        AppPorts creates this folder automatically to retain official applications before manual re-signing.
        Original packages stay on external storage; only small indexes and operation records stay internally.
        UUIDs distinguish packages. Each .app still contains its application identity and version.

        To restore, connect this disk and choose Restore Original Signature on the installed app in AppPorts.
        AppPorts verifies the installation, version, original contents and related data dependencies.
        These are application packages, not backups of your documents, messages or other application data.

        You may delete an original .app in Finder once you no longer need its signature recovery option.
        This leaves the installed application and its data intact, but removes that offline recovery copy.
        Reinstalling from the official source may then be necessary. AppPorts also removes verified redundant originals.
        Items in Trash still use storage. Do not modify or run these originals as your everyday applications.
        Keep this folder in place. AppPorts uses the volume identity to handle changed disk mount names.
        APFS clones may share blocks, so the displayed size is not a promise of reclaimable space.
        """
        let data = Data((text + "\n").utf8)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try DurableFileIO.syncDirectory(at: directory)
    }
}
