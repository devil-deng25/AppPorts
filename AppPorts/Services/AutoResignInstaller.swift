//
//  AutoResignInstaller.swift
//  AppPorts
//

import Foundation

/// Retires the historical login writer on every supported macOS version.
/// Signature repair is an explicit foreground operation; no new agent is installed.
enum AutoResignInstaller {

    static let enabledDefaultsKey = "autoResignAtLogin"
    static let policyErrorDefaultsKey = "autoResignSystemPolicyError"
    private static let label = "com.shimoko.AppPorts.re-sign"
    private static let scriptName = "AppPorts-ReSign.sh"
    private static let backgroundTaskStopper = BackgroundTaskStopper()

    private static var agentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var appSupportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AppPorts")
    }

    private static var scriptURL: URL {
        appSupportDir.appendingPathComponent(scriptName)
    }

    static var isSupported: Bool {
        supportsLoginResigning(macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    static func supportsLoginResigning(macOSMajorVersion: Int) -> Bool {
        false
    }

    // MARK: - Install

    /// Neutralize the installed script, then confirm the entire old process
    /// group has stopped before deleting its login registration.
    static func refreshInstalledScriptIfNeeded() async throws {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        try await disableIfUnsupported(
            macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            defaults: .standard, agentPlistURL: agentPlistURL, scriptURL: scriptURL,
            stopTask: { try await stopBackgroundTask() }
        )
    }

    /// 先把旧脚本改为空操作，再确认整个进程组退出，最后删除登录任务。
    /// 路径、偏好和停止动作可注入，测试不会接触真实登录项或签名备份。
    @discardableResult
    static func disableIfUnsupported(
        macOSMajorVersion: Int,
        defaults: UserDefaults,
        agentPlistURL: URL,
        scriptURL: URL,
        stopTask: () async throws -> Void
    ) async throws -> Bool {
        _ = macOSMajorVersion // The retirement policy now applies to every system.

        let fm = FileManager.default
        let hadInstallation = fm.fileExists(atPath: agentPlistURL.path) || fm.fileExists(atPath: scriptURL.path)
        let wasEnabled = defaults.bool(forKey: enabledDefaultsKey)
        defaults.set(false, forKey: enabledDefaultsKey)

        if hadInstallation {
            do {
                // 即使本次停止/清理失败，下一次登录也不能再执行旧脚本。
                try fm.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try DurableFileIO.write(Data("#!/bin/bash\n# Login re-signing has been disabled by AppPorts.\nexit 0\n".utf8), to: scriptURL)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            } catch {
                // 写入失败仍要尝试停止并卸载；只有后面的完整清理成功才算关闭完成。
                AppLogger.shared.logError("预先停用旧重签脚本失败，将继续停止并卸载任务", error: error)
            }
        }

        do {
            // plist 可能已经被删除，但对应任务仍在运行，不能按文件是否存在跳过此屏障。
            try await stopTask()
            try removeIfPresent(agentPlistURL)
            try removeIfPresent(scriptURL)
            defaults.removeObject(forKey: policyErrorDefaultsKey)
            if hadInstallation || wasEnabled {
                AppLogger.shared.log("开机自动重签名已停用，旧登录任务及其子进程已停止并卸载")
            }
            return true
        } catch {
            defaults.set(error.localizedDescription, forKey: policyErrorDefaultsKey)
            throw error
        }
    }

    private static func removeIfPresent(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // 幂等清理，也允许启动检查与签名操作同时等待同一个停止屏障。
        }
    }

    /// 旧脚本可能已读完记录并准备原地重签。仅更新脚本或记录不能取消它，
    /// 手动签名事务开始前必须确认本次登录任务及其子进程已退出。
    /// 不删除 plist，也不在当前会话重新 bootstrap，避免刚恢复就再次后台重签。
    static func stopBackgroundTask(
        runner: ShellCommandRunning = ProcessCommandRunner(),
        processGroupIsRunning: @escaping @Sendable (Int32) -> Bool = { kill(-$0, 0) == 0 || errno != ESRCH },
        timeout: TimeInterval = 15
    ) async throws {
        try await backgroundTaskStopper.stop(runner: runner, processGroupIsRunning: processGroupIsRunning, timeout: timeout)
    }

    private actor BackgroundTaskStopper {
        // actor 在 await 时可重入；共享进行中的任务，让启动刷新和手动操作等同一个停止屏障。
        private var pending: Task<Void, Error>?

        func stop(runner: ShellCommandRunning, processGroupIsRunning: @escaping @Sendable (Int32) -> Bool, timeout: TimeInterval) async throws {
            if let pending { return try await pending.value }
            let task = Task { try await AutoResignInstaller.stopLoadedTask(runner: runner, processGroupIsRunning: processGroupIsRunning, timeout: timeout) }
            pending = task
            defer { pending = nil }
            try await task.value
        }
    }

    private static func stopLoadedTask(
        runner: ShellCommandRunning,
        processGroupIsRunning: @escaping @Sendable (Int32) -> Bool,
        timeout: TimeInterval
    ) async throws {
        let target = "gui/\(getuid())/\(label)"
        let status = try await runner.run(executable: "/bin/launchctl", arguments: ["print", target], timeout: timeout)
        guard !status.timedOut else { throw InstallError.backgroundTaskStillRunning }
        if status.status != 0 {
            guard status.combinedText.localizedCaseInsensitiveContains("could not find service") else {
                throw InstallError.backgroundTaskStillRunning
            }
            return
        }
        let pid = status.stdoutText.components(separatedBy: .newlines).compactMap { line -> Int32? in
            let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " = ")
            guard parts.count == 2, parts[0] == "pid" else { return nil }
            return Int32(parts[1])
        }.first
        let help = try await runner.run(executable: "/bin/launchctl", arguments: ["help", "bootout"], timeout: timeout)
        let supportsWait = help.combinedText.contains("--wait")
        let arguments = supportsWait ? ["bootout", "--wait", target] : ["bootout", target]
        let stopped = try await runner.run(executable: "/bin/launchctl", arguments: arguments, timeout: timeout)
        guard !stopped.timedOut else { throw InstallError.backgroundTaskStillRunning }
        if stopped.status != 0 {
            // 启动刷新和手动操作可能同时停同一任务；只有确认任务已不存在才接受。
            let check = try await runner.run(executable: "/bin/launchctl", arguments: ["print", target], timeout: timeout)
            guard !check.timedOut, check.status != 0,
                  check.combinedText.localizedCaseInsensitiveContains("could not find service") else {
                throw InstallError.backgroundTaskStillRunning
            }
        }
        // 旧系统没有 bootout --wait。launchd 为任务建立独立进程组并在 bootout 时清理；
        // 等整组消失，不能只等 bash 退出而漏掉仍在运行的 codesign 子进程。
        let deadline = Date().addingTimeInterval(timeout)
        if let pid, pid > 1 {
            while processGroupIsRunning(pid) {
                guard Date() < deadline else { throw InstallError.backgroundTaskStillRunning }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    static func synchronizeScript(from source: URL, to destination: URL) throws {
        let data = try Data(contentsOf: source)
        if (try? Data(contentsOf: destination)) != data {
            try data.write(to: destination, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    }

    static func install() throws { throw InstallError.unsupportedSystem }

    /// Compatibility for the old settings toggle. Retirement itself remains an
    /// awaited barrier for all file-mutating services and application startup.
    static func uninstall() {
        UserDefaults.standard.set(false, forKey: enabledDefaultsKey)
        Task {
            do { try await refreshInstalledScriptIfNeeded() }
            catch { AppLogger.shared.logError("旧登录重签任务尚未完成停用", error: error) }
        }
    }

    // MARK: - Status

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: agentPlistURL.path)
    }

    enum InstallError: LocalizedError {
        case unsupportedSystem
        case scriptNotFound
        case launchAgentLoadFailed
        case backgroundTaskStillRunning

        var errorDescription: String? {
            switch self {
            case .unsupportedSystem:
                return "开机自动重签名已在所有系统停用。请在应用内对具体应用手动签名或恢复官方原件。".localized
            case .scriptNotFound:
                return "找不到重签名脚本，安装失败".localized
            case .launchAgentLoadFailed:
                return "LaunchAgent 加载失败".localized
            case .backgroundTaskStillRunning:
                return "无法确认后台重签任务已经停止，已取消本次操作以保护原始签名。请稍后重试。".localized
            }
        }
    }
}
