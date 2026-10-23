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
            case .unreachable(let detail): return "特权助手不可用：" + detail
            case .timedOut: return "特权助手响应超时"
            case .refused(let detail): return "特权助手拒绝执行：" + detail
            case .staleHelper(let installed):
                return "特权助手运行的仍是旧镜像（\(installed)），重装后才能使用"
            }
        }
    }

    struct Handshake: Sendable {
        let version: String
        let cdHash: String
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

    /// 握手：确认守护进程可用，且跑的是与当前客户端一致的镜像。
    func handshake() throws -> Handshake {
        guard Self.isInstalled else { throw ClientError.unreachable("尚未安装") }
        let handshake = try perform(timeout: handshakeTimeout) { proxy, box in
            proxy.handshake { version, cdHash in
                box.store(.success(Handshake(version: version, cdHash: cdHash)))
            }
        }
        guard handshake.version == PrivilegedHelperConstants.protocolVersion else {
            throw ClientError.staleHelper(installed: handshake.version)
        }
        // 两边都有 cdhash 时才比对：开发构建可能根本没有 cdhash，那由守护进程一侧
        // 的签名校验把关，这里不重复判断。
        if let own = Self.selfCDHash, !handshake.cdHash.isEmpty, own != handshake.cdHash {
            throw ClientError.staleHelper(installed: String(handshake.cdHash.prefix(12)))
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
            throw ClientError.refused("命令不在挂载白名单内")
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
            throw ClientError.unreachable("无法转换为助手接口")
        }
        body(typed, box)
        guard box.wait(timeout) else {
            invalidate()
            throw ClientError.timedOut
        }
        switch box.value {
        case .success(let value): return value
        case .failure(let error): throw error
        case nil: throw ClientError.unreachable("助手没有返回结果")
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

    private static let selfCDHash: String? = {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: 0), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let hash = dictionary[kSecCodeInfoUnique as String] as? Data else { return nil }
        return hash.base64EncodedString()
    }()
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
