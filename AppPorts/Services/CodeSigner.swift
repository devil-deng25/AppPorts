//
//  CodeSigner.swift
//  AppPorts
//

import Foundation

actor CodeSigner {

    enum SigningError: LocalizedError {
        case codesignFailed(String)
        case backupFailed(String)
        case restoreFailed(String)
        case noBackupFound
        case applicationUnavailable(URL)
        case sandboxedApplication(URL)
        case legacyBackupIncomplete
        case snapshotInvalid
        case applicationChanged
        case operationInProgress
        case atomicReplacementUnavailable
        case originalApplicationMismatch

        var errorDescription: String? {
            switch self {
            case .codesignFailed(let msg):
                return String(format: "签名失败: %@".localized, msg)
            case .backupFailed(let msg):
                return String(format: "备份签名失败: %@".localized, msg)
            case .restoreFailed(let msg):
                return String(format: "恢复签名失败: %@".localized, msg)
            case .noBackupFound:
                return "未找到原始签名备份".localized
            case .applicationUnavailable(let url):
                return String(format: "无法找到真实应用，无法重签名：%@".localized, url.path)
            case .sandboxedApplication(let url):
                return String(format: "「%@」是沙盒应用。Ad-hoc 重签名会移除它的沙盒、应用组和钥匙串访问授权，系统升级后应用可能无法启动，默认拒绝重签名。容器数据请优先使用挂载迁移。".localized, url.lastPathComponent)
            case .legacyBackupIncomplete:
                return "旧版备份只记录了签名身份，没有保存原始应用，无法直接恢复。请选择从官方渠道取得的同版本原版应用，或从官方渠道重新安装；现有应用和备份均已保留。".localized
            case .snapshotInvalid:
                return "原始应用备份缺失或校验失败，已停止恢复。现有应用和备份均已保留。".localized
            case .applicationChanged:
                return "应用内容已更新或改变，不能用旧备份覆盖。请选择同版本原版应用恢复，或从官方渠道重新安装；现有应用和备份均已保留。".localized
            case .operationInProgress:
                return "另一项签名操作正在进行，请稍后重试。".localized
            case .atomicReplacementUnavailable:
                return "此存储不支持安全替换应用。请先将应用迁回本地，再重试签名操作。原应用和备份均已保留。".localized
            case .originalApplicationMismatch:
                return "所选原版应用的标识、版本或开发者签名不匹配，或签名校验失败。请选择同一应用、同一版本的官方原版。".localized
            }
        }
    }

    /// 沙盒授权键；默认拒绝重签，经典模式必须先保存完整原始应用。
    static let sandboxEntitlementKey = "com.apple.security.app-sandbox"
    private static let entitlementsQueryTimeout: TimeInterval = 10

    private static let backupDirectoryName = "signature-backups"

    static var defaultBackupDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("AppPorts/\(backupDirectoryName)")
    }

    private let fileManager = FileManager.default
    private let backupDirectoryURL: URL
    private let allowAdministratorPrompt: Bool
    private let trashBackupSnapshot: @Sendable (URL) throws -> Void
    private let deleteBackupRecordFile: @Sendable (URL) throws -> Void
    private let exchangeApplications: @Sendable (URL, URL) throws -> Void
    private let copyApplication: @Sendable (URL, URL) throws -> Void

    init(
        backupDirectoryURL: URL? = nil,
        allowAdministratorPrompt: Bool = true,
        trashBackupSnapshot: @escaping @Sendable (URL) throws -> Void = { try SignatureSnapshot.trash($0) },
        deleteBackupRecordFile: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
        exchangeApplications: @escaping @Sendable (URL, URL) throws -> Void = { try SignatureSnapshot.exchange($0, $1) },
        copyApplication: @escaping @Sendable (URL, URL) throws -> Void = { try SignatureSnapshot.copy(from: $0, to: $1) }
    ) {
        self.backupDirectoryURL = backupDirectoryURL ?? Self.defaultBackupDirectoryURL
        self.allowAdministratorPrompt = allowAdministratorPrompt
        self.trashBackupSnapshot = trashBackupSnapshot
        self.deleteBackupRecordFile = deleteBackupRecordFile
        self.exchangeApplications = exchangeApplications
        self.copyApplication = copyApplication
    }

    static func ownershipRepairAppleScript(username: String, appPath: String) -> String {
        """
        set targetPath to \(AppMigrationService.appleScriptStringLiteral(appPath))
        set userName to \(AppMigrationService.appleScriptStringLiteral(username))
        do shell script "/usr/sbin/chown -R -P " & quoted form of userName & " " & quoted form of targetPath with administrator privileges
        """
    }

    // MARK: - Public API

    /// 解析真实应用包，不依赖可能已经过期的扫描状态，也不在目标缺失时退回签名本地入口。
    static func resolveAppURL(at appURL: URL) throws -> URL {
        let fileManager = FileManager.default
        var candidate = appURL.standardizedFileURL
        var visited = Set<String>()

        while visited.insert(candidate.path).inserted {
            candidate = candidate.resolvingSymlinksInPath().standardizedFileURL
            var isDirectory: ObjCBool = false
            guard candidate.pathExtension.lowercased() == "app",
                  fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw SigningError.applicationUnavailable(candidate)
            }

            let pathFile = candidate.appendingPathComponent("Contents/Resources/real_app_path.txt")
            if (try? fileManager.attributesOfItem(atPath: pathFile.path)) != nil {
                guard let path = try? String(contentsOf: pathFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines), path.hasPrefix("/") else {
                    throw SigningError.applicationUnavailable(candidate)
                }
                candidate = URL(fileURLWithPath: path).standardizedFileURL
                continue
            }

            // 兼容旧 bash Stub；只解析字面量，绝不执行脚本。
            let launcher = candidate.appendingPathComponent("Contents/MacOS/launcher")
            if let script = try? String(contentsOf: launcher, encoding: .utf8),
               let assignment = script.components(separatedBy: .newlines)
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { $0.hasPrefix("REAL_APP=") }) {
                guard assignment.hasPrefix("REAL_APP='"), assignment.hasSuffix("'") else {
                    throw SigningError.applicationUnavailable(candidate)
                }
                let path = String(assignment.dropFirst("REAL_APP='".count).dropLast())
                    .replacingOccurrences(of: "'\\''", with: "'")
                guard path.hasPrefix("/") else {
                    throw SigningError.applicationUnavailable(candidate)
                }
                candidate = URL(fileURLWithPath: path).standardizedFileURL
                continue
            }

            // 旧 Deep Contents Wrapper 必须直接签外部包，不能签完临时 Contents 副本后丢弃。
            let contents = candidate.appendingPathComponent("Contents")
            if let target = try? fileManager.destinationOfSymbolicLink(atPath: contents.path) {
                candidate = URL(fileURLWithPath: target, relativeTo: candidate)
                    .standardizedFileURL.deletingLastPathComponent()
                continue
            }

            if bundleIdentifier(at: candidate)?.hasSuffix(".appports.stub") == true {
                throw SigningError.applicationUnavailable(candidate)
            }
            return candidate
        }

        throw SigningError.applicationUnavailable(candidate)
    }

    static func bundleIdentifier(at appURL: URL) -> String? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return plist["CFBundleIdentifier"] as? String
    }

    /// 读取应用主可执行文件的 entitlements；未签名或读取失败返回 nil。
    ///
    /// 新系统用 `--xml` 输出 plist；旧系统只认 `:-`（去掉 blob 头的 XML）。两种都试，解析成功即返回。
    static func entitlements(at appURL: URL) -> [String: Any]? {
        for arguments in [
            ["--display", "--entitlements", "-", "--xml", appURL.path],
            ["--display", "--entitlements", ":-", appURL.path]
        ] {
            guard let output = runCodesignQuery(arguments: arguments, timeout: entitlementsQueryTimeout) else { continue }
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let plist = try? PropertyListSerialization.propertyList(from: Data(trimmed.utf8), format: nil) as? [String: Any] else {
                continue
            }
            return plist
        }
        return nil
    }

    /// 应用是否以沙盒身份运行。沙盒应用访问容器只能靠 entitlements，不能靠重签名。
    static func isSandboxed(at appURL: URL) -> Bool {
        guard let entitlements = entitlements(at: appURL) else { return false }
        if let flag = entitlements[sandboxEntitlementKey] as? Bool {
            return flag
        }
        return (entitlements[sandboxEntitlementKey] as? NSNumber)?.boolValue == true
    }

    /// 只读查询，带超时；返回 codesign 的标准输出，失败或超时返回 nil。
    private static func runCodesignQuery(arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // 超时后终止进程；持续读取避免 entitlements 较长时填满 pipe 导致进程无法退出。
        let timeoutWork = DispatchWorkItem {
            guard process.isRunning else { return }
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutWork.cancel()

        guard process.terminationStatus == 0 else {
            if process.terminationReason == .uncaughtSignal {
                AppLogger.shared.logContext(
                    "codesign 查询超时，已终止",
                    details: [("arguments", arguments.joined(separator: " ")), ("timeout_sec", String(Int(timeout)))],
                    level: "WARN"
                )
            }
            return nil
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// 迁移前保存完整原始应用，包含签名、授权及所有嵌套代码。
    func backupOriginalSignature(appURL: URL, bundleIdentifier: String) async throws {
        let appURL = try Self.resolveAppURL(at: appURL)
        try await ensureBackupDirectory()
        let lock = try acquireSignatureLock()
        defer { lock.release() }
        _ = try saveOriginalSignature(appURL: appURL, bundleIdentifier: Self.bundleIdentifier(at: appURL) ?? bundleIdentifier)
    }

    /// 在工作副本中重签，校验并保存可恢复状态后才替换真实应用。
    /// 默认拒绝沙盒应用；经典模式允许重签，但先保存可恢复的原始应用。
    /// `allowSandboxed` 仅供经典数据迁移模式使用，调用方必须已向用户说明后果。
    func sign(appURL: URL, bundleIdentifier: String?, allowSandboxed: Bool = false) async throws {
        let appURL = try Self.resolveAppURL(at: appURL)
        if !allowSandboxed, Self.isSandboxed(at: appURL) {
            AppLogger.shared.logError(
                "拒绝重签名沙盒应用",
                errorCode: "RESIGN-REFUSED-SANDBOXED",
                context: [("bundle_id", bundleIdentifier ?? Self.bundleIdentifier(at: appURL) ?? "nil")],
                relatedURLs: [("app", appURL)]
            )
            throw SigningError.sandboxedApplication(appURL)
        }
        try await ensureBackupDirectory()
        let lock = try acquireSignatureLock()
        defer { lock.release() }
        guard let bundleID = Self.bundleIdentifier(at: appURL) ?? bundleIdentifier else {
            throw SigningError.backupFailed("无法读取应用 Bundle Identifier".localized)
        }
        var backup = try saveOriginalSignature(appURL: appURL, bundleIdentifier: bundleID)
        let originalFingerprint = try SignatureSnapshot.fingerprint(of: appURL)
        guard backup.restorableFingerprints?.contains(originalFingerprint) == true else {
            throw SigningError.applicationChanged
        }
        let work = try makeWorkingCopy(of: appURL, beside: appURL)
        defer { removeWorkingDirectory(work.deletingLastPathComponent()) }
        guard try SignatureSnapshot.fingerprint(of: work) == originalFingerprint else {
            throw SigningError.applicationChanged
        }
        try SignatureSnapshot.validateLinksForSigning(in: work)
        try withUnlockedBundle(at: work) { items in
                try stripSigningDetritus(from: items)
                cleanBundleRoot(at: work)
                try runCodesign(arguments: ["--force", "--deep", "--sign", "-", work.path])
                try runCodesign(arguments: ["--verify", "--deep", "--strict", work.path], retries: 0)
        }
        let signedFingerprint = try SignatureSnapshot.fingerprint(of: work)
        // 在交换前持久化两种有效状态：即使此刻退出，下次也能识别交换前/后的应用。
        var accepted = backup.restorableFingerprints ?? []
        if !accepted.contains(signedFingerprint) { accepted.append(signedFingerprint) }
        backup.restorableFingerprints = accepted
        try writeBackup(backup)
        try replaceApplication(at: appURL, with: work, expectedFingerprint: originalFingerprint)

        AppLogger.shared.logContext(
            "Ad-hoc 重签名完成",
            details: [("path", appURL.path)]
        )
    }

    /// 验证签名
    func verify(appURL: URL) async -> SignatureStatus {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", appURL.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .unknown
        }

        if process.terminationStatus == 0 {
            return .valid
        }

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        if errorOutput.contains("code object is not signed at all") {
            return .unsigned
        }
        if errorOutput.contains("invalid signature") || errorOutput.contains("ad-hoc") {
            return .adHoc
        }

        return .invalid
    }

    /// 获取当前签名身份
    func getSigningIdentity(appURL: URL) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dvv", appURL.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        for line in output.components(separatedBy: "\n") {
            if line.contains("Authority=") {
                return line
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "Authority=", with: "")
            }
        }
        return nil
    }

    /// 从完整原始应用恢复，不重新签名，不依赖开发者私钥。
    /// 旧版记录可由用户提供的同版本官方原版补救；不会把身份名称当作可恢复备份。
    func restoreSignature(appURL: URL, bundleIdentifier: String, originalApplication: URL? = nil) async throws {
        let appURL = try Self.resolveAppURL(at: appURL)
        let bundleIdentifier = Self.bundleIdentifier(at: appURL) ?? bundleIdentifier
        try await ensureBackupDirectory()
        let lock = try acquireSignatureLock()
        defer { lock.release() }
        guard let backup = try readBackup(bundleIdentifier: bundleIdentifier) else {
            throw SigningError.noBackupFound
        }
        let currentFingerprint = try SignatureSnapshot.fingerprint(of: appURL)
        if let cleanup = backup.cleanup, cleanup.applicationFingerprint == currentFingerprint {
            try finishBackupCleanup(backup, appURL: appURL, applicationFingerprint: currentFingerprint)
            return
        }
        let original: URL
        let originalFingerprint: String
        let verifyOriginal: Bool
        if let originalApplication {
            original = try Self.resolveAppURL(at: originalApplication)
            guard original != appURL else { throw SigningError.originalApplicationMismatch }
            try validateOriginalApplication(original, for: appURL, backup: backup)
            originalFingerprint = try SignatureSnapshot.fingerprint(of: original)
            verifyOriginal = true
        } else {
            original = try verifiedSnapshot(for: backup)
            guard let digest = backup.originalFingerprint,
                  backup.restorableFingerprints?.contains(currentFingerprint) == true else {
                throw SigningError.applicationChanged
            }
            originalFingerprint = digest
            verifyOriginal = backup.originalSignatureWasValid == true
        }
        // 即使内容摘要相同，也恢复快照中的 ACL、Finder 元数据等未纳入摘要的属性。
        do {
            let work = try makeWorkingCopy(of: original, beside: appURL)
            defer { removeWorkingDirectory(work.deletingLastPathComponent()) }
            guard try SignatureSnapshot.fingerprint(of: work) == originalFingerprint else {
                throw SigningError.snapshotInvalid
            }
            if verifyOriginal {
                try runCodesign(arguments: ["--verify", "--deep", "--strict", work.path], retries: 0)
            }
            try replaceApplication(at: appURL, with: work, expectedFingerprint: currentFingerprint)
        }
        // 只有交换完成后才清理；清理失败不会伪报恢复失败。
        removeBackup(bundleIdentifier: bundleIdentifier, appURL: appURL, applicationFingerprint: originalFingerprint)
        AppLogger.shared.logContext("恢复原始签名完成", details: [
            ("path", appURL.path), ("bundle_id", bundleIdentifier),
            ("source", originalApplication == nil ? "snapshot" : "user-selected-original")
        ])
    }

    /// 检查是否有备份
    func hasBackup(bundleIdentifier: String) -> Bool {
        let backupURL = backupFileURL(for: bundleIdentifier)
        return fileManager.fileExists(atPath: backupURL.path)
    }

    /// A data operation may have saved an original before failing or before
    /// the user declined signing. Discard only a proven duplicate of the real
    /// current app. An app that still differs keeps its signature recovery copy.
    @discardableResult
    func discardUnusedOriginalBackup(bundleIdentifier: String, appURL: URL? = nil) async throws -> Bool {
        guard hasBackup(bundleIdentifier: bundleIdentifier) else { return false }
        let lock = try acquireSignatureLock()
        defer { lock.release() }
        guard let backup = try readBackup(bundleIdentifier: bundleIdentifier),
              backup.schemaVersion == 2, let originalFingerprint = backup.originalFingerprint else { return false }
        let current: URL
        do {
            current = try Self.resolveAppURL(at: appURL ?? URL(fileURLWithPath: backup.originalPath))
        } catch SigningError.applicationUnavailable {
            return false
        }
        guard Self.bundleIdentifier(at: current) == bundleIdentifier else { return false }
        // Another installed copy cannot prove that the recorded app no longer
        // needs recovery, including when that app's disk or old path is offline.
        guard let recordedApp = try? Self.resolveAppURL(at: URL(fileURLWithPath: backup.originalPath)),
              try DataPathIdentity.capture(recordedApp).matchesFilesystemObject(DataPathIdentity.capture(current)) else { return false }
        let expected = backup.cleanup?.applicationFingerprint ?? originalFingerprint
        guard try SignatureSnapshot.fingerprint(of: current) == expected else { return false }
        try finishBackupCleanup(backup, appURL: current, applicationFingerprint: expected)
        AppLogger.shared.logContext("已清理未使用的原始签名备份", details: [("bundle_id", bundleIdentifier)])
        return true
    }

    /// 备份目录里是否存在任何签名备份。
    /// 启动时的「签名已被替换」提醒据此在没有备份时直接跳过目录枚举。
    nonisolated static func hasSignatureBackups(backupDirectoryURL: URL? = nil) -> Bool {
        let directory = backupDirectoryURL ?? defaultBackupDirectoryURL
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return false }
        return entries.contains { $0.hasSuffix(".plist") }
    }

    /// 备份里记录的原始签名身份；没有备份返回 nil。供扫描器判断签名是否被替换。
    nonisolated static func originalSigningIdentity(bundleIdentifier: String, backupDirectoryURL: URL? = nil) -> String? {
        let directory = backupDirectoryURL ?? defaultBackupDirectoryURL
        let url = directory.appendingPathComponent("\(bundleIdentifier).plist")
        guard let data = try? Data(contentsOf: url),
              let backup = try? PropertyListDecoder().decode(SignatureBackup.self, from: data) else { return nil }
        return backup.signingIdentity
    }

    /// 原始签名是否已被 Ad-hoc 替换。
    nonisolated static func isSignatureReplaced(originalIdentity: String?, currentlyAdHoc: Bool) -> Bool {
        guard currentlyAdHoc, let originalIdentity, !originalIdentity.isEmpty, originalIdentity != "ad-hoc" else { return false }
        return true
    }

    // MARK: - Signature Status

    enum SignatureStatus: Equatable {
        case valid
        case adHoc
        case unsigned
        case invalid
        case unknown
    }

    // MARK: - Backup Management

    private struct SignatureBackup: Codable, Equatable {
        let bundleIdentifier: String
        let signingIdentity: String
        let originalPath: String
        let backupDate: Date
        var schemaVersion: Int? = nil
        var snapshotName: String? = nil
        var originalFingerprint: String? = nil
        var restorableFingerprints: [String]? = nil
        var originalSignatureWasValid: Bool? = nil
        var cleanup: SignatureBackupCleanup? = nil
    }

    /// Native Trash moves the whole snapshot. Keep its record until the move
    /// and record deletion both finish, including across an app restart.
    private struct SignatureBackupCleanup: Codable, Equatable {
        let parentIdentity: DataPathIdentity
        let snapshotIdentity: DataPathIdentity?
        let applicationFingerprint: String
    }

    private func saveOriginalSignature(appURL: URL, bundleIdentifier: String) throws -> SignatureBackup {
        let currentFingerprint = try SignatureSnapshot.fingerprint(of: appURL)
        var retiredBackup: SignatureBackup?
        if let existing = try readBackup(bundleIdentifier: bundleIdentifier) {
            if let cleanup = existing.cleanup, cleanup.applicationFingerprint == currentFingerprint {
                try finishBackupCleanup(existing, appURL: appURL, applicationFingerprint: currentFingerprint)
                return try saveOriginalSignature(appURL: appURL, bundleIdentifier: bundleIdentifier)
            }
            if existing.schemaVersion == 2, existing.restorableFingerprints?.contains(currentFingerprint) == true {
                _ = try verifiedSnapshot(for: existing)
                return existing
            }
            // 官方更新/重装后，以当前完整有效的开发者签名应用建立新恢复点。
            // 旧记录与快照先归档，绝不把新版摘要混入旧版快照。
            guard let identity = syncGetSigningIdentity(appURL: appURL),
                  identity == existing.signingIdentity,
                  (try? runCodesign(arguments: ["--verify", "--deep", "--strict", appURL.path], retries: 0)) != nil else {
                throw existing.schemaVersion == 2 ? SigningError.applicationChanged : SigningError.legacyBackupIncomplete
            }
            retiredBackup = existing
        }
        let name = "original-" + UUID().uuidString + ".app"
        let snapshot = backupDirectoryURL.appendingPathComponent(name)
        var committed = false
        defer { if !committed { removeWorkingDirectory(snapshot) } }
        try copyApplication(appURL, snapshot)
        guard try SignatureSnapshot.fingerprint(of: snapshot) == currentFingerprint,
              try SignatureSnapshot.fingerprint(of: appURL) == currentFingerprint else {
            throw SigningError.applicationChanged
        }
        let wasValid = (try? runCodesign(arguments: ["--verify", "--deep", "--strict", snapshot.path], retries: 0)) != nil
        var backup = SignatureBackup(
            bundleIdentifier: bundleIdentifier,
            signingIdentity: syncGetSigningIdentity(appURL: snapshot) ?? "ad-hoc",
            originalPath: appURL.path,
            backupDate: Date()
        )
        backup.schemaVersion = 2
        backup.snapshotName = name
        backup.originalFingerprint = currentFingerprint
        backup.restorableFingerprints = [currentFingerprint]
        backup.originalSignatureWasValid = wasValid
        if let retiredBackup {
            let archive = backupDirectoryURL.appendingPathComponent("retired")
            try fileManager.createDirectory(at: archive, withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml
            try encoder.encode(retiredBackup).write(to: archive.appendingPathComponent(UUID().uuidString + ".plist"), options: .atomic)
        }
        try writeBackup(backup)
        committed = true
        AppLogger.shared.logContext("原始应用与签名已完整备份", details: [
            ("bundle_id", bundleIdentifier), ("snapshot", snapshot.path)
        ])
        return backup
    }

    private func readBackup(bundleIdentifier: String) throws -> SignatureBackup? {
        let url = backupFileURL(for: bundleIdentifier)
        // 不允许应用的 Bundle ID 把记录写到备份目录外。
        guard !bundleIdentifier.isEmpty, url.deletingLastPathComponent().standardizedFileURL == backupDirectoryURL.standardizedFileURL else {
            throw SigningError.snapshotInvalid
        }
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let backup = try PropertyListDecoder().decode(SignatureBackup.self, from: Data(contentsOf: url))
            guard backup.bundleIdentifier == bundleIdentifier else { throw SigningError.snapshotInvalid }
            return backup
        } catch { throw SigningError.snapshotInvalid }
    }

    private func verifiedSnapshot(for backup: SignatureBackup) throws -> URL {
        guard backup.schemaVersion == 2 else { throw SigningError.legacyBackupIncomplete }
        guard let snapshot = snapshotURL(for: backup), let fingerprint = backup.originalFingerprint,
              (try? SignatureSnapshot.info(at: snapshot).st_mode & S_IFMT) == S_IFDIR,
              (try? SignatureSnapshot.fingerprint(of: snapshot)) == fingerprint else {
            throw SigningError.snapshotInvalid
        }
        return snapshot
    }

    private func snapshotURL(for backup: SignatureBackup) -> URL? {
        guard let name = backup.snapshotName,
              name.hasPrefix("original-"), name.hasSuffix(".app"),
              URL(fileURLWithPath: name).lastPathComponent == name else { return nil }
        return backupDirectoryURL.appendingPathComponent(name)
    }

    private func writeBackup(_ backup: SignatureBackup) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(backup).write(to: backupFileURL(for: backup.bundleIdentifier), options: .atomic)
    }

    private func removeBackup(bundleIdentifier: String, appURL: URL, applicationFingerprint: String) {
        do {
            guard let backup = try readBackup(bundleIdentifier: bundleIdentifier) else { return }
            try finishBackupCleanup(backup, appURL: appURL, applicationFingerprint: applicationFingerprint)
        } catch {
            AppLogger.shared.logError("签名已恢复，但备份清理未完成", error: error)
        }
    }

    private func finishBackupCleanup(_ original: SignatureBackup, appURL: URL, applicationFingerprint: String) throws {
        let parent = backupDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
        let appURL = try Self.resolveAppURL(at: appURL)
        // A portal can accidentally point into the backup directory. Matching
        // fingerprints must never authorize moving the live application away.
        guard appURL.path != parent.path, !appURL.path.hasPrefix(parent.path + "/"),
              Self.bundleIdentifier(at: appURL) == original.bundleIdentifier else {
            throw SigningError.applicationChanged
        }
        let appIdentity = try DataPathIdentity.capture(appURL)
        guard try SignatureSnapshot.fingerprint(of: appURL) == applicationFingerprint,
              try readBackup(bundleIdentifier: original.bundleIdentifier) == original else {
            throw SigningError.applicationChanged
        }
        let snapshot = snapshotURL(for: original)
        if original.snapshotName != nil, snapshot == nil { throw SigningError.snapshotInvalid }
        let parentIdentity = try DataPathIdentity.capture(parent)
        var backup = original
        if let cleanup = backup.cleanup {
            guard cleanup.applicationFingerprint == applicationFingerprint,
                  parentIdentity.matchesFilesystemObject(cleanup.parentIdentity) else { throw SigningError.snapshotInvalid }
        } else {
            // An unexplained missing snapshot is not a completed Trash move.
            let snapshotIdentity: DataPathIdentity?
            if let snapshot {
                _ = try verifiedSnapshot(for: backup)
                let identity = try DataPathIdentity.capture(snapshot)
                guard !identity.matchesFilesystemObject(appIdentity) else { throw SigningError.applicationChanged }
                snapshotIdentity = identity
            } else {
                snapshotIdentity = nil // Legacy identity-only record after explicit signature restoration.
            }
            backup.cleanup = .init(parentIdentity: parentIdentity, snapshotIdentity: snapshotIdentity,
                                   applicationFingerprint: applicationFingerprint)
            guard try readBackup(bundleIdentifier: backup.bundleIdentifier) == original else { throw SigningError.applicationChanged }
            try writeBackup(backup)
        }
        guard let cleanup = backup.cleanup else { throw SigningError.snapshotInvalid }
        if let snapshot, try backupEntryExists(snapshot) {
            guard let expectedIdentity = cleanup.snapshotIdentity,
                  try DataPathIdentity.capture(snapshot).matchesFilesystemObject(expectedIdentity),
                  !expectedIdentity.matchesFilesystemObject(appIdentity) else { throw SigningError.snapshotInvalid }
            _ = try verifiedSnapshot(for: backup)
            guard try DataPathIdentity.capture(parent).matchesFilesystemObject(cleanup.parentIdentity),
                  try DataPathIdentity.capture(appURL).matchesFilesystemObject(appIdentity),
                  try SignatureSnapshot.fingerprint(of: appURL) == applicationFingerprint,
                  try readBackup(bundleIdentifier: backup.bundleIdentifier) == backup else { throw SigningError.applicationChanged }
            try trashBackupSnapshot(snapshot)
            guard try !backupEntryExists(snapshot) else { throw SigningError.snapshotInvalid }
        }
        guard try DataPathIdentity.capture(parent).matchesFilesystemObject(cleanup.parentIdentity),
              try DataPathIdentity.capture(appURL).matchesFilesystemObject(appIdentity),
              try SignatureSnapshot.fingerprint(of: appURL) == applicationFingerprint,
              try readBackup(bundleIdentifier: backup.bundleIdentifier) == backup else { throw SigningError.snapshotInvalid }
        try deleteBackupRecordFile(backupFileURL(for: backup.bundleIdentifier))
    }

    private func backupEntryExists(_ url: URL) throws -> Bool {
        var value = stat()
        if lstat(url.path, &value) == 0 { return true }
        guard errno == ENOENT else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path]) }
        return false
    }

    private func backupFileURL(for bundleIdentifier: String) -> URL {
        backupDirectoryURL.appendingPathComponent("\(bundleIdentifier).plist")
    }

    private func ensureBackupDirectory() async throws {
        try fileManager.createDirectory(at: backupDirectoryURL, withIntermediateDirectories: true)
        if backupDirectoryURL == Self.defaultBackupDirectoryURL {
            try await AutoResignInstaller.stopBackgroundTask()
            try await AutoResignInstaller.refreshInstalledScriptIfNeeded()
        }
    }

    private func acquireSignatureLock() throws -> OperationLock {
        // 每次用独立文件描述符，防止多个 CodeSigner 实例把同一个可重入锁当作已取得。
        let lock = OperationLock(fileURL: backupDirectoryURL.appendingPathComponent("signature-operation.lock"))
        guard lock.tryAcquire() else { throw SigningError.operationInProgress }
        return lock
    }

    private func makeWorkingCopy(of source: URL, beside app: URL) throws -> URL {
        let directory = app.deletingLastPathComponent().appendingPathComponent(".AppPorts-signature-" + UUID().uuidString)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        let copy = directory.appendingPathComponent(app.lastPathComponent)
        do {
            try copyApplication(source, copy)
            guard try SignatureSnapshot.fingerprint(of: source) == SignatureSnapshot.fingerprint(of: copy) else {
                throw SigningError.snapshotInvalid
            }
            return copy
        } catch {
            removeWorkingDirectory(directory)
            throw error
        }
    }

    private func removeWorkingDirectory(_ directory: URL) {
        do { try SignatureSnapshot.remove(directory) }
        catch { AppLogger.shared.logError("清理签名工作副本失败", error: error, relatedURLs: [("path", directory)]) }
    }

    private func replaceApplication(at app: URL, with work: URL, expectedFingerprint: String) throws {
        guard try SignatureSnapshot.fingerprint(of: app) == expectedFingerprint else {
            throw SigningError.applicationChanged
        }
        let lockedPaths = try bundleItems(at: app).filter { try fileInfo(at: $0).st_flags & UInt32(UF_IMMUTABLE) != 0 }
        let workRootLocked = try fileInfo(at: work).st_flags & UInt32(UF_IMMUTABLE) != 0
        var exchanged = false
        do {
            try withOwnershipRepair(at: app) {
                // 只解开目录根的锁；原子交换无需修改目录内的文件。
                try setImmutable(false, at: app)
                try setImmutable(false, at: work)
                try exchangeApplications(app, work)
                exchanged = true
            }
        } catch {
            try? restoreImmutableItems(lockedPaths)
            if workRootLocked { try? setImmutable(true, at: work) }
            throw error
        }
        if exchanged {
            do {
                try restoreImmutableItems(lockedPaths)
                if workRootLocked { try setImmutable(true, at: app) }
            } catch {
                // 内容已完整提交，锁定状态修复失败不能当成内容恢复失败。
                AppLogger.shared.logError("签名操作完成，但恢复应用锁定状态失败", error: error)
            }
        }
    }

    private func validateOriginalApplication(_ original: URL, for current: URL, backup: SignatureBackup) throws {
        func metadata(_ url: URL) -> [String: Any]? {
            guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")) else { return nil }
            return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        }
        guard Self.bundleIdentifier(at: original) == backup.bundleIdentifier,
              let currentInfo = metadata(current), let originalInfo = metadata(original) else {
            throw SigningError.originalApplicationMismatch
        }
        for key in ["CFBundleVersion", "CFBundleShortVersionString"] {
            guard currentInfo[key] as? String == originalInfo[key] as? String else {
                throw SigningError.originalApplicationMismatch
            }
        }
        if !backup.signingIdentity.isEmpty, backup.signingIdentity != "ad-hoc",
           syncGetSigningIdentity(appURL: original) != backup.signingIdentity {
            throw SigningError.originalApplicationMismatch
        }
        guard (try? runCodesign(arguments: ["--verify", "--deep", "--strict", original.path], retries: 0)) != nil else {
            throw SigningError.originalApplicationMismatch
        }
    }

    // MARK: - Immutable Handling

    /// 枚举包内所有子项（包括隐藏文件和嵌套 .app），不跟随符号链接。
    private func bundleItems(at appURL: URL) throws -> [URL] {
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: appURL,
            includingPropertiesForKeys: nil,
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: appURL.path])
        }
        var items = [appURL]
        // DirectoryEnumerator 默认不跟随链接；对链接调用 skipDescendants()
        // 反而会跳过下一个真实目录（如框架的 Versions/A），漏掉其锁定文件。
        for case let url as URL in enumerator {
            items.append(url)
        }
        if let enumerationError { throw enumerationError }
        return items
    }

    private func fileInfo(at url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        return info
    }

    /// 仅修改 uchg 位，并用 lchflags 避免改到链接目标。
    private func setImmutable(_ immutable: Bool, at url: URL) throws {
        let info = try fileInfo(at: url)
        let flags = immutable ? info.st_flags | UInt32(UF_IMMUTABLE) : info.st_flags & ~UInt32(UF_IMMUTABLE)
        guard lchflags(url.path, flags) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    private func restoreImmutableItems(_ items: [URL]) throws {
        var firstError: Error?
        for url in items.reversed() {
            do {
                // codesign 可以替换文件；按原路径恢复锁，保留新的其它 flags。
                // 清理掉的 .DS_Store 等项目无需重建。
                if (try? fileManager.attributesOfItem(atPath: url.path)) != nil {
                    try setImmutable(true, at: url)
                }
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    private func withUnlockedBundle(at appURL: URL, operation: ([URL]) throws -> Void) throws {
        let items = try bundleItems(at: appURL)
        var unlocked: [URL] = []
        do {
            for url in items {
                if try fileInfo(at: url).st_flags & UInt32(UF_IMMUTABLE) != 0 {
                    try setImmutable(false, at: url)
                    unlocked.append(url)
                }
            }
            try operation(items)
            try restoreImmutableItems(unlocked)
        } catch {
            do {
                try restoreImmutableItems(unlocked)
            } catch let restoreError {
                AppLogger.shared.logError(
                    "恢复应用锁定状态失败",
                    error: restoreError,
                    relatedURLs: [("app", appURL)]
                )
            }
            throw error
        }
    }

    // MARK: - Codesign Execution

    @discardableResult
    private func runCodesign(arguments: [String], retries: Int = 2) throws -> String {
        var lastError: String = ""

        for attempt in 0...retries {
            if attempt > 0 {
                Thread.sleep(forTimeInterval: Double(attempt) * 1.0)
                AppLogger.shared.logContext(
                    "重试 codesign",
                    details: [("attempt", String(attempt)), ("arguments", arguments.joined(separator: " "))],
                    level: "WARN"
                )
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = arguments

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            try process.run()
            // 持续读取，避免深度签名产生大量输出时填满 pipe 而无法退出。
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: outputData, encoding: .utf8) ?? ""

            if process.terminationStatus == 0 {
                return output
            }

            lastError = output.isEmpty ? "exit code \(process.terminationStatus)" : output

            // 只对瞬态错误重试（internal error、SIGKILL 等）
            let isTransient = output.contains("internal error")
                || process.terminationStatus == 9
                || process.terminationStatus == 137
            if !isTransient { break }
        }

        throw SigningError.codesignFailed(lastError)
    }

    /// 仅清理 codesign 禁止的 resource fork/Finder 信息，保留其它元数据及脚本签名属性。
    private func stripSigningDetritus(from items: [URL]) throws {
        for url in items {
            for name in ["com.apple.ResourceFork", "com.apple.FinderInfo"] {
                let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
                if size < 0 {
                    // 重试时，首次尝试可能已清理 .DS_Store 等杂散文件。
                    if errno == ENOATTR || errno == ENOTSUP || errno == ENOENT { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
                }
                if removexattr(url.path, name, XATTR_NOFOLLOW) != 0, errno != ENOATTR {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
                }
            }
        }
    }

    /// codesign 可以替换只读可执行文件；只在实际操作报告权限错误时请求修复。
    private func withOwnershipRepair(at appURL: URL, operation: () throws -> Void) throws {
        do {
            try operation()
        } catch {
            guard allowAdministratorPrompt, isPermissionFailure(error) else { throw error }
            AppLogger.shared.logContext(
                "应用由 root 安装，尝试请求管理员权限修复",
                details: [("path", appURL.path)],
                level: "WARN"
            )
            try elevateAndFixOwnership(at: appURL)
            do {
                try operation()
            } catch {
                guard isPermissionFailure(error) else { throw error }
                throw SigningError.codesignFailed(
                    String(format: "应用不可写，无法完成重签名：%@".localized, appURL.path)
                        + "\n" + error.localizedDescription
                )
            }
        }
    }

    private func isPermissionFailure(_ error: Error) -> Bool {
        if case SigningError.codesignFailed(let message) = error {
            return message.localizedCaseInsensitiveContains("permission denied")
                || message.localizedCaseInsensitiveContains("operation not permitted")
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(EACCES) || nsError.code == Int(EPERM)
        }
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileReadNoPermission.rawValue
            || nsError.code == CocoaError.fileWriteNoPermission.rawValue {
            return true
        }
        return nsError.underlyingErrors.contains(where: isPermissionFailure)
    }

    /// 请求管理员权限，将 app bundle 的 owner 修改为当前用户
    ///
    /// 使用 NSAppleScript 弹出系统密码框，执行 chown -R 将 bundle 所有权改为当前用户。
    /// App Store 应用受 SIP 保护，chown 可能部分失败，不抛出错误仅记录日志。
    private func elevateAndFixOwnership(at appURL: URL) throws {
        let username = NSUserName()
        let script = Self.ownershipRepairAppleScript(username: username, appPath: appURL.path)

        let appleScript = NSAppleScript(source: script)
        var errorInfo: NSDictionary?
        appleScript?.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let number = errorInfo[NSAppleScript.errorNumber] as? Int ?? -1
            if number == -128 {
                throw SigningError.codesignFailed("用户取消了权限授权".localized)
            }
            // chown 失败（如 SIP 保护的文件），不抛出，仅记录日志
            let msg = errorInfo[NSAppleScript.errorMessage] as? String ?? "未知错误".localized
            AppLogger.shared.logContext(
                "权限修复部分失败（可能受 SIP 保护），继续尝试签名",
                details: [("path", appURL.path), ("error", msg)],
                level: "WARN"
            )
        } else {
            AppLogger.shared.logContext(
                "已通过管理员权限修复 bundle 所有权",
                details: [("path", appURL.path), ("new_owner", username)]
            )
        }
    }

    /// 清理 .app bundle 根目录中的杂散文件，避免 codesign 报 "unsealed contents present in the bundle root"
    private func cleanBundleRoot(at appURL: URL) {
        let strayNames: Set<String> = [".DS_Store", "__MACOSX", ".git", ".svn"]
        guard let items = try? fileManager.contentsOfDirectory(atPath: appURL.path) else { return }
        for item in items {
            guard strayNames.contains(item) else { continue }
            let itemURL = appURL.appendingPathComponent(item)
            try? fileManager.removeItem(at: itemURL)
        }
    }

    /// 同步获取签名身份（actor 内部用）
    private func syncGetSigningIdentity(appURL: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dvv", appURL.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        for line in output.components(separatedBy: "\n") {
            if line.contains("Authority=") {
                return line
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "Authority=", with: "")
            }
        }
        return nil
    }
}
