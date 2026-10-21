import Foundation

/// 仅供界面展示的目录大小，不参与迁移校验。
final class ToolDirectorySizeCacheStore: @unchecked Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let identity: String
        let sourcePath: String
        let targetPath: String
        let bytes: Int64
        let measuredAt: Date
    }

    struct Snapshot: Codable, Sendable {
        var version = 1
        var entries: [String: Entry] = [:]
        var updatedAt: Date? { entries.values.map(\.measuredAt).max() }
    }

    static let shared = ToolDirectorySizeCacheStore()
    static let customDirectories = ToolDirectorySizeCacheStore(fileName: "custom-directory-sizes.json")
    private let queue = DispatchQueue(label: "com.shimoko.AppPorts.tool-size-cache", qos: .utility)
    private let fileURL: URL

    init(fileName: String = "tool-directory-sizes.json") {
        fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppPorts/" + fileName)
    }

    /// 路径、状态或目标文件系统身份变化后，旧大小不再适用。
    static func identity(for item: DataDirItem) -> String? {
        guard let url = item.sizeMeasurementURL?.resolvingSymlinksInPath().standardizedFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return [item.path.standardizedFileURL.path, url.path, item.status,
                device.stringValue, inode.stringValue].joined(separator: "\n")
    }

    func load() -> Snapshot { queue.sync { read() } }

    func save(_ snapshot: Snapshot) { queue.sync { write(snapshot) } }

    func invalidate(for url: URL) {
        queue.sync {
            var snapshot = read()
            let oldCount = snapshot.entries.count
            let path = url.standardizedFileURL.path
            snapshot.entries = snapshot.entries.filter { _, entry in
                ![entry.sourcePath, entry.targetPath].contains { cached in
                    cached == path || cached.hasPrefix(path + "/") || path.hasPrefix(cached + "/")
                }
            }
            if snapshot.entries.count != oldCount { write(snapshot) }
        }
    }

    private func read() -> Snapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Snapshot() }
        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: fileURL))
            return snapshot.version == 1 ? snapshot : Snapshot()
        } catch {
            AppLogger.shared.logError("读取工具目录大小缓存失败，将重新统计", error: error)
            return Snapshot()
        }
    }

    private func write(_ snapshot: Snapshot) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            AppLogger.shared.logError("保存工具目录大小缓存失败", error: error)
        }
    }
}
