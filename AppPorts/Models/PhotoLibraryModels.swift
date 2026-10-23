//
//  PhotoLibraryModels.swift
//  AppPorts
//
//  「照片」图库（`*.photoslibrary` 包）的发现与位置判定。
//
//  图库本身是一个包目录，搬家用的是与自定义目录迁移同一条通路
//  （`CustomDirConfig` + `DataDirMover`），所以这里只负责两件事：
//  找到图库、判断它现在在哪。判定逻辑与 `CustomDirScanner` 保持同一套语义，
//  但抽成不碰文件系统的纯函数，便于测试覆盖各种软链组合。
//

import Foundation

/// 一个照片图库当前处于什么位置。
enum PhotoLibraryState: Equatable, Sendable {
    /// 本地实体目录，可以搬走。
    case movable
    /// 本地已是软链，真实图库在外置盘上。
    case onExternal(URL)
    /// 软链还在，但它指向的外置盘没有挂载。
    case externalUnavailable(URL)
    /// 本地路径不见了，外置盘上还有受管的副本，可以接回。
    case pendingRelink(URL)
    /// 本机路径存在，但既不是实体目录也没有可识别的副本。
    case missing

    var canMove: Bool {
        if case .movable = self { return true }
        return false
    }

    var canRestore: Bool {
        if case .onExternal = self { return true }
        return false
    }

    var canRelink: Bool {
        if case .pendingRelink = self { return true }
        return false
    }

    /// 展示用状态文案。复用数据目录那一套语汇，避免同一个位置出现两种叫法。
    var statusText: String {
        switch self {
        case .movable:
            return DataDirStatus.localized(DataDirStatus.local)
        case .onExternal:
            return "已在外置盘".localized
        case .externalUnavailable:
            return DataDirStatus.localized(DataDirStatus.volumeMissing)
        case .pendingRelink:
            return DataDirStatus.localized(DataDirStatus.pendingRelink)
        case .missing:
            return DataDirStatus.localized(DataDirStatus.missing)
        }
    }

    /// 需要用户先处理的状态：外置盘没接上时不该让人看到「已链接」这种安心话术。
    var needsAttention: Bool {
        switch self {
        case .externalUnavailable, .pendingRelink, .missing: return true
        case .movable, .onExternal: return false
        }
    }
}

/// 判定所需的两组事实：本地路径长什么样、外置副本还在不在。
///
/// 之所以把事实和判定分开，是因为 `FileManager` 的这些结果在测试里不好构造，
/// 而判定本身才是容易出错的地方（软链指向别处、盘没挂、副本已删）。
struct PhotoLibraryFacts: Equatable, Sendable {
    var localExists: Bool
    var localIsSymlink: Bool
    var symlinkDestination: URL?
    var symlinkDestinationExists: Bool
    var externalCopyExists: Bool
    /// 软链解析后的真实位置。整个「图片」文件夹被迁移时，图库自己不是软链，
    /// 但它的真实位置已经在外置盘上。
    var resolvedURL: URL?
    /// 图库与用户目录是否在同一个卷上。不同卷说明它已经在外置盘。
    var sameVolumeAsHome: Bool

    init(localExists: Bool,
         localIsSymlink: Bool,
         symlinkDestination: URL?,
         symlinkDestinationExists: Bool,
         externalCopyExists: Bool,
         resolvedURL: URL? = nil,
         sameVolumeAsHome: Bool = true) {
        self.localExists = localExists
        self.localIsSymlink = localIsSymlink
        self.symlinkDestination = symlinkDestination
        self.symlinkDestinationExists = symlinkDestinationExists
        self.externalCopyExists = externalCopyExists
        self.resolvedURL = resolvedURL
        self.sameVolumeAsHome = sameVolumeAsHome
    }

    /// 直接从磁盘读一份事实。`externalDestination` 来自已保存的迁移配置。
    static func capture(localURL: URL, externalDestination: URL?,
                        fileManager: FileManager = .default) -> PhotoLibraryFacts {
        var isSymlink = false
        var destination: URL?
        if let attributes = try? fileManager.attributesOfItem(atPath: localURL.path),
           let type = attributes[.type] as? FileAttributeType, type == .typeSymbolicLink,
           let rawDestination = try? fileManager.destinationOfSymbolicLink(atPath: localURL.path) {
            isSymlink = true
            destination = rawDestination.hasPrefix("/")
                ? URL(fileURLWithPath: rawDestination).standardizedFileURL
                : localURL.deletingLastPathComponent()
                    .appendingPathComponent(rawDestination).standardizedFileURL
        }
        let localExists = fileManager.fileExists(atPath: localURL.path)
        return PhotoLibraryFacts(
            // fileExists 跟随软链：软链悬空时它是 false，正好用来区分「盘没挂」。
            localExists: localExists,
            localIsSymlink: isSymlink,
            symlinkDestination: destination,
            symlinkDestinationExists: destination.map { fileManager.fileExists(atPath: $0.path) } ?? false,
            externalCopyExists: externalDestination.map { fileManager.fileExists(atPath: $0.path) } ?? false,
            resolvedURL: localExists ? localURL.resolvingSymlinksInPath().standardizedFileURL : nil,
            sameVolumeAsHome: localExists && isOnHomeVolume(localURL, fileManager: fileManager)
        )
    }

    /// 比较设备号，而不是猜路径前缀：`/Volumes` 之外也可能有其它卷，反之亦然。
    private static func isOnHomeVolume(_ url: URL, fileManager: FileManager) -> Bool {
        let home = fileManager.homeDirectoryForCurrentUser
        guard let homeAttributes = try? fileManager.attributesOfItem(atPath: home.path),
              let itemAttributes = try? fileManager.attributesOfItem(atPath: url.path),
              let homeDevice = homeAttributes[.systemNumber] as? NSNumber,
              let itemDevice = itemAttributes[.systemNumber] as? NSNumber else {
            // 读不到就当作同一卷，宁可多给一次「可移动」也不要误报成已迁移。
            return true
        }
        return homeDevice == itemDevice
    }
}

enum PhotoLibraryStateResolver {
    /// - Parameter externalDestination: 已保存配置里的外置目标；没有配置传 nil。
    static func resolve(localURL: URL,
                        externalDestination: URL?,
                        facts: PhotoLibraryFacts) -> PhotoLibraryState {
        if facts.localIsSymlink, let destination = facts.symlinkDestination {
            return facts.symlinkDestinationExists ? .onExternal(destination) : .externalUnavailable(destination)
        }
        // 本地是实体目录：图库自己没被链接，但整个「图片」文件夹已经被迁移到外置盘，
        // 那么它其实已经在外置盘上了，再给「移动到外置盘」只会撞上「与已管理目录重叠」。
        if facts.localExists {
            if !facts.sameVolumeAsHome, let resolved = facts.resolvedURL { return .onExternal(resolved) }
            return .movable
        }
        if let externalDestination, facts.externalCopyExists { return .pendingRelink(externalDestination) }
        return .missing
    }
}

/// 从磁盘上找图库。做成 enum 而不是实例，是因为它没有状态。
enum PhotoLibraryDiscovery {
    static let packageExtension = "photoslibrary"

    /// 默认位置：用户「图片」文件夹。
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
    }

    /// - Returns: 该目录下的图库，按修改时间从新到旧；不是包目录的同名文件会被排除。
    static func libraryURLs(in directory: URL, fileManager: FileManager = .default) -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == packageExtension }
            .filter { url in
                // 包目录在 Finder 里表现为单个文件，但在文件系统上必须是目录。
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return (left ?? .distantPast) > (right ?? .distantPast)
            }
    }
}

/// 卡片上的一行。
struct PhotoLibraryItem: Identifiable, Equatable, Sendable {
    var url: URL
    var state: PhotoLibraryState
    var sizeText: String?
    var sizeBytes: Int64 = 0
    /// 已保存的迁移配置；只有迁移过的图库才有。
    var config: CustomDirConfig?

    nonisolated var id: String { url.standardizedFileURL.path }

    nonisolated var displayName: String {
        url.deletingPathExtension().lastPathComponent
    }

    /// 迁移时交给 `DataDirMover` 的条目。类型走 `.custom`，与配置里的目录同源。
    nonisolated var dataDirItem: DataDirItem {
        DataDirItem(
            name: displayName,
            path: url,
            type: .custom,
            priority: .recommended,
            description: "照片图库".localized,
            status: state.statusText,
            size: sizeText,
            sizeBytes: sizeBytes,
            isMigratable: state.canMove,
            linkedDestination: state.canRestore || state.canRelink ? config?.externalDestinationURL : nil
        )
    }

    /// 外置目标：配置里有就用配置，否则取软链实际指向。
    nonisolated var externalDestination: URL? {
        if let config { return config.externalDestinationURL }
        if case let .onExternal(destination) = state { return destination }
        if case let .externalUnavailable(destination) = state { return destination }
        return nil
    }
}
