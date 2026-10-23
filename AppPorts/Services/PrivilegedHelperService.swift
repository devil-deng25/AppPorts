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
            reply(PrivilegedHelperConstants.protocolVersion, PeerTrust.selfCDHash?.base64EncodedString() ?? "")
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
/// 两层：
/// 1. 正式签名构建（带 Team ID）用 `SecRequirement` 把调用方钉到「同一个 bundle id +
///    同一个 Team ID」，这是 macOS 上特权助手的常规做法；
/// 2. 本地开发签名或临时签名没有 Team ID，退化为「cdhash 与自身镜像完全一致」，
///    保证只有这一份二进制能驱动助手。
///
/// 两种情况都要求调用方进程能通过代码签名有效性校验，未签名或被改写的副本会被拒绝。
enum PeerTrust {
    /// 自身镜像的 cdhash。
    static let selfCDHash: Data? = {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &code) == errSecSuccess, let code else { return nil }
        return cdHash(of: code)
    }()

    static func isTrusted(connection: NSXPCConnection) -> Bool {
        let processIdentifier = connection.processIdentifier
        guard processIdentifier > 0 else { return false }
        let attributes = [kSecGuestAttributePid as String: processIdentifier] as CFDictionary
        var peer: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(rawValue: 0), &peer) == errSecSuccess,
              let peer else { return false }
        // 调用方的签名必须先是有效的：被改写过的副本在这一步就出局。
        guard SecCodeCheckValidity(peer, SecCSFlags(rawValue: 0), nil) == errSecSuccess else { return false }

        let information = signingInformation(peer)
        let identifier = information[kSecCodeInfoIdentifier as String] as? String
        let teamIdentifier = information[kSecCodeInfoTeamIdentifier as String] as? String

        if let teamIdentifier, let requirement = teamRequirement(identifier: identifier, team: teamIdentifier),
           SecCodeCheckValidity(peer, SecCSFlags(rawValue: 0), requirement) == errSecSuccess {
            return true
        }
        // 没有 Team ID（本地开发构建）时，只认与自身完全一致的镜像。
        guard let ownCDHash = selfCDHash, let peerCDHash = cdHash(of: peer), ownCDHash == peerCDHash else {
            return false
        }
        return true
    }

    private static func teamRequirement(identifier: String?, team: String) -> SecRequirement? {
        guard let identifier, !identifier.isEmpty,
              identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              !team.isEmpty, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        let text = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, SecCSFlags(rawValue: 0), &requirement) == errSecSuccess else {
            return nil
        }
        return requirement
    }

    private static func signingInformation(_ code: SecCode) -> [String: Any] {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: 0), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return [:] }
        return dictionary
    }

    private static func cdHash(of code: SecCode) -> Data? {
        signingInformation(code)[kSecCodeInfoUnique as String] as? Data
    }
}
