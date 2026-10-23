import Foundation
import Security

/// 特权助手客户端。
///
/// 只做三件事：连上 `com.shimoko.AppPorts.privileged-helper`、握手确认跑的是当前这份
/// 二进制、把一条已通过白名单的命令送过去。任何一步不成立都抛错，由调用方退回
/// 原来的一次性授权——助手是「少弹密码」的优化，不是唯一通路。
final class PrivilegedHelperClient: @unchecked Sendable {
    static let shared = PrivilegedHelperClient()

    enum ClientError: LocalizedError {
        case unreachable(String)
        case timedOut
        case refused(String)
        case staleHelper(installed: String)

        var errorDescription: String? {
            switch self {
            case .unreachable(let detail):
                return String(format: "特权助手不可用：%@".localized, detail)
            case .timedOut: return "特权助手响应超时".localized
            case .refused(let detail):
                return String(format: "特权助手拒绝执行：%@".localized, detail)
            case .staleHelper(let installed):
                return String(format: "特权助手与当前构建不匹配（%@），重装后才能使用".localized, installed)
            }
        }
    }

    struct Handshake: Sendable {
        let version: String
        /// 助手的签名身份指纹，见 `CodeIdentity`。
        let fingerprint: String
    }

    private let lock = NSLock()
    private var connection: NSXPCConnection?

    /// 单条命令的等待上限；磁盘命令自身的超时更短，这里只兜住连接层挂死。
    private let commandTimeout: TimeInterval = 60
    /// 握手只确认「在不在、是不是这份」，等太久没有意义。
    private let handshakeTimeout: TimeInterval = 6

    private init() {}

    /// 助手是否已被安装（只看 LaunchDaemon 描述文件在不在）。
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: PrivilegedHelperConstants.daemonPlistPath)
    }

    /// 握手：确认守护进程可用，且与当前客户端属于同一个签名身份、同一版协议。
    ///
    /// 比的是签名身份而不是 cdhash：同一张证书重新构建出来的应用不必让用户重装助手。
    /// 只有 adhoc 构建没有证书，指纹才会随镜像变化——那正是它需要重装的情况。
    func handshake() throws -> Handshake {
        guard Self.isInstalled else { throw ClientError.unreachable("尚未安装".localized) }
        let handshake = try perform(timeout: handshakeTimeout) { proxy, box in
            proxy.handshake { version, fingerprint in
                box.store(.success(Handshake(version: version, fingerprint: fingerprint)))
            }
        }
        guard handshake.version == PrivilegedHelperConstants.protocolVersion else {
            throw ClientError.staleHelper(installed: handshake.version)
        }
        // 两边都读得到指纹时才比对：读不到就意味着签名信息不完整，
        // 这种情况由守护进程一侧的有效性校验把关，这里不重复判断。
        if let own = Self.selfFingerprint, !handshake.fingerprint.isEmpty, own != handshake.fingerprint {
            throw ClientError.staleHelper(installed: CodeIdentity.shortKind(handshake.fingerprint))
        }
        return handshake
    }

    /// 助手是否可以立即接活（不弹密码）。
    var isReady: Bool {
        (try? handshake()) != nil
    }

    /// 执行一条挂载类命令。命令不在白名单里时直接抛错，不打扰助手。
    func run(executable: String, arguments: [String]) throws -> ShellCommandResult {
        guard PrivilegedMountCommand.isSupported(executable: executable, arguments: arguments) else {
            throw ClientError.refused("命令不在挂载白名单内".localized)
        }
        let reply = try perform(timeout: commandTimeout) { proxy, box in
            proxy.runMountCommand(executable, arguments: arguments) { status, output, error in
                box.store(.success((status, output, error)))
            }
        }
        let (status, output, error) = reply
        guard status >= 0 else {
            throw ClientError.refused(String(decoding: error, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return ShellCommandResult(status: status, standardOutput: output, standardError: error, timedOut: false)
    }

    /// 断开当前连接。安装、重装、卸载之后必须调用，否则会继续用旧连接。
    func invalidate() {
        lock.lock()
        let existing = connection
        connection = nil
        lock.unlock()
        existing?.invalidate()
    }

    /// 发起一次调用并等待结果。连接层错误也走同一个等待点，避免「连不上却等满超时」。
    private func perform<T>(timeout: TimeInterval,
                            _ body: (AppPortsPrivilegedHelperProtocol, ReplyBox<Result<T, Error>>) -> Void) throws -> T {
        let connection = try makeConnection()
        let box = ReplyBox<Result<T, Error>>()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            box.store(.failure(ClientError.unreachable(error.localizedDescription)))
        }
        guard let typed = proxy as? AppPortsPrivilegedHelperProtocol else {
            invalidate()
            throw ClientError.unreachable("无法转换为助手接口".localized)
        }
        body(typed, box)
        guard box.wait(timeout) else {
            invalidate()
            throw ClientError.timedOut
        }
        switch box.value {
        case .success(let value): return value
        case .failure(let error): throw error
        case nil: throw ClientError.unreachable("助手没有返回结果".localized)
        }
    }

    private func makeConnection() throws -> NSXPCConnection {
        lock.lock()
        if let connection {
            lock.unlock()
            return connection
        }
        lock.unlock()
        let created = NSXPCConnection(machServiceName: PrivilegedHelperConstants.machService, options: [])
        created.remoteObjectInterface = NSXPCInterface(with: AppPortsPrivilegedHelperProtocol.self)
        created.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.connection = nil
            self.lock.unlock()
        }
        created.resume()
        lock.lock()
        // 并发建连时保留先到的那一个，多余的直接丢掉。
        if let existing = connection {
            lock.unlock()
            created.invalidate()
            return existing
        }
        connection = created
        lock.unlock()
        return created
    }

    /// 自身镜像的签名身份指纹，比较逻辑见 `CodeIdentity`。
    private static let selfFingerprint: String? = CodeIdentity.currentFingerprint
}

/// XPC 回调在别的队列上执行，用一把锁把结果交回等待方。
/// 不用闭包捕获可变变量，是为了在更严格的并发检查下也不需要改代码。
private final class ReplyBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var stored: T?

    func store(_ value: T) {
        lock.lock()
        if stored == nil { stored = value }
        lock.unlock()
        semaphore.signal()
    }

    func wait(_ timeout: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }

    var value: T? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
