import Foundation
import Security

/// 以 root 身份运行的常驻助手（LaunchDaemon）。
///
/// 设计前提：不接受任何「任意命令」，只接受 `PrivilegedMountCommand` 白名单里的
/// 挂载类命令；并且只接受由同一份 AppPorts 镜像发来的调用。任何一项校验失败都不执行、
/// 不解释原因，只回一条拒绝，客户端随后退回一次性授权（会弹密码）而不是失败退出。
enum PrivilegedHelperService {
    /// 进程入口。返回 false 表示当前不是助手模式，调用方应继续走 GUI 启动流程。
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.dropFirst().first == PrivilegedHelperConstants.launchArgument else {
            return false
        }
        // 只有 launchd 以 root 拉起时才提供特权。手动以普通用户执行同一条命令时
        // 直接退出，避免出现「自称助手、其实没有特权」的假进程。
        guard geteuid() == 0 else {
            FileHandle.standardError.write(Data("AppPorts helper requires root\n".utf8))
            exit(EXIT_FAILURE)
        }
        serve()
    }

    /// 常驻循环。永不返回。
    private static func serve() -> Never {
        let listener = NSXPCListener(machServiceName: PrivilegedHelperConstants.machService)
        let delegate = ListenerDelegate()
        self.delegate = delegate
        listener.delegate = delegate
        listener.resume()
        dispatchMain()
    }

    /// `NSXPCListener` 不持有 delegate，这里必须自己保住它，否则第一次连接前就被回收。
    private static var delegate: ListenerDelegate?

    /// 守护进程的日志只写标准错误，由 launchd 收进统一日志。
    ///
    /// 刻意不接 `AppLogger`：那个单例会读 `UserDefaults`、按当前用户定位日志目录，
    /// 在 root 守护进程里既写不到用户能看的位置，也让特权进程多做了一堆与己无关的事。
    /// 排查时用 `log show --predicate 'process == "AppPorts"'`。
    static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            guard PeerTrust.isTrusted(connection: connection) else {
                PrivilegedHelperService.log("rejected untrusted connection from pid "
                    + String(connection.processIdentifier))
                return false
            }
            connection.exportedInterface = NSXPCInterface(with: AppPortsPrivilegedHelperProtocol.self)
            connection.exportedObject = HelperImplementation()
            connection.resume()
            return true
        }
    }

    /// 导出给客户端的实现。
    private final class HelperImplementation: NSObject, AppPortsPrivilegedHelperProtocol {
        func handshake(reply: @escaping (String, String) -> Void) {
            reply(PrivilegedHelperConstants.protocolVersion, PeerTrust.selfFingerprint ?? "")
        }

        func runMountCommand(_ executable: String, arguments: [String],
                             reply: @escaping (Int32, Data, Data) -> Void) {
            guard let validated = PrivilegedMountCommand.validate(executable: executable, arguments: arguments) else {
                PrivilegedHelperService.log("refused command outside the mount whitelist: "
                    + executable + " " + arguments.joined(separator: " "))
                reply(-1, Data(), Data("command outside the mount whitelist\n".utf8))
                return
            }
            PrivilegedHelperService.log("running: " + executable + " " + validated.joined(separator: " "))
            // 磁盘命令最长可能跑满命令超时；放到后台队列，避免占住这条连接的队列
            // 让握手、状态查询一起排队。
            DispatchQueue.global(qos: .userInitiated).async {
                let result = execute(executable: executable, arguments: validated)
                reply(result.status, result.standardOutput, result.standardError)
            }
        }
    }

    /// 用临时文件收集输出：管道在输出超过缓冲时会和 `waitUntilExit` 互相等待。
    private static func execute(executable: String, arguments: [String]) -> ShellCommandResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppPorts-helper-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("stdout")
        let errorURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: outputURL),
              let error = try? FileHandle(forWritingTo: errorURL) else {
            return ShellCommandResult(status: -1, standardOutput: Data(),
                                      standardError: Data("helper could not open capture files\n".utf8),
                                      timedOut: false)
        }
        defer {
            try? output.close()
            try? error.close()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        // 不继承调用方的环境：PATH 之类的变量不该影响 root 命令的解析。
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        do {
            try process.run()
        } catch {
            return ShellCommandResult(status: -1, standardOutput: Data(),
                                      standardError: Data((error.localizedDescription + "\n").utf8),
                                      timedOut: false)
        }
        let deadline = Date().addingTimeInterval(120)
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                timedOut = true
                break
            }
            usleep(50_000)
        }
        process.waitUntilExit()
        try? output.synchronize()
        try? error.synchronize()
        return ShellCommandResult(status: process.terminationStatus,
                                  standardOutput: (try? Data(contentsOf: outputURL)) ?? Data(),
                                  standardError: (try? Data(contentsOf: errorURL)) ?? Data(),
                                  timedOut: timedOut)
    }
}

/// 调用方身份校验。
///
/// 两步：
/// 1. `SecCodeCheckValidity` 确认调用方的签名本身有效——被改写过的副本在这一步出局；
/// 2. 把调用方的签名身份压成指纹（`CodeIdentity`），与自己这份镜像逐字比较。
///
/// 用签名身份而不是 cdhash，是因为 cdhash 每次重新构建都会变：过去只要出一次新包，
/// 已经装好的助手就把用户的新应用当成陌生人。指纹在「同一张证书签的」这一层是稳定的，
/// Developer ID 或本机自签证书签出来的构建因此可以一直用下去；adhoc 构建没有证书，
/// 指纹只能退回 cdhash，重新构建后仍需重装——这是签名方式本身决定的，不是这里的取舍。
enum PeerTrust {
    /// 自身镜像的签名身份指纹。
    static let selfFingerprint: String? = CodeIdentity.currentFingerprint

    static func isTrusted(connection: NSXPCConnection) -> Bool {
        let processIdentifier = connection.processIdentifier
        guard processIdentifier > 0 else { return false }
        let attributes = [kSecGuestAttributePid as String: processIdentifier] as CFDictionary
        var peer: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(rawValue: 0), &peer) == errSecSuccess,
              let peer else { return false }
        // 调用方的签名必须先是有效的：被改写过的副本在这一步就出局。
        guard SecCodeCheckValidity(peer, SecCSFlags(rawValue: 0), nil) == errSecSuccess else { return false }

        guard let own = selfFingerprint,
              let peerSnapshot = CodeIdentity.snapshot(for: peer) else { return false }
        let peerFingerprint = CodeIdentity.fingerprint(peerSnapshot)
        guard peerFingerprint == own else {
            // 两边的身份都记下来：排查「为什么被拒」时，这一行比什么都直接。
            PrivilegedHelperService.log("rejected peer identity \(CodeIdentity.shortKind(peerFingerprint))"
                + ", own \(CodeIdentity.shortKind(own))")
            return false
        }
        return true
    }
}
