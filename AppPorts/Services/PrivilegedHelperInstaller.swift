import Foundation

/// 特权助手的安装与卸载。
///
/// 整个安装只花一次管理员授权：把 LaunchDaemon 描述文件装进
/// `/Library/LaunchDaemons`，再 `bootstrap` 到系统域。之后挂载类命令不再弹密码，
/// 因为这些命令走的是助手自己的 Mach 服务，和 `do shell script` 无关。
///
/// 有意保留的限制：
/// - 只允许从 `/Applications` 安装。守护进程以 root 执行磁盘上的可执行文件，
///   若允许外置卷或用户可写目录，等于把 root 交给那个目录的写权限。
/// - 描述文件里的可执行路径是固定的。应用被移动或更新后镜像会变，必须重装一次，
///   否则助手继续跑旧镜像（客户端握手会识别并提示重装）。
enum PrivilegedHelperInstaller {
    enum InstallError: LocalizedError {
        case outsideApplications(String)
        case launchd(String)
        case verification(String)

        var errorDescription: String? {
            switch self {
            case .outsideApplications(let path):
                return "特权助手只能从 /Applications 安装（当前路径：\(path)）。请先把 AppPorts 移回「应用程序」文件夹。"
            case .launchd(let detail): return "无法注册特权助手：" + detail
            case .verification(let detail): return "特权助手安装后无法握手：" + detail
            }
        }
    }

    enum Status: Equatable {
        case notInstalled
        case needsReinstall(String)
        case ready

        var isReady: Bool { self == .ready }
    }

    /// 安装（或按需重装）。调用方应保证不在主线程上等待——它会弹系统授权框。
    static func install(executablePath: URL = PrivilegedHelperInstaller.currentExecutableURL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try installSynchronously(executablePath: executablePath)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 卸载，同时断开会话。同样只弹一次授权。
    static func uninstall() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try runRootScript(uninstallScript())
                    PrivilegedHelperClient.shared.invalidate()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 当前状态：握手成功算就绪；描述文件在但握手失败算需要重装。
    static func status() -> Status {
        guard PrivilegedHelperClient.isInstalled else { return .notInstalled }
        do {
            _ = try PrivilegedHelperClient.shared.handshake()
            return .ready
        } catch {
            return .needsReinstall(error.localizedDescription)
        }
    }

    static var currentExecutableURL: URL {
        Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    }

    // MARK: - 同步实现

    private static func installSynchronously(executablePath: URL) throws {
        let path = executablePath.resolvingSymlinksInPath().path
        guard path.hasPrefix(PrivilegedHelperConstants.installableBundleRoot + "/"),
              path.contains(".app/Contents/MacOS/") else {
            throw InstallError.outsideApplications(path)
        }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw InstallError.verification("可执行文件不可用：\(path)")
        }
        let plist = daemonPlist(executablePath: path)
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppPorts-helper-\(UUID().uuidString).plist")
        try plist.write(to: staged, options: .atomic)
        defer { try? FileManager.default.removeItem(at: staged) }

        try runRootScript(installScript(stagedPlist: staged.path))
        PrivilegedHelperClient.shared.invalidate()

        // 安装脚本返回成功不代表守护进程真的起来了：launchd 可能因为签名、
        // 权限或描述文件格式拒绝加载。这里用握手确认，并留出冷启动的余量——
        // 一次握手失败就要求用户重装，等于让人白输一次密码。
        var lastError: Error?
        for attempt in 1...3 {
            do {
                _ = try PrivilegedHelperClient.shared.handshake()
                return
            } catch {
                lastError = error
                if attempt < 3 { Thread.sleep(forTimeInterval: 0.6) }
            }
        }
        throw InstallError.verification(lastError?.localizedDescription ?? "未知原因")
    }

    /// 把描述文件装到位、在系统域重新注册。`bootout` 允许失败：
    /// 首次安装时本来就没有在跑的服务。
    private static func installScript(stagedPlist: String) -> String {
        let destination = PrivilegedHelperConstants.daemonPlistPath
        let label = PrivilegedHelperConstants.label
        return """
        set -e
        /usr/bin/install -m 0644 -o root -g wheel \(shellQuote(stagedPlist)) \(shellQuote(destination))
        /bin/launchctl bootout system/\(label) >/dev/null 2>&1 || true
        # bootout 是异步的：旧实例还没退干净就 bootstrap，会撞上 “Bootstrap failed: 5”。
        # 这里等它从 launchd 里消失再注册，最多等 3 秒。
        for _ in 1 2 3 4 5 6; do
            /bin/launchctl print system/\(label) >/dev/null 2>&1 || break
            /bin/sleep 0.5
        done
        /bin/launchctl enable system/\(label) >/dev/null 2>&1 || true
        /bin/launchctl bootstrap system \(shellQuote(destination))
        """
    }

    private static func uninstallScript() -> String {
        let destination = PrivilegedHelperConstants.daemonPlistPath
        let label = PrivilegedHelperConstants.label
        return """
        /bin/launchctl bootout system/\(label) >/dev/null 2>&1 || true
        /bin/launchctl disable system/\(label) >/dev/null 2>&1 || true
        /bin/rm -f \(shellQuote(destination))
        /bin/launchctl print-disabled system >/dev/null 2>&1 || true
        """
    }

    private static func daemonPlist(executablePath: String) -> Data {
        let payload: [String: Any] = [
            "Label": PrivilegedHelperConstants.label,
            "ProgramArguments": [executablePath, PrivilegedHelperConstants.launchArgument],
            "MachServices": [PrivilegedHelperConstants.machService: true],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "ThrottleInterval": 10,
            "EnvironmentVariables": ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        ]
        // 描述文件由 launchd 解析，格式错会直接拒绝加载，所以这里失败就是失败。
        return (try? PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0))
            ?? Data()
    }

    private static func runRootScript(_ script: String) throws {
        let result: ShellCommandResult
        do {
            result = try AdministratorAuthorization.shared.run(command: script)
        } catch DiskUtility.Failure.administratorPromptCancelled {
            throw CancellationError()
        }
        guard result.status == 0 else {
            let detail = result.combinedText.isEmpty ? "退出码 \(result.status)" : result.combinedText
            throw InstallError.launchd(detail)
        }
    }

    /// 单引号包裹 + 内部的单引号转义，避免路径里的空格或引号破坏脚本。
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
