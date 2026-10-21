import Foundation

/// 首页展示缓存，不作为迁移完整性或删除原件的依据。
final class AppSizeCacheStore: @unchecked Sendable {
    struct Entry: Codable, Sendable {
        let size: String
        let bytes: Int64
        let mtime: Date?
        let isLocalPortal: Bool

        init(size: String, bytes: Int64, mtime: Date?, isLocalPortal: Bool = false) {
            self.size = size
            self.bytes = bytes
            self.mtime = mtime
            self.isLocalPortal = isLocalPortal
        }
    }

    struct Snapshot: Codable, Sendable {
        var version = 1
        var entries: [String: Entry] = [:]
        var updatedAt: Date?
    }

    static let shared = AppSizeCacheStore()
    private let queue = DispatchQueue(label: "com.shimoko.AppPorts.app-size-cache", qos: .utility)
    private let fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AppPorts", isDirectory: true)
        .appendingPathComponent("app-sizes.json")

    func load() -> Snapshot {
        queue.sync {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return Snapshot() }
            do {
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: fileURL))
                return snapshot.version == 1 ? snapshot : Snapshot()
            } catch {
                AppLogger.shared.logError("读取应用大小缓存失败，将重新统计", error: error)
                return Snapshot()
            }
        }
    }

    func save(entries: [String: Entry], updatedAt: Date) {
        let snapshot = Snapshot(entries: entries, updatedAt: updatedAt)
        queue.async { [self] in
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
            } catch {
                AppLogger.shared.logError("保存应用大小缓存失败", error: error)
            }
        }
    }
}
