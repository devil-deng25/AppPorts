//
//  OwnershipStorageAdvisory.swift
//  AppPorts
//

import Foundation
import Darwin

// MARK: - 迁移目标盘是否保存文件所有者

/// 符号链接迁移前，看一眼目标盘是否记得住「哪个文件属于哪个用户」。
///
/// 复制本身不受影响：内容、权限位、时间都能过去。问题出在归属上——
/// - exFAT / FAT 这类文件系统没有 POSIX 所有者字段，macOS 只能给它一个占位值；
/// - HFS+ 以忽略所有权的视图挂载时，新建对象会把该占位值真的写进磁盘。
///
/// 普通应用读写照旧；少数用管理员权限校验归属的应用（例如带特权后台服务的
/// clash-verge）会拒绝工作，并且它给出的 `chown` 修复命令在忽略所有权的卷上会被
/// 内核静默丢弃，用户怎么试都修不好。这种提示只能在迁移前给出，事后补救代价太大。
///
/// APFS 即使在忽略所有权的挂载下也保存真实 UID/GID（实测：noowners 挂载下新建文件，
/// 切回 owners 挂载后 uid 仍为用户本人），因此不在提示范围。这里只提示、不阻断：
/// 用户可能确实只有一块 exFAT 盘可用。
struct OwnershipStorageAdvisory: Sendable {

    /// 目标盘的实际状态；只读查询，不需要授权。
    struct VolumeState: Equatable, Sendable {
        /// `statfs` 的 `f_fstypename`，例如 apfs / hfs / exfat
        let filesystemType: String
        /// 卷是否以「忽略文件所有权」挂载
        let ignoresOwnership: Bool
    }

    enum Limitation: Equatable, Sendable {
        /// 文件系统没有所有者字段（exFAT、FAT32）
        case noFileOwners(filesystemType: String)
        /// 卷忽略所有权，且新建对象会把忽略标记写进磁盘（HFS+）
        case ignoredOwnership(filesystemType: String)
    }

    /// 检测用到的外部依赖；测试注入假实现，不碰真实磁盘。
    struct Probe: Sendable {
        var volumeState: @Sendable (URL) -> VolumeState?
    }

    let probe: Probe

    init(probe: Probe = .live) {
        self.probe = probe
    }

    /// - Parameter destination: 本次迁移要写入的位置；允许尚不存在，会向上找最近的已存在目录。
    /// - Returns: 目标盘存不住归属时的具体原因；存得住或无法判断时为 nil。
    func limitation(for destination: URL) -> Limitation? {
        guard let state = probe.volumeState(destination) else { return nil }
        let type = state.filesystemType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !type.isEmpty else { return nil }

        switch type {
        case "exfat", "msdos", "fat":
            // 这类文件系统根本没有所有者字段，挂载视图怎么设置都不保存。
            return .noFileOwners(filesystemType: type)
        case "hfs":
            return state.ignoresOwnership ? .ignoredOwnership(filesystemType: type) : nil
        default:
            // APFS 与其余文件系统（含 APFS 的 noowners 视图）能保存真实归属。
            return nil
        }
    }
}

extension OwnershipStorageAdvisory.Probe {
    /// 真机实现。`statfs` 只读，不弹授权框，也不会改动目标盘。
    static let live = OwnershipStorageAdvisory.Probe(volumeState: { url in
        guard let path = existingAncestor(of: url) else { return nil }
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        let type = withUnsafeBytes(of: &info.f_fstypename) { raw in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        return .init(
            filesystemType: type,
            ignoresOwnership: info.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0
        )
    })

    /// 迁移目标通常还没创建（`<外盘>/Library/Application Support/<bundle id>`），
    /// 盘本身则一定存在，所以向上找到第一个可 `stat` 的目录即可。
    private static func existingAncestor(of url: URL) -> String? {
        var candidate = url.standardizedFileURL
        while candidate.path != "/" {
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
        return candidate.path
    }
}

// MARK: - 提示文案

extension OwnershipStorageAdvisory.Limitation {
    /// - Parameter driveName: 用户认得的盘名，例如 `UD210`，不是文件系统类型。
    func advisoryMessage(driveName: String) -> String {
        switch self {
        case .noFileOwners:
            return String(
                format: "「%@」不保存文件所有者。迁移后数据仍可正常读写，但个别应用（例如带后台管理员服务的）可能拒绝工作，并给出修改权限也无法解决的错误。建议把数据留在本机，或改用 APFS 格式的磁盘。".localized,
                driveName
            )
        case .ignoredOwnership:
            return String(
                format: "「%@」当前忽略文件所有权，迁移后新文件在磁盘上会被记成「未知用户」。数据仍可正常读写，但个别应用（例如带后台管理员服务的）可能拒绝工作。可以在访达的「显示简介」里取消「忽略此宗卷上的所有权」后重新迁移，或把数据留在本机。".localized,
                driveName
            )
        }
    }
}
