import CryptoKit
import Darwin
import Foundation

/// Finder 替身记录目标卷身份，挂载位置变化后仍可定位外置数据。
enum AppDataShortcutService {
    private struct Ownership: Codable {
        let fileName: String
        let digest: Data
    }

    static func update(for record: ContainerMountRecord, removing: Bool = false) {
        do { try updateShortcut(for: record, removing: removing) }
        catch {
            AppLogger.shared.logError("更新应用数据快捷方式失败", error: error,
                relatedURLs: [("external_root", URL(fileURLWithPath: record.externalRootPath))])
        }
    }

    private static func updateShortcut(for record: ContainerMountRecord, removing: Bool) throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: record.externalRootPath)
        // 不在外置盘缺席时创建同名本地目录，也不追随目录中的软链。
        guard try isDirectory(root) else { return }
        let directory = root.appendingPathComponent("应用数据目录", isDirectory: true)
        let appDirectory = directory.appendingPathComponent(appFolderName(record.appName), isDirectory: true)
        let legacyDirectory = directory.appendingPathComponent(safeName(record.appName), isDirectory: true)
        if !removing {
            guard DiskUtility.isMountPoint(record.mountPointURL),
                  DiskUtility.mountedVolumeUUID(at: record.mountPointURL)?.caseInsensitiveCompare(record.volumeUUID) == .orderedSame else { return }
        }
        if try isDirectory(directory), legacyDirectory != appDirectory,
           try !isDirectory(appDirectory), try isDirectory(legacyDirectory) {
            try repairLegacyDirectory(legacyDirectory, destination: appDirectory)
        }
        if removing {
            guard try isDirectory(directory), try isDirectory(appDirectory) else { return }
        } else {
            try ensureDirectory(directory)
            try ensureDirectory(appDirectory)
        }
        let ownerURL = appDirectory.appendingPathComponent(".appports-alias-\(safeName(record.volumeUUID)).plist")
        let ownership = try isRegularFile(ownerURL)
            ? try PropertyListDecoder().decode(Ownership.self, from: Data(contentsOf: ownerURL)) : nil
        if let ownership {
            guard ownership.fileName == safeName(ownership.fileName) else { throw CocoaError(.fileReadCorruptFile) }
            let aliasURL = appDirectory.appendingPathComponent(ownership.fileName)
            if try isRegularFile(aliasURL) {
                let digest = Data(SHA256.hash(data: try Data(contentsOf: aliasURL)))
                // 用户替换过的文件不覆盖、不删除。
                guard digest == ownership.digest else { throw CocoaError(.fileWriteFileExists) }
                if !removing { return }
                try fm.removeItem(at: aliasURL)
            }
            if removing {
                try fm.removeItem(at: ownerURL)
                return
            }
        } else if removing {
            return
        }

        let target = record.mountPointURL
        let parent = target.deletingLastPathComponent().lastPathComponent
        let leaf = target.lastPathComponent
        let name = ["msg", "business"].contains(leaf) && parent.hasPrefix("wxid_")
            ? "\(leaf)（\(parent)）" : "\(leaf)（\(record.volumeUUID.prefix(8))）"
        let aliasURL = appDirectory.appendingPathComponent(safeName(name))
        guard !fm.fileExists(atPath: aliasURL.path) else { throw CocoaError(.fileWriteFileExists) }
        let bookmark = try target.bookmarkData(options: .suitableForBookmarkFile,
            includingResourceValuesForKeys: [.volumeUUIDStringKey], relativeTo: nil)
        let temporary = appDirectory.appendingPathComponent(".appports-alias-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        try URL.writeBookmarkData(bookmark, to: temporary)
        let digest = Data(SHA256.hash(data: try Data(contentsOf: temporary)))
        let owner = Ownership(fileName: aliasURL.lastPathComponent, digest: digest)
        try PropertyListEncoder().encode(owner).write(to: ownerURL, options: .atomic)
        try fm.moveItem(at: temporary, to: aliasURL)
    }

    /// 应用显示名可能含 .app，数据文件夹不能因此被 Finder 识别为应用包。
    private static func appFolderName(_ value: String) -> String {
        let name = safeName(value)
        return name.lowercased().hasSuffix(".app") ? safeName(String(name.dropLast(4))) : name
    }

    private static func repairLegacyDirectory(_ source: URL, destination: URL) throws {
        let fm = FileManager.default
        let children = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        let owners = children.filter {
            $0.lastPathComponent.hasPrefix(".appports-alias-") && $0.pathExtension == "plist"
        }
        guard !owners.isEmpty else { throw CocoaError(.fileWriteFileExists) }
        var managedNames = Set<String>()
        for ownerURL in owners {
            guard try isRegularFile(ownerURL) else { throw CocoaError(.fileReadCorruptFile) }
            let owner = try PropertyListDecoder().decode(Ownership.self, from: Data(contentsOf: ownerURL))
            guard owner.fileName == safeName(owner.fileName) else { throw CocoaError(.fileReadCorruptFile) }
            let alias = source.appendingPathComponent(owner.fileName)
            if try isRegularFile(alias) {
                guard Data(SHA256.hash(data: try Data(contentsOf: alias))) == owner.digest else {
                    throw CocoaError(.fileWriteFileExists)
                }
                managedNames.insert(owner.fileName)
            }
            managedNames.insert(ownerURL.lastPathComponent)
        }
        guard Set(children.map(\.lastPathComponent)) == managedNames else { throw CocoaError(.fileWriteFileExists) }
        try fm.moveItem(at: source, to: destination)
    }

    private static func safeName(_ value: String) -> String {
        let name = value.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return name.isEmpty || name == "." || name == ".." ? "应用" : name
    }

    private static func isRegularFile(_ url: URL) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileWriteFileExists) }
        return true
    }

    private static func isDirectory(_ url: URL) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw CocoaError(.fileWriteFileExists) }
        return true
    }

    private static func ensureDirectory(_ url: URL) throws {
        if try !isDirectory(url) { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
    }
}
