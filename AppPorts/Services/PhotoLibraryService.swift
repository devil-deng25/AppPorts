//
//  PhotoLibraryService.swift
//  AppPorts
//
//  照片图库的扫描、大小统计、搬迁前的前置检查。
//
//  这里刻意不实现任何搬运逻辑：图库搬家走的是 `CustomDirConfig` +
//  `DataDirMover` 这条既有通路，与用户手动添加的目录完全一样，
//  因此「接回 / 还原 / 断开链接」这些能力不需要第二套实现。
//

import AppKit
import Foundation

enum PhotoLibraryService {
    /// 「照片」的 bundle id。用它判断 App 是否在运行，比按进程名匹配可靠。
    static let photosBundleIdentifier = "com.apple.Photos"

    enum MigrationError: LocalizedError {
        case photosStillRunning
        case unsupportedStorage

        var errorDescription: String? {
            switch self {
            case .photosStillRunning:
                return "请先退出照片 App，再重试".localized
            case .unsupportedStorage:
                return "目标盘不支持文件所有者或扩展属性，照片图库可能无法打开；请换用 APFS 或 Mac OS 扩展格式的磁盘".localized
            }
        }
    }

    // MARK: - 发现

    /// 只做发现与状态判定，不统计大小。进页面就遍历几十 GB 会让人以为界面卡住。
    static func items(picturesDirectory: URL = PhotoLibraryDiscovery.defaultDirectory,
                      configs: [CustomDirConfig],
                      fileManager: FileManager = .default) -> [PhotoLibraryItem] {
        PhotoLibraryDiscovery.libraryURLs(in: picturesDirectory, fileManager: fileManager).map { url in
            let config = configs.first {
                $0.localURL.standardizedFileURL.path == url.standardizedFileURL.path
            }
            let facts = PhotoLibraryFacts.capture(
                localURL: url,
                externalDestination: config?.externalDestinationURL,
                fileManager: fileManager
            )
            return PhotoLibraryItem(
                url: url,
                state: PhotoLibraryStateResolver.resolve(
                    localURL: url,
                    externalDestination: config?.externalDestinationURL,
                    facts: facts
                ),
                config: config
            )
        }
    }

    /// 大小统计。图库可能几十 GB，调用方应放在后台任务里。
    static func measureSize(of url: URL) -> (text: String, bytes: Int64) {
        let measured = measureDirectorySize(at: url, useCache: false)
        var text = LocalizedByteCountFormatter.string(fromByteCount: measured.bytes)
        if !measured.readIssues.isEmpty { text += "（统计不完整）".localized }
        return (text, measured.bytes)
    }

    // MARK: - 前置检查

    /// 正在运行的照片 App 实例。
    static func photosApplications() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: photosBundleIdentifier)
            .filter { !$0.isTerminated }
    }

    /// 退出照片 App 并等它真的退出。
    ///
    /// 不用 `forceTerminate`：强杀可能让图库停在写了一半的状态。等不到就如实报错，
    /// 让用户自己关掉再点一次，比冒险继续安全。
    @MainActor
    static func quitPhotos(timeout: TimeInterval = 15) async -> Bool {
        let applications = photosApplications()
        guard !applications.isEmpty else { return true }
        applications.forEach { $0.terminate() }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if photosApplications().isEmpty { return true }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return photosApplications().isEmpty
    }

    /// 目标盘能不能装下图库需要的元数据。
    ///
    /// Photos 的图库依赖扩展属性与权限位；ExFAT/FAT 这类盘上复制过去的库
    /// 会出现「打不开」或反复重建。与其让人搬完才发现，不如在选择目标时就拒绝。
    /// - Returns: nil 表示没问题；否则返回给用户看的原因。
    static func storageLimitation(at destination: URL) -> String? {
        guard let capabilities = StorageCapabilityProbe.probe(destination: destination) else {
            // 探测不出来不等于有问题，不据此阻止。
            return nil
        }
        return capabilities.supportsPermissions && capabilities.supportsResourceFork
            ? nil
            : MigrationError.unsupportedStorage.localizedDescription
    }
}
