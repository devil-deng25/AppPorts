import Darwin
import Foundation

/// A write barrier for operation records and the trees they commit. Every
/// syscall failure is reported to the caller; unsupported storage never falls
/// back to an atomic rename without a durability barrier.
enum DurableFileIO {
    /// 临时记录的文件名前缀。写入中断（进程被 kill）时下面的 `defer` 不会执行，
    /// 这个前缀的残留只能由目录所有者另行回收，因此前缀必须对外唯一且稳定。
    static let temporaryNamePrefix = ".appports-write-"

    static func write(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        let directory = try openDescriptor(parent.path, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        defer { _ = close(directory) }
        let temporaryName = temporaryNamePrefix + UUID().uuidString
        let descriptor = openat(directory, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw failure(.createTemporaryRecord, url) }
        defer { _ = close(descriptor) }
        var published = false
        defer { if !published { _ = unlinkat(directory, temporaryName, 0) } }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw failure(.writeRecord, url, code: count == 0 ? EIO : errno) }
                offset += count
            }
        }
        try synchronize(descriptor, url: url, full: true)
        var existing = stat()
        if fstatat(directory, url.lastPathComponent, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG else { throw failure(.replaceNonRegularRecord, url, code: EINVAL) }
        } else if errno != ENOENT {
            throw failure(.inspectRecord, url)
        }
        try requireNamedObject(parent, descriptor: directory)
        guard renameat(directory, temporaryName, directory, url.lastPathComponent) == 0 else {
            throw failure(.publishRecord, url)
        }
        published = true
        try synchronize(directory, url: parent, full: true)
        try requireNamedObject(parent, descriptor: directory)
        try requireNamedObject(url, descriptor: descriptor)
    }

    /// Flushes file contents and metadata, followed by every containing
    /// directory and one device-cache barrier. Traversal does not follow links
    /// and refuses nested mounts or unsupported filesystem nodes.
    ///
    /// `barrier` selects how much durability the caller needs. A tree that is
    /// only published after its own verification does not need a device flush
    /// per file: a power cut leaves a destination the caller re-copies, never
    /// one it switches to. Every node still checks cancellation and reports
    /// progress, so a long flush can be stopped and is visible to the user.
    static func syncTree(at root: URL, excludingRootEntries: Set<String> = [],
                         allowParentAlias: Bool = false, barrier: TreeSyncBarrier = .full) throws {
        DataTransferSession.progress?.begin(.synchronizing)
        DataTransferSession.progress?.startTraversal(at: root)
        let descriptor = try openDescriptor(root.path, flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        defer { _ = close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw failure(.inspectTree, root) }
        try syncNode(descriptor, url: root, device: status.st_dev,
                     exclusions: excludingRootEntries, barrier: barrier)
        // The root always gets the device-cache barrier: it is the single
        // object whose durability the caller switches on.
        try synchronize(descriptor, url: root, full: true)
        try requireNamedObject(root, descriptor: descriptor)
        try syncDirectory(at: root.deletingLastPathComponent(), resolvingAlias: allowParentAlias)
        try requireNamedObject(root, descriptor: descriptor)
    }

    /// A configured home root may be an ordinary system alias. Callers must
    /// opt in for that exact root; both the alias entry and its resolved target
    /// stay anchored across the barrier. Record writes always remain no-follow.
    static func syncDirectory(at directory: URL, resolvingAlias: Bool = false) throws {
        if resolvingAlias {
            var named = stat()
            guard lstat(directory.path, &named) == 0 else { throw failure(.inspectDirectoryAlias, directory) }
            let resolved = directory.resolvingSymlinksInPath()
            let descriptor = try openDescriptor(resolved.path, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            defer { _ = close(descriptor) }
            try requireDirectoryAlias(directory, named: named, resolved: resolved, descriptor: descriptor)
            try synchronize(descriptor, url: directory, full: true)
            try requireDirectoryAlias(directory, named: named, resolved: resolved, descriptor: descriptor)
            return
        }
        let descriptor = try openDescriptor(directory.path, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        defer { _ = close(descriptor) }
        try synchronize(descriptor, url: directory, full: true)
        try requireNamedObject(directory, descriptor: descriptor)
    }

    private static func syncNode(_ descriptor: Int32, url: URL, device: dev_t, exclusions: Set<String> = [],
                                 barrier: TreeSyncBarrier = .full) throws {
        try Task.checkCancellation()
        DataTransferSession.progress?.activity(file: url.lastPathComponent)
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw failure(.inspectTreeNode, url) }
        guard value.st_dev == device else { throw failure(.syncNestedMount, url, code: EXDEV) }
        switch value.st_mode & S_IFMT {
        case S_IFREG, S_IFIFO:
            // A FIFO has persistent inode metadata, but no durable byte stream.
            // It was opened with O_NONBLOCK and is never read during the barrier.
            // `.contentDurable` still flushes every directory, so the file's
            // name and inode are committed by its parent's fsync.
            if barrier == .full { try synchronize(descriptor, url: url, full: false) }
        case S_IFDIR:
            let duplicate = dup(descriptor)
            guard duplicate >= 0 else { throw failure(.openDirectoryStream, url) }
            guard let stream = fdopendir(duplicate) else {
                let error = failure(.openDirectoryStream, url)
                _ = close(duplicate)
                throw error
            }
            defer { _ = closedir(stream) }
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw failure(.readDirectory, url) }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." || exclusions.contains(name) { continue }
                let childURL = url.appendingPathComponent(name)
                var child = stat()
                guard fstatat(descriptor, name, &child, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw failure(.inspectDirectoryEntry, childURL)
                }
                // Link data is committed by the containing directory's fsync.
                if child.st_mode & S_IFMT == S_IFLNK { continue }
                let childDescriptor = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard childDescriptor >= 0 else { throw failure(.openTreeNode, childURL) }
                var opened = stat()
                guard fstat(childDescriptor, &opened) == 0 else {
                    _ = close(childDescriptor)
                    throw failure(.inspectOpenedNode, childURL)
                }
                guard opened.st_dev == child.st_dev, opened.st_ino == child.st_ino else {
                    _ = close(childDescriptor)
                    throw failure(.verifyTreeNode, childURL, code: ESTALE)
                }
                defer { _ = close(childDescriptor) }
                try syncNode(childDescriptor, url: childURL, device: device,
                             exclusions: exclusions, barrier: barrier)
            }
            try synchronize(descriptor, url: url, full: false)
        default:
            throw failure(.syncUnsupportedNode, url, code: ENOTSUP)
        }
        DataTransferSession.progress?.activity(completedItem: true)
    }

    private static func synchronize(_ descriptor: Int32, url: URL, full: Bool) throws {
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw failure(.syncContent, url)
        }
        if full {
            while fcntl(descriptor, F_FULLFSYNC) != 0 {
                if errno == EINTR { continue }
                throw failure(.syncDeviceCache, url)
            }
        }
    }

    private static func openDescriptor(_ path: String, flags: Int32) throws -> Int32 {
        let descriptor = open(path, flags)
        guard descriptor >= 0 else { throw failure(.openForSync, URL(fileURLWithPath: path)) }
        return descriptor
    }

    private static func requireNamedObject(_ url: URL, descriptor: Int32) throws {
        var opened = stat(), current = stat()
        guard fstat(descriptor, &opened) == 0, lstat(url.path, &current) == 0 else {
            throw failure(.recheckSynchronizedObject, url)
        }
        guard opened.st_dev == current.st_dev, opened.st_ino == current.st_ino,
              opened.st_mode & S_IFMT == current.st_mode & S_IFMT else {
            throw failure(.verifySynchronizedObject, url, code: ESTALE)
        }
    }

    private static func requireDirectoryAlias(_ directory: URL, named: stat, resolved: URL, descriptor: Int32) throws {
        var currentName = stat(), currentTarget = stat(), opened = stat()
        guard lstat(directory.path, &currentName) == 0, stat(directory.path, &currentTarget) == 0,
              fstat(descriptor, &opened) == 0 else { throw failure(.recheckDirectoryAlias, directory) }
        guard named.st_dev == currentName.st_dev, named.st_ino == currentName.st_ino,
              named.st_mode & S_IFMT == currentName.st_mode & S_IFMT,
              opened.st_mode & S_IFMT == S_IFDIR,
              opened.st_dev == currentTarget.st_dev, opened.st_ino == currentTarget.st_ino else {
            throw failure(.verifyDirectoryAlias, directory, code: ESTALE)
        }
        try requireNamedObject(resolved, descriptor: descriptor)
    }

    /// Keep errno intact while selecting a translated operation description.
    private enum Operation {
        case createTemporaryRecord
        case writeRecord
        case replaceNonRegularRecord
        case inspectRecord
        case publishRecord
        case inspectTree
        case inspectDirectoryAlias
        case inspectTreeNode
        case syncNestedMount
        case openDirectoryStream
        case readDirectory
        case inspectDirectoryEntry
        case openTreeNode
        case inspectOpenedNode
        case verifyTreeNode
        case syncUnsupportedNode
        case syncContent
        case syncDeviceCache
        case openForSync
        case recheckSynchronizedObject
        case verifySynchronizedObject
        case recheckDirectoryAlias
        case verifyDirectoryAlias

        var localizedDescription: String {
            switch self {
            case .createTemporaryRecord: return "创建临时操作记录".localized
            case .writeRecord: return "写入操作记录".localized
            case .replaceNonRegularRecord: return "替换非普通文件的操作记录".localized
            case .inspectRecord: return "检查操作记录".localized
            case .publishRecord: return "保存操作记录".localized
            case .inspectTree: return "检查同步目录树".localized
            case .inspectDirectoryAlias: return "检查目录别名".localized
            case .inspectTreeNode: return "检查同步目录项".localized
            case .syncNestedMount: return "同步嵌套挂载点".localized
            case .openDirectoryStream: return "打开目录读取流".localized
            case .readDirectory: return "读取同步目录".localized
            case .inspectDirectoryEntry: return "检查目录子项".localized
            case .openTreeNode: return "打开同步目录项".localized
            case .inspectOpenedNode: return "检查已打开的目录项".localized
            case .verifyTreeNode: return "确认同步目录项未改变".localized
            case .syncUnsupportedNode: return "同步不支持的文件类型".localized
            case .syncContent: return "同步文件内容（fsync）".localized
            case .syncDeviceCache: return "同步存储缓存（F_FULLFSYNC）".localized
            case .openForSync: return "打开同步对象".localized
            case .recheckSynchronizedObject: return "复查同步对象".localized
            case .verifySynchronizedObject: return "确认同步对象未移动或改变".localized
            case .recheckDirectoryAlias: return "复查目录别名".localized
            case .verifyDirectoryAlias: return "确认目录别名未移动或改变".localized
            }
        }
    }

    private static func failure(_ operation: Operation, _ url: URL, code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSFilePathErrorKey: url.path,
            NSLocalizedDescriptionKey: String(format: "%@失败：%@\n系统错误：%@".localized, operation.localizedDescription, url.path, String(cString: strerror(code)))
        ])
    }

    // MARK: - 回收写入中断遗留的临时文件

    /// 同一目录两次回收之间的最小间隔。残留不会自己消失，但也不能让回收
    /// 变成每次读取都要付的成本，因此按目录分别节流。
    static let temporaryPruneInterval: TimeInterval = 300
    /// 临时文件的最短静默期。刚写下的临时文件属于正在进行的写入，
    /// 只有明显超龄的才可能是中断残留。
    static let temporaryGracePeriod: TimeInterval = 60

    private static let temporaryPruneLock = NSLock()
    nonisolated(unsafe) private static var temporaryPrunePasses: [String: TimeInterval] = [:]

    /// 回收本目录下写入中断遗留的临时文件，返回删除条数。
    ///
    /// `write` 用 `defer` 在失败时删除临时文件，但进程被强制退出、崩溃或断电时
    /// `defer` 不会执行，残留只能由目录所有者另行回收。这就是这个入口存在的
    /// 唯一理由：它清理的是「本该由自己删掉、但没机会删」的文件。
    ///
    /// 判定条件与写入时保持一致：本用户、普通文件、前缀完全匹配、超过静默期。
    /// 任何一步失败都按「保留」处理，绝不向调用方抛错 —— 回收是可选的后台收益，
    /// 不能因为清理失败而影响读取路径。
    ///
    /// 目录不存在（例如外置盘未挂载）时返回 0，这是正常情况而不是错误。
    @discardableResult
    static func pruneAbandonedTemporaries(in directory: URL,
                                          olderThan gracePeriod: TimeInterval = temporaryGracePeriod,
                                          limit: Int = 256,
                                          now: TimeInterval = Date().timeIntervalSince1970) -> Int {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return 0 }
        defer { _ = close(descriptor) }
        var directoryInfo = stat()
        guard fstat(descriptor, &directoryInfo) == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_uid == getuid() else { return 0 }
        let duplicate = dup(descriptor)
        guard duplicate >= 0, let entries = fdopendir(duplicate) else {
            if duplicate >= 0 { _ = close(duplicate) }
            return 0
        }
        defer { _ = closedir(entries) }

        var removed = 0
        var scanned = 0
        // 同前缀的文件正常只有几个。但异常或人为堆积时不能退化成整目录遍历，
        // 否则一次回收就可能变成「读一遍所有记录」的代价。
        let scanLimit = max(limit * 8, 512)
        while removed < limit, scanned < scanLimit {
            errno = 0
            guard let entry = readdir(entries) else { break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name.hasPrefix(temporaryNamePrefix) else { continue }
            scanned += 1

            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid() else { continue }
            let modified = TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
            guard now - modified >= gracePeriod else { continue }
            if unlinkat(descriptor, name, 0) == 0 { removed += 1 }
        }
        return removed
    }

    /// 带进程内节流的回收入口，供各存储的读取入口调用一次。
    ///
    /// 节流按目录路径共享，因此同一个目录被多处调用时也只会扫一次；主程序与
    /// 挂载代理是两个进程，各自持有一份，靠 300 秒的稀疏间隔自然错开。
    @discardableResult
    static func pruneAbandonedTemporariesIfNeeded(in directory: URL,
                                                  now: TimeInterval = Date().timeIntervalSince1970) -> Int {
        let key = directory.standardizedFileURL.path
        temporaryPruneLock.lock()
        let lastPass = temporaryPrunePasses[key]
        if let lastPass, now - lastPass < temporaryPruneInterval {
            temporaryPruneLock.unlock()
            return 0
        }
        temporaryPrunePasses[key] = now
        temporaryPruneLock.unlock()
        return pruneAbandonedTemporaries(in: directory, now: now)
    }
}
