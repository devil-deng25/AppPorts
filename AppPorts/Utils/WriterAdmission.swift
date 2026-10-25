import Darwin
import Foundation

/// This identity comes from the kernel, not the version currently installed at
/// the executable's path. Replacing an app on disk does not upgrade its process.
struct WriterProcessIdentity: Codable, Equatable, Sendable {
    let processID: Int32
    let userID: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executablePath: String
}

struct WriterPresence: Codable, Equatable, Sendable {
    let process: WriterProcessIdentity
    let dataDirectoryPath: String
    let capabilities: Set<String>
}

enum WriterAdmissionError: LocalizedError {
    case incompatibleWriter(WriterProcessIdentity, String)
    case inspectionFailed(Int32?, String)
    case defaultDataInTests

    var errorDescription: String? {
        switch self {
        case let .incompatibleWriter(process, reason):
            // 阻断时用户最缺的是「这个 PID 从哪来、怎么退」。旧镜像不会自己消失，
            // 所以把启动时间与磁盘侧被替换的事实一并写进提示。
            let base = String(format: "仍有无法确认写入兼容性的 AppPorts 进程（PID %@，%@）：%@。请退出该进程后重试；现有副本已保留。".localized,
                              String(process.processID), process.executablePath, reason)
            let hint = WriterAdmission.quitHint(for: process)
            return hint.isEmpty ? base : base + " " + hint
        case let .inspectionFailed(pid, reason):
            if let pid {
                return String(format: "无法确认运行中的 AppPorts 写入进程（PID %@）：%@。已暂停写入并保留现有副本。".localized,
                              String(pid), reason)
            }
            return String(format: "无法确认运行中的 AppPorts 写入进程：%@。已暂停写入并保留现有副本。".localized, reason)
        case .defaultDataInTests:
            return "测试进程不能写入用户的 AppPorts 数据目录；请注入独立测试目录。".localized
        }
    }
}

/// Small, process-lifetime capability registration. This is an admission check
/// for live writers, not a schema/version gate or an operation journal. A stale
/// registration cannot authorize a reused PID or another data directory.
final class WriterAdmission {
    static let requiredCapability = "appports-verified-writer-v7-disk-ejection"
    /// 单次最多删除多少条失效登记，避免积压很多时把启动路径拖成一次大删除。
    static let presencePruneLimit = 512
    /// 单次最多查看多少个目录项。积压超过这个数时只清理窗口内的部分，
    /// 剩余部分由后续轮次继续，任何一轮都不会全量遍历整个目录。
    static let presenceScanLimit = 2_048
    /// 两次清理之间的最小间隔。写入路径每次 `prepareForWrite` 都会重新登记，
    /// 没有这个间隔就会在每次写入前重复扫描目录。
    static let presencePruneInterval: TimeInterval = 300
    /// 失效登记的最短静默期。判定「进程已退出」与真正删除之间，系统可能把
    /// 同一个 PID 分配给刚启动的实例并写下新登记；新登记的时间戳是「现在」，
    /// 落在静默期内，因此不会被误删。只有真正的历史残留才会超过这个年龄。
    static let presenceGracePeriod: TimeInterval = 60
    static var defaultDataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppPorts", isDirectory: true)
    }

    /// 主程序与挂载代理各自独立启动，共用同一个节流闸门才能避免两边同时扫目录。
    private static let sharedPruneGate = PresencePruneGate()
    private static var live: WriterAdmission {
        WriterAdmission(dataDirectory: defaultDataDirectory, pruneGate: { sharedPruneGate.admit(at: $0) })
    }
    private let dataDirectory: URL
    private let currentProcess: () throws -> WriterProcessIdentity
    private let processSnapshot: () throws -> [WriterProcessIdentity]
    private let clock: () -> TimeInterval
    private let waitForRegistration: (TimeInterval) -> Void
    private let pruneGate: ((TimeInterval) -> Bool)?

    init(dataDirectory: URL,
         currentProcess: @escaping () throws -> WriterProcessIdentity = { try currentProcessIdentity() },
         processSnapshot: @escaping () throws -> [WriterProcessIdentity] = { try runningAppPortsProcesses() },
         clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
         waitForRegistration: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         pruneGate: ((TimeInterval) -> Bool)? = nil) {
        self.dataDirectory = Self.canonical(dataDirectory)
        self.currentProcess = currentProcess
        self.processSnapshot = processSnapshot
        self.clock = clock
        self.waitForRegistration = waitForRegistration
        self.pruneGate = pruneGate
    }

    /// Called before main/--mount-agent startup. XCTest uses injected datasets
    /// and must not create even presence metadata in the user's real dataset.
    static func registerCurrentWriter() throws {
        guard !isRunningUnitTests else { return }
        try live.registerCurrentProcess()
    }

    /// Production stores share this one dataset. Injected stores are isolated;
    /// tests of admission itself use an instance with a synthetic process list.
    static func recheck(dataDirectory: URL) throws {
        guard canonical(dataDirectory) == canonical(defaultDataDirectory) else { return }
        guard !isRunningUnitTests else { throw WriterAdmissionError.defaultDataInTests }
        try live.checkCurrentWriters()
    }

    static func prepareForWrite(dataDirectory: URL) throws {
        guard canonical(dataDirectory) == canonical(defaultDataDirectory) else { return }
        guard !isRunningUnitTests else { throw WriterAdmissionError.defaultDataInTests }
        try live.registerCurrentProcess()
        try live.checkCurrentWriters()
    }

    func registerCurrentProcess() throws {
        let process = try currentProcess()
        let presence = WriterPresence(process: process, dataDirectoryPath: dataDirectory.path,
                                      capabilities: [Self.requiredCapability])
        try preparePresenceDirectory()
        if (try? readPresence(processID: process.processID)) != presence {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try DurableFileIO.write(try encoder.encode(presence), to: presenceURL(processID: process.processID))
        }
        pruneStalePresence(keeping: process.processID)
    }

    /// 退出的实例从不注销自己的登记。长期使用后登记目录会积累上万条记录，
    /// 因此每次登记后按内核身份清理一轮。
    ///
    /// 一条登记被判为失效，必须同时满足两个条件：
    /// 1. 该 PID 已不存在（`kill` 返回 ESRCH），或当前占用该 PID 的进程启动时间
    ///    与身份与登记不符（PID 被复用）；
    /// 2. 文件已静默超过 `presenceGracePeriod`。
    ///
    /// 第二个条件不是保险，而是消除竞态：从「判定进程已退出」到「真正 unlink」
    /// 之间存在窗口，系统可能在这个窗口里把该 PID 分配给刚启动的实例并写下新
    /// 登记。新登记的时间戳是「现在」，落在静默期内，因此不会被误删；只有真正
    /// 的历史残留才会超过这个年龄。反过来，PID 被复用后旧登记要么被新登记覆盖
    /// （时间戳变新），要么因身份不符而被清理，两种都不会误判。
    ///
    /// 目录条目用 `readdir` 增量读取、按 `unlinkat` 相对目录描述符删除，不整目录
    /// 列成 URL 数组，也不跟随符号链接。只处理本用户 0700 目录下的两种普通文件：
    /// `<pid>.plist` 与写入中断遗留的 `.appports-write-*` 临时文件。迁移数据、
    /// 挂载记录与恢复副本不在这个目录，也不在这个函数的作用范围内。
    ///
    /// 任何一步失败都按「保留」处理并直接返回：清理是可选的后台收益，既不能
    /// 阻断启动，也不能让写入路径因为清理失败而改变判定结果。
    private func pruneStalePresence(keeping currentProcessID: Int32) {
        let now = clock()
        if let pruneGate, !pruneGate(now) { return }

        let directory = open(presenceDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return }
        defer { _ = close(directory) }
        var directoryInfo = stat()
        guard fstat(directory, &directoryInfo) == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_uid == getuid() else { return }
        let duplicate = dup(directory)
        guard duplicate >= 0, let entries = fdopendir(duplicate) else {
            if duplicate >= 0 { _ = close(duplicate) }
            return
        }
        defer { _ = closedir(entries) }

        var scanned = 0
        var removed = 0
        while scanned < Self.presenceScanLimit, removed < Self.presencePruneLimit {
            errno = 0
            guard let entry = readdir(entries) else { break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard let candidate = Self.pruneCandidate(name) else { continue }
            scanned += 1
            // 当前实例自己的登记由本次写入维护，不参与清理。
            if case let .presence(processID) = candidate, processID == currentProcessID { continue }

            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid() else { continue }
            let modified = TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
            guard now - modified >= Self.presenceGracePeriod else { continue }

            switch candidate {
            case .abandonedWrite:
                // 写入中断的临时文件没有登记语义，超龄即可回收。
                if unlinkat(directory, name, 0) == 0 { removed += 1 }
            case let .presence(processID):
                guard isStaleRegistration(processID: processID) else { continue }
                if unlinkat(directory, name, 0) == 0 { removed += 1 }
            }
        }
    }

    private enum PruneCandidate {
        case presence(Int32)
        case abandonedWrite
    }

    private static func pruneCandidate(_ name: String) -> PruneCandidate? {
        if name.hasPrefix(DurableFileIO.temporaryNamePrefix) { return .abandonedWrite }
        guard name.hasSuffix(".plist") else { return nil }
        let stem = String(name.dropLast(".plist".count))
        // 只接受规范十进制写法，避免把 `007.plist`、`+7.plist` 这类名字
        // 当成合法的 PID 登记。
        guard let processID = Int32(stem), processID > 0, String(processID) == stem else { return nil }
        return .presence(processID)
    }

    private func isStaleRegistration(processID: Int32) -> Bool {
        if Self.processHasExited(processID) { return true }
        guard let presence = try? readPresence(processID: processID),
              let live = try? Self.identity(processID: processID) else { return false }
        return presence.process != live
    }

    /// 不可兼容写入者的处置提示：说明它是不是更新前启动的旧镜像，并给出退出方法。
    static func quitHint(for process: WriterProcessIdentity) -> String {
        let started = Date(timeIntervalSince1970: Double(process.startSeconds)
                           + Double(process.startMicroseconds) / 1_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "MM-dd HH:mm"
        var hint = String(format: "该实例启动于 %@。".localized, formatter.string(from: started))
        if let modified = executableModificationDate(process.executablePath), modified > started.addingTimeInterval(1) {
            hint += "磁盘上的 AppPorts 在此之后被替换过，它仍在运行替换前的旧镜像，不会自行退出。".localized
        }
        hint += String(format: "请在菜单栏的 AppPorts 图标中选择「退出」，或在终端执行 kill %@，然后重试。".localized,
                       String(process.processID))
        return hint
    }

    private static func executableModificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    func checkCurrentWriters() throws {
        var registrationRetries = 0
        while true {
            let processes = try processSnapshot()
            let current = try currentProcess()
            guard processes.contains(current) else {
                throw WriterAdmissionError.inspectionFailed(current.processID, "进程列表中缺少当前写入实例".localized)
            }
            var pending: (process: WriterProcessIdentity, reason: String)?
            for process in processes {
                let presence: WriterPresence
                do { presence = try readPresence(processID: process.processID) }
                catch {
                    pending = (process, "该运行实例没有可验证的写入能力登记".localized)
                    break
                }
                guard presence.process == process else {
                    pending = (process, "登记与当前进程身份或启动时间不符".localized)
                    break
                }
                guard presence.dataDirectoryPath == dataDirectory.path else {
                    throw WriterAdmissionError.incompatibleWriter(process, "登记属于另一个数据目录".localized)
                }
                guard presence.capabilities.contains(Self.requiredCapability) else {
                    throw WriterAdmissionError.incompatibleWriter(process, "该运行实例不支持当前安全写入约定".localized)
                }
            }
            guard let pending else { return }
            let failure = WriterAdmissionError.incompatibleWriter(pending.process, pending.reason)
            guard registrationRetries < 40 else { throw failure }
            registrationRetries += 1

            // A launchd agent is visible to libproc before its Swift entry point
            // publishes its presence. Recheck the live identity and allow that
            // registration to settle; never infer capability from its file path.
            // An agent that exited during inspection is no longer a writer.
            guard try processSnapshot().contains(pending.process) else { continue }
            let started = Double(pending.process.startSeconds)
                + Double(pending.process.startMicroseconds) / 1_000_000
            let age = clock() - started
            guard age >= 0, age < 1 else { throw failure }
            waitForRegistration(min(0.025, 1 - age))
            // No write has been admitted. The next pass validates every live
            // instance again, including any PID reuse or newly started writer.
        }
    }

    func presenceURL(processID: Int32) -> URL {
        presenceDirectory.appendingPathComponent(String(processID) + ".plist")
    }

    private var presenceDirectory: URL { dataDirectory.appendingPathComponent(".writer-presence", isDirectory: true) }

    private func preparePresenceDirectory() throws {
        try FileManager.default.createDirectory(at: presenceDirectory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(presenceDirectory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid() else {
            throw WriterAdmissionError.inspectionFailed(nil, "写入能力登记目录的身份无法确认".localized)
        }
    }

    private func readPresence(processID: Int32) throws -> WriterPresence {
        let url = presenceURL(processID: processID)
        let directory = open(presenceDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        defer { _ = close(directory) }
        var directoryInfo = stat()
        guard fstat(directory, &directoryInfo) == 0, directoryInfo.st_uid == getuid() else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let descriptor = openat(directory, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_size > 0, info.st_size <= 65_536 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var offset = 0
        try bytes.withUnsafeMutableBytes { buffer in
            while offset < buffer.count {
                let count = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw CocoaError(.fileReadCorruptFile) }
                offset += count
            }
        }
        return try PropertyListDecoder().decode(WriterPresence.self, from: Data(bytes))
    }

    static func currentProcessIdentity() throws -> WriterProcessIdentity {
        try identity(processID: getpid())
    }

    /// libproc also sees an executable launched directly as --mount-agent; a
    /// list of GUI applications alone would miss that writer. Bundle identity
    /// is used only to recognize candidates, never to infer their capability.
    static func runningAppPortsProcesses(processIDs: [Int32]? = nil,
        inspect: ((Int32) -> (proc_bsdinfo?, String?))? = nil) throws -> [WriterProcessIdentity] {
        let pids = try processIDs ?? currentUserProcessIDs()
        var result: [WriterProcessIdentity] = []
        for pid in pids {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            let infoResult: Int32
            let path: String?
            if let inspect {
                let observed = inspect(pid)
                if let value = observed.0 { info = value; infoResult = size } else { infoResult = 0 }
                path = observed.1
            } else {
                infoResult = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
                path = executablePath(processID: pid)
            }
            if infoResult != size, processHasExited(pid) { continue }
            let name = withUnsafeBytes(of: info.pbi_name) { bytes in
                String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            let namedAppPorts = name.caseInsensitiveCompare("AppPorts") == .orderedSame
            let relevant = pid == getpid() || namedAppPorts || path.map(isAppPortsExecutable) == true
            // Unrelated processes can exit or become unreadable between the
            // UID list and libproc calls. Only identified AppPorts candidates
            // participate in writer admission; unknown system activity must
            // not abort a transfer or prevent its journal from being saved.
            guard relevant else { continue }
            guard infoResult == size, let path else {
                if processHasExited(pid) { continue }
                throw WriterAdmissionError.inspectionFailed(pid, "运行实例的启动时间或可执行文件路径暂不可读".localized)
            }
            // Detect a PID disappearing/reappearing while it is inspected.
            let observed = makeIdentity(processID: pid, info: info, path: path)
            do {
                guard try identity(processID: pid) == observed else {
                    throw WriterAdmissionError.inspectionFailed(pid, "检查期间进程身份发生变化".localized)
                }
            } catch {
                if processHasExited(pid) { continue }
                throw error
            }
            result.append(observed)
        }
        return result.sorted { $0.processID < $1.processID }
    }

    private static func currentUserProcessIDs() throws -> [Int32] {
        let stride = MemoryLayout<Int32>.stride
        var capacity = max(128, Int(proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)) / stride + 64)
        for _ in 0..<4 {
            var buffer = [Int32](repeating: 0, count: capacity)
            let byteCount = buffer.withUnsafeMutableBytes {
                proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, Int32($0.count))
            }
            guard byteCount > 0 else {
                throw WriterAdmissionError.inspectionFailed(nil, "无法列出当前用户的运行进程".localized)
            }
            let count = Int(byteCount) / stride
            if count < capacity { return Array(Set(buffer.prefix(count).filter { $0 > 0 })).sorted() }
            capacity *= 2
        }
        throw WriterAdmissionError.inspectionFailed(nil, "运行进程列表持续变化，无法完成兼容检查".localized)
    }

    private static func identity(processID: Int32) throws -> WriterProcessIdentity {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, size) == size,
              let path = executablePath(processID: processID) else {
            throw WriterAdmissionError.inspectionFailed(processID, "无法读取内核进程身份".localized)
        }
        return makeIdentity(processID: processID, info: info, path: path)
    }

    private static func makeIdentity(processID: Int32, info: proc_bsdinfo, path: String) -> WriterProcessIdentity {
        WriterProcessIdentity(processID: processID, userID: info.pbi_uid,
                              startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec,
                              executablePath: path)
    }

    private static func executablePath(processID: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a C expression macro not imported by Swift.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes { proc_pidpath(processID, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL.path
    }

    private static func isAppPortsExecutable(_ path: String) -> Bool {
        let executable = URL(fileURLWithPath: path)
        if executable.lastPathComponent.caseInsensitiveCompare("AppPorts") == .orderedSame { return true }
        var ancestor = executable.deletingLastPathComponent()
        while ancestor.path != "/" {
            if ancestor.pathExtension.lowercased() == "app" {
                return Bundle(url: ancestor)?.bundleIdentifier == "com.shimoko.AppPorts"
            }
            ancestor.deleteLastPathComponent()
        }
        return false
    }

    private static func processHasExited(_ pid: Int32) -> Bool { kill(pid, 0) != 0 && errno == ESRCH }
    private static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    private static var isRunningUnitTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}

/// 清理节流。主程序与挂载代理各自启动、各自登记，共用同一个闸门；
/// 单次判定失败不影响状态，最坏情况是少清一轮，不会删错东西。
private final class PresencePruneGate {
    private let lock = NSLock()
    private var lastPass: TimeInterval?

    func admit(at now: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let lastPass, now - lastPass < WriterAdmission.presencePruneInterval { return false }
        lastPass = now
        return true
    }
}
