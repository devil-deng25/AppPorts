import AppKit
import Darwin
import Foundation

struct SignatureTemporarySpaceRequirement: Equatable, Sendable {
    let parentURL: URL
    let logicalSourceBytes: Int64
    let requiredAdditionalBytes: Int64
}

/// Manual signature changes own one temporary candidate. Persistent records
/// describe that operation until exchange and real cleanup have both completed.
actor CodeSigner {
    enum SigningError: LocalizedError {
        case codesignFailed(String), backupFailed(String), restoreFailed(String)
        case noBackupFound, legacyBackupIncomplete, snapshotInvalid, applicationChanged
        case operationInProgress, atomicReplacementUnavailable, originalApplicationMismatch
        case applicationUnavailable(URL), sandboxedApplication(URL), lockedApplication(URL)
        case entitlementsUnavailable(String), originalIdentityUnavailable, incompletePreparation
        case incompatibleWriter(String)
        case temporaryCapacityUnavailable(URL)
        case insufficientTemporarySpace(parent: URL, requiredBytes: Int64, availableBytes: Int64)
        case temporaryMaterialCannotBeTrashed, deletionDispositionChanged
        case unreadableOperationRecord(URL)

        var errorDescription: String? {
            switch self {
            case .codesignFailed(let reason): return "签名失败：".localized + reason
            case .backupFailed(let reason): return "无法读取历史签名原件：".localized + reason
            case .restoreFailed(let reason): return "恢复签名失败：".localized + reason
            case .noBackupFound: return "没有旧版恢复备份。请选择同版本官方原件，或从官方渠道重新安装。".localized
            case .legacyBackupIncomplete: return "旧版记录不包含原始应用，不能恢复签名字节。请选择同版本官方原件或从官方渠道重新安装。".localized
            case .snapshotInvalid: return "签名材料缺失、身份改变或校验失败，已保留现有应用和可用材料。".localized
            case .applicationChanged: return "应用对象、版本或内容已经改变，原有确认不再适用。请重新检查当前应用。".localized
            case .operationInProgress: return "已有文件操作或该应用的签名准备尚未完成，请先在副本页继续或取消原操作。".localized
            case .atomicReplacementUnavailable: return "此存储不支持安全交换应用。请将应用迁回本地后重试；原应用已保留。".localized
            case .originalApplicationMismatch: return "所选原件的应用标识、双版本或可验证开发者身份不匹配，或严格验签失败。请选择同版本官方原件。".localized
            case .applicationUnavailable(let url): return "无法找到真实应用：".localized + url.path
            case .sandboxedApplication(let url): return "此应用有沙盒授权，需要针对本次应用单独确认重签后果：".localized + url.lastPathComponent
            case .lockedApplication(let url): return "此路径的锁定来源无法确认，未解除其属性。请明确解锁后重试：".localized + url.path
            case .entitlementsUnavailable(let reason): return "未能确认应用签名或授权，已暂停本次签名：".localized + reason
            case .originalIdentityUnavailable: return "没有足够的原开发者身份事实来证明此次恢复。请通过官方更新或重新安装恢复官方状态；应用数据不会被本操作覆盖。".localized
            case .incompletePreparation: return "这次临时副本尚未完成签名验证。请先取消该准备，再重新发起手动重签。".localized
            case .incompatibleWriter(let reason): return reason
            case .temporaryCapacityUnavailable(let parent): return "无法确认临时签名位置的可用空间：".localized + parent.path
            case .insufficientTemporarySpace(let parent, let required, let available):
                return String(format: "临时签名副本空间不足：需要 %@，可用 %@。位置：%@".localized,
                    LocalizedByteCountFormatter.string(fromByteCount: required),
                    LocalizedByteCountFormatter.string(fromByteCount: available), parent.path)
            case .temporaryMaterialCannotBeTrashed:
                return "临时签名副本不能移入废纸篓。请在副本页继续清理，或取消尚未提交的准备。".localized
            case .deletionDispositionChanged:
                return "此操作已确定清理方式，不能改用另一种删除方式。请在副本页继续原操作。".localized
            case .unreadableOperationRecord(let url):
                return "此应用的签名操作记录无法读取；请在副本页查看保留的记录：".localized + url.path
            }
        }
    }

    enum SignatureStatus: Equatable, Sendable { case valid, adHoc, unsigned, invalid, unknown }
    enum RecordRemovalConfirmation: Sendable {
        /// Explain that files and volumes stay intact and no storage is freed.
        case keepAllFilesAndVolumes
    }
    enum RecordRemovalResult: Equatable, Sendable {
        case recordRemoved
        /// An old row may have disappeared or changed. Neither case authorizes
        /// deleting a different record or claiming its original was deleted.
        case recordUnavailable
    }
    static let sandboxEntitlementKey = "com.apple.security.app-sandbox"
    static var defaultBackupDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppPorts/signature-backups")
    }

    let backupDirectoryURL: URL
    let operations: SignatureOperationStore
    let history: SignatureHistoryStore
    let facts: SignatureFactStore
    let protection: AppUpdateProtectionStore
    let runner: any ShellCommandRunning
    let commandTimeout: TimeInterval
    let inspectSignature: @Sendable (URL) throws -> SignatureInspection
    let requireDeveloperIdentity: @Sendable (OriginalDeveloperIdentity, URL) throws -> Void
    let requireStopped: @Sendable (URL, String) async throws -> Void
    let recoveryDependencyCheck: @Sendable (SignatureRecoveryRequirements) async throws -> Void
    let checkpoint: @Sendable (SignatureOperationRecord) throws -> Void
    let synchronizeTree: @Sendable (URL) throws -> Void
    let synchronizeDirectory: @Sendable (URL) throws -> Void
    let deleteTemporaryTree: @Sendable (URL, SignatureRemovalManifest, Bool, Bool) throws -> Void
    let trashBackupSnapshot: (@Sendable (URL) throws -> Void)?
    let trashHistoricalMaterial: @Sendable (URL) throws -> Void
    let deleteBackupRecordFile: @Sendable (URL) throws -> Void
    let exchangeApplications: @Sendable (URL, URL) throws -> Void
    let copyApplication: @Sendable (URL, URL) throws -> Void
    let availableTemporaryCapacity: @Sendable (URL) throws -> Int64

    init(
        backupDirectoryURL: URL? = nil,
        allowAdministratorPrompt: Bool = true,
        trashBackupSnapshot: (@Sendable (URL) throws -> Void)? = nil,
        trashHistoricalMaterial: @escaping @Sendable (URL) throws -> Void = { try SignatureSnapshot.trash($0) },
        deleteBackupRecordFile: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
        exchangeApplications: @escaping @Sendable (URL, URL) throws -> Void = { try SignatureSnapshot.exchange($0, $1) },
        copyApplication: @escaping @Sendable (URL, URL) throws -> Void = { try SignatureSnapshot.copyContents(from: $0, into: $1) },
        availableTemporaryCapacity: @escaping @Sendable (URL) throws -> Int64 = { try CodeSigner.availableTemporarySpace(at: $0) },
        runner: any ShellCommandRunning = ProcessCommandRunner(captureLimit: 1_048_576),
        commandTimeout: TimeInterval = 120,
        inspectSignature: @escaping @Sendable (URL) throws -> SignatureInspection = { try SignatureInspector.inspect(at: $0) },
        requireDeveloperIdentity: @escaping @Sendable (OriginalDeveloperIdentity, URL) throws -> Void = { try SignatureInspector.require($0, at: $1) },
        requireStopped: @escaping @Sendable (URL, String) async throws -> Void = { app, identifier in
            try await DataOperationSafety().requireNoKnownWriters(at: app, bundleIdentifier: identifier)
        },
        recoveryDependencyCheck: @escaping @Sendable (SignatureRecoveryRequirements) async throws -> Void = {
            try await SignatureRecoveryDependencyCheck.requireSafeRestore($0)
        },
        checkpoint: @escaping @Sendable (SignatureOperationRecord) throws -> Void = { _ in },
        synchronizeTree: @escaping @Sendable (URL) throws -> Void = { try DurableFileIO.syncTree(at: $0) },
        synchronizeDirectory: @escaping @Sendable (URL) throws -> Void = { try DurableFileIO.syncDirectory(at: $0) },
        deleteTemporaryTree: @escaping @Sendable (URL, SignatureRemovalManifest, Bool, Bool) throws -> Void = {
            try $1.remove(at: $0, allowingPartial: $2, unlockCopiedFlags: $3)
        },
        protectionStore: AppUpdateProtectionStore? = nil,
        applicationTransferStore: AppTransferStore? = nil
    ) {
        let directory = backupDirectoryURL ?? Self.defaultBackupDirectoryURL
        self.backupDirectoryURL = directory
        operations = .init(backupDirectoryURL: directory)
        history = .init(backupDirectoryURL: directory)
        let transfers = applicationTransferStore ?? (directory.standardizedFileURL == Self.defaultBackupDirectoryURL.standardizedFileURL ? .shared
            : AppTransferStore(directoryURL: directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + "-app-transfers")))
        facts = .init(backupDirectoryURL: directory, applicationTransferStore: transfers)
        protection = protectionStore ?? AppUpdateProtectionStore(transferStore: transfers)
        self.runner = runner
        self.commandTimeout = commandTimeout
        self.inspectSignature = inspectSignature
        self.requireDeveloperIdentity = requireDeveloperIdentity
        self.requireStopped = requireStopped
        self.recoveryDependencyCheck = recoveryDependencyCheck
        self.checkpoint = checkpoint
        self.synchronizeTree = synchronizeTree
        self.synchronizeDirectory = synchronizeDirectory
        self.deleteTemporaryTree = deleteTemporaryTree
        self.trashBackupSnapshot = trashBackupSnapshot
        self.trashHistoricalMaterial = trashHistoricalMaterial
        self.deleteBackupRecordFile = deleteBackupRecordFile
        self.exchangeApplications = exchangeApplications
        self.copyApplication = copyApplication
        self.availableTemporaryCapacity = availableTemporaryCapacity
        // Kept as a source-compatible initializer parameter. Signature changes
        // never recursively chown the live application to obtain permission.
        _ = allowAdministratorPrompt
    }

    static func ownershipRepairAppleScript(username: String, appPath: String) -> String {
        """
        set targetPath to \(AppMigrationService.appleScriptStringLiteral(appPath))
        set userName to \(AppMigrationService.appleScriptStringLiteral(username))
        do shell script "/usr/sbin/chown -R -P " & quoted form of userName & " " & quoted form of targetPath with administrator privileges
        """
    }

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


    static func entitlements(at appURL: URL) -> [String: Any]? { try? SignatureInspector.entitlements(at: appURL) }
    static func sandboxStatus(at appURL: URL) -> SignatureSandboxStatus {
        do { return try SignatureInspector.inspect(at: appURL).sandboxStatus }
        catch { return .unavailable(error.localizedDescription) }
    }
    /// Display-only compatibility helper. Mutation paths use sandboxStatus and
    /// explicitly reject an unavailable read instead of treating it as false.
    static func isSandboxed(at appURL: URL) -> Bool { sandboxStatus(at: appURL) == .sandboxed }

    private nonisolated static let temporaryMetadataReserveBytes: Int64 = 16 * 1024 * 1024

    /// A preview and pre-copy budget for the one temporary application. Sparse
    /// files and clones are charged at logical size because ordinary copying is
    /// always a supported fallback. No application payload or xattr value is read.
    nonisolated static func temporarySpaceRequirement(appURL: URL, sourceURL: URL? = nil) throws -> SignatureTemporarySpaceRequirement {
        let app = try resolveAppURL(at: appURL)
        let source = try sourceURL.map { try resolveAppURL(at: $0) } ?? app
        let parent = app.deletingLastPathComponent()
        var filesystem = statfs()
        guard statfs(parent.path, &filesystem) == 0 else { throw SigningError.temporaryCapacityUnavailable(parent) }
        let blockSize = max(Int64(filesystem.f_bsize), 4_096)
        var logicalBytes: Int64 = 0
        var requiredBytes = temporaryMetadataReserveBytes
        func adding(_ value: Int64, to total: Int64) throws -> Int64 {
            let (sum, overflow) = total.addingReportingOverflow(value)
            guard value >= 0, !overflow else { throw SigningError.snapshotInvalid }
            return sum
        }
        func accountBytes(_ size: Int64) throws {
            logicalBytes = try adding(size, to: logicalBytes)
            let rounded = try adding(blockSize - 1, to: size) / blockSize * blockSize
            requiredBytes = try adding(rounded, to: requiredBytes)
        }
        func account(_ url: URL) throws {
            try Task.checkCancellation()
            let info = try SignatureSnapshot.info(at: url)
            switch info.st_mode & S_IFMT {
            case S_IFREG, S_IFLNK: try accountBytes(info.st_size)
            case S_IFDIR: break
            default: throw SigningError.snapshotInvalid
            }
            // Budget metadata and the resource seal per entry, in addition to
            // a fixed reserve for signing and operation bookkeeping.
            requiredBytes = try adding(blockSize, to: requiredBytes)
            let count = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
            if count < 0 {
                if errno == ENOTSUP { return }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard count <= 1_048_576 else { throw SigningError.snapshotInvalid }
            if count == 0 { return }
            var names = [CChar](repeating: 0, count: count)
            let read = names.withUnsafeMutableBufferPointer { listxattr(url.path, $0.baseAddress, count, XATTR_NOFOLLOW) }
            guard read >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            for nameBytes in names.prefix(read).split(separator: 0) {
                try Task.checkCancellation()
                let name = String(decoding: nameBytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
                guard size >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                try accountBytes(Int64(size))
            }
        }
        try account(source)
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil,
            options: [], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw SigningError.applicationUnavailable(source)
        }
        for case let url as URL in enumerator {
            try account(url)
            if try SignatureSnapshot.info(at: url).st_mode & S_IFMT == S_IFLNK { enumerator.skipDescendants() }
        }
        if let enumerationError { throw enumerationError }
        return .init(parentURL: parent, logicalSourceBytes: logicalBytes, requiredAdditionalBytes: requiredBytes)
    }

    nonisolated static func availableTemporarySpace(at parent: URL) throws -> Int64 {
        var filesystem = statfs()
        guard statfs(parent.path, &filesystem) == 0, filesystem.f_bavail <= UInt64(Int64.max) else {
            throw SigningError.temporaryCapacityUnavailable(parent)
        }
        let (available, overflow) = Int64(filesystem.f_bavail).multipliedReportingOverflow(by: Int64(filesystem.f_bsize))
        guard !overflow, available >= 0 else { throw SigningError.temporaryCapacityUnavailable(parent) }
        return available
    }

    @discardableResult
    func sign(appURL: URL, bundleIdentifier: String?, allowSandboxed: Bool = false,
              expectedFingerprint: String? = nil, expectedIdentity: DataPathIdentity? = nil) async throws -> SignatureOperationResult {
        let app = try Self.resolveAppURL(at: appURL)
        _ = try requireSigningInspection(at: app, allowSandboxed: allowSandboxed)
        try await prepareServices()
        let locks = try acquireLocks()
        defer { locks.forEach { $0.release() } }
        let identity = try DataPathIdentity.capture(app)
        // Service retirement can suspend. Re-read the actual code after the
        // locks are held so an intervening app replacement cannot reuse a stale
        // non-sandbox inspection or developer identity.
        let inspection = try requireSigningInspection(at: app, allowSandboxed: allowSandboxed)
        let version = try SignatureAppVersion.read(at: app)
        let originalFingerprint = try SignatureSnapshot.fingerprint(of: app)
        guard expectedFingerprint == nil || expectedFingerprint == originalFingerprint,
              expectedIdentity == nil || expectedIdentity!.matchesFilesystemObject(identity),
              try DataPathIdentity.capture(app).matchesFilesystemObject(identity) else { throw SigningError.applicationChanged }
        try await requireStopped(app, version.bundleIdentifier)
        try facts.reconcileCommittedMetadata(at: app)
        try requireNoPreparation(for: app)
        let existingFact = try facts.currentFact(at: app, inspection: inspection, verifyContent: true)
        // Invalid/mismatched history stays visible but does not prevent a newly
        // authorized manual signature from using the current application.
        let legacy = try? matchingBackup(app: app, fingerprint: originalFingerprint, fact: existingFact)
        var developer = existingFact?.originalDeveloper
        if developer == nil, let identity = inspection.developerIdentity {
            do { try await verifyStrict(app); developer = identity }
            catch is CancellationError { throw CancellationError() }
            catch { /* Damaged signatures cannot establish a verified original developer. */ }
        }
        if developer == nil, let legacy, legacy.backup.originalSignatureWasValid == true {
            let original = try history.verifiedSnapshot(for: legacy.backup)
            try await verifyStrict(original)
            developer = try inspectSignature(original).developerIdentity
        }
        var record = try startOperation(kind: .sign, app: app, identity: identity, version: version, fingerprint: originalFingerprint)
        do {
            try createCandidate(&record, copying: app)
            guard try SignatureSnapshot.fingerprint(of: record.candidateURL) == originalFingerprint,
                  try SignatureSnapshot.fingerprint(of: app) == originalFingerprint else { throw SigningError.applicationChanged }
            try SignatureSnapshot.validateLinksForSigning(in: record.candidateURL)
            let locked = try unlockCandidate(record.candidateURL)
            do {
                try stripSigningDetritus(in: record.candidateURL)
                try await runCodesign(["--force", "--deep", "--sign", "-", record.candidateURL.path])
                try await verifyStrict(record.candidateURL)
                try restoreCandidateLocks(locked)
            } catch {
                try? restoreCandidateLocks(locked)
                throw error
            }
            // A candidate's inherited root lock is ours to change. An unknown
            // lock on the live root is checked separately before exchange.
            try clearCandidateRootLock(record.candidateURL)
            let signedFingerprint = try SignatureSnapshot.fingerprint(of: record.candidateURL)
            let signedInspection = try inspectSignature(record.candidateURL)
            record.candidateFingerprint = signedFingerprint
            record.legacyRecordPath = legacy?.url.path
            record.pendingFact = .init(installationID: existingFact?.installationID ?? UUID(), applicationPath: app.path,
                applicationIdentity: try DataPathIdentity.capture(record.candidateURL), version: version,
                originalDeveloper: developer, originalFingerprint: existingFact?.originalFingerprint ?? originalFingerprint,
                currentFingerprint: signedFingerprint, currentCodeDirectoryHash: signedInspection.codeDirectoryHash,
                signatureWasReplaced: developer != nil, legacyBackupRecordPath: legacy?.url.path,
                lastOperationID: record.id, updatedAt: Date())
            record.phase = .prepared
            try synchronizeTree(record.candidateURL)
            try write(record)
            return try await commit(&record)
        } catch {
            // A failed post-exchange checkpoint must never turn into a rollback
            // or a claim that cancellation prevented the signature change.
            if (try? hasExchanged(record)) == true { return await finishCommitted(record, priorWarning: error.localizedDescription) }
            await cleanFailedPreparation(record, failure: error)
            throw error
        }
    }

    @discardableResult
    func restoreSignature(appURL: URL, bundleIdentifier: String, originalApplication: URL? = nil,
                          historicalMaterialID: String? = nil) async throws -> SignatureOperationResult {
        let app = try Self.resolveAppURL(at: appURL)
        try await prepareServices()
        let locks = try acquireLocks()
        defer { locks.forEach { $0.release() } }
        try facts.reconcileCommittedMetadata(at: app)
        let pendingOperations = try operationsForApplication(app)
        if originalApplication == nil, historicalMaterialID == nil {
            for pending in pendingOperations where pending.kind == .restore {
                if try hasExchanged(pending) { return await finishCommitted(pending) }
            }
        }
        if originalApplication == nil, historicalMaterialID == nil,
           let backup = try history.read(bundleIdentifier: bundleIdentifier), let cleanup = backup.cleanup,
           try SignatureSnapshot.fingerprint(of: app) == cleanup.applicationFingerprint {
            do {
                try finishBackupCleanup(backup, recordURL: history.recordURL(bundleIdentifier: bundleIdentifier), app: app,
                                        applicationFingerprint: cleanup.applicationFingerprint)
                return .init(applicationURL: app, operationID: nil, committed: true, cleanupWarning: nil)
            } catch { return .init(applicationURL: app, operationID: nil, committed: true, cleanupWarning: error.localizedDescription) }
        }
        try requireNoPreparation(for: app, records: pendingOperations)
        let source = try await restorationSource(app: app, bundleIdentifier: bundleIdentifier,
                                               originalApplication: originalApplication, historicalMaterialID: historicalMaterialID)
        try await recoveryDependencyCheck(source.requirements)
        let version = source.applicationVersion
        try await requireStopped(app, version.bundleIdentifier)
        var record = try startOperation(kind: .restore, app: app, identity: source.applicationIdentity,
                                        version: version, fingerprint: source.applicationFingerprint)
        record.originalSourcePath = source.url.path
        record.legacyRecordPath = source.recordURL?.path
        record.recoveryRequirements = .init(source.requirements)
        try write(record)
        do {
            try createCandidate(&record, copying: source.url)
            guard try SignatureSnapshot.fingerprint(of: record.candidateURL) == source.requirements.originalFingerprint else { throw SigningError.snapshotInvalid }
            // Immutable bits in old snapshots are not signature data and are not
            // replayed into the restored application. Only current owned update
            // protection can be re-applied after the verified exchange.
            _ = try unlockCandidate(record.candidateURL)
            if source.verifySignature { try await verifyStrict(record.candidateURL) }
            let restoredFingerprint = try SignatureSnapshot.fingerprint(of: record.candidateURL)
            let restoredInspection = try inspectSignature(record.candidateURL)
            let existing = try facts.currentFact(at: app, verifyContent: true)
            record.pendingFact = .init(installationID: existing?.installationID ?? UUID(), applicationPath: app.path,
                applicationIdentity: try DataPathIdentity.capture(record.candidateURL), version: version,
                originalDeveloper: existing?.originalDeveloper ?? restoredInspection.developerIdentity,
                originalFingerprint: existing?.originalFingerprint ?? restoredFingerprint, currentFingerprint: restoredFingerprint,
                currentCodeDirectoryHash: restoredInspection.codeDirectoryHash, signatureWasReplaced: false,
                legacyBackupRecordPath: nil, lastOperationID: record.id, updatedAt: Date())
            record.candidateFingerprint = restoredFingerprint
            record.phase = .prepared
            try synchronizeTree(record.candidateURL)
            try write(record)
            return try await commit(&record)
        } catch {
            if (try? hasExchanged(record)) == true { return await finishCommitted(record, priorWarning: error.localizedDescription) }
            await cleanFailedPreparation(record, failure: error)
            throw error
        }
    }

    func recoveryRequirements(appURL: URL, bundleIdentifier: String, originalApplication: URL? = nil,
                              historicalMaterialID: String? = nil) async throws -> SignatureRecoveryRequirements {
        let app = try Self.resolveAppURL(at: appURL)
        return try await restorationSource(app: app, bundleIdentifier: bundleIdentifier,
            originalApplication: originalApplication, historicalMaterialID: historicalMaterialID).requirements
    }

    func verify(appURL: URL) async -> SignatureStatus {
        do {
            try await verifyStrict(appURL)
            return .valid
        } catch is CancellationError { return .unknown }
        catch {
            guard let info = try? inspectSignature(appURL) else { return .unknown }
            return info.sandboxStatus == .unsigned ? .unsigned : .invalid
        }
    }

    func getSigningIdentity(appURL: URL) async -> String? { try? inspectSignature(appURL).developerIdentity?.authority }
    func hasBackup(bundleIdentifier: String) -> Bool { (try? history.read(bundleIdentifier: bundleIdentifier)) != nil }

    nonisolated static func hasSignatureBackups(backupDirectoryURL: URL? = nil) -> Bool {
        let directory = backupDirectoryURL ?? defaultBackupDirectoryURL
        return ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).contains { $0.hasSuffix(".plist") }
    }
    nonisolated static func hasSignatureRecords(backupDirectoryURL: URL? = nil) -> Bool {
        let store = SignatureFactStore(backupDirectoryURL: backupDirectoryURL)
        if FileManager.default.fileExists(atPath: store.directoryURL.path),
           (try? FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path)) == nil { return true }
        return hasSignatureBackups(backupDirectoryURL: backupDirectoryURL)
            || ((try? FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path)) ?? []).contains { $0.hasSuffix(".plist") }
    }
    nonisolated static func originalSigningIdentity(bundleIdentifier: String, backupDirectoryURL: URL? = nil) -> String? {
        try? SignatureHistoryStore(backupDirectoryURL: backupDirectoryURL ?? defaultBackupDirectoryURL)
            .read(bundleIdentifier: bundleIdentifier)?.signingIdentity
    }
    nonisolated static func originalSigningIdentity(appURL: URL, backupDirectoryURL: URL? = nil) -> String? {
        if let fact = try? SignatureFactStore(backupDirectoryURL: backupDirectoryURL).currentFact(at: appURL),
           let developer = fact.originalDeveloper { return developer.authority ?? developer.teamIdentifier }
        let history = SignatureHistoryStore(backupDirectoryURL: backupDirectoryURL ?? defaultBackupDirectoryURL)
        guard let identifier = Self.bundleIdentifier(at: appURL), let backup = try? history.read(bundleIdentifier: identifier),
              (try? history.belongs(backup, to: appURL)) == true else { return nil }
        return backup.signingIdentity
    }
    nonisolated static func isSignatureReplaced(originalIdentity: String?, currentlyAdHoc: Bool) -> Bool {
        currentlyAdHoc && originalIdentity != nil && originalIdentity != "" && originalIdentity != "ad-hoc"
    }

    nonisolated static func hasUnavailableSignatureRecord(at app: URL, bundleIdentifier: String, backupDirectoryURL: URL? = nil) -> Bool {
        var paths = Set([app.standardizedFileURL.path, app.resolvingSymlinksInPath().standardizedFileURL.path])
        if let target = try? String(contentsOf: app.appendingPathComponent("Contents/Resources/real_app_path.txt"), encoding: .utf8) {
            let path = target.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("/") { paths.insert(URL(fileURLWithPath: path).standardizedFileURL.path) }
        }
        let store = SignatureFactStore(backupDirectoryURL: backupDirectoryURL)
        if let inventory = try? store.inventory(),
           inventory.facts.contains(where: { $0.version.bundleIdentifier == bundleIdentifier && paths.contains($0.applicationPath) })
            || inventory.unreadableRecords.contains(where: { $0.applicationPath.map(paths.contains) == true }) { return true }
        if let backup = try? SignatureHistoryStore(backupDirectoryURL: backupDirectoryURL ?? defaultBackupDirectoryURL)
            .read(bundleIdentifier: bundleIdentifier), paths.contains(backup.originalPath) { return true }
        return false
    }

    private func prepareServices() async throws {
        if backupDirectoryURL.standardizedFileURL == Self.defaultBackupDirectoryURL.standardizedFileURL {
            try await AutoResignInstaller.refreshInstalledScriptIfNeeded()
        }
    }

    private func acquireLocks() throws -> [OperationLock] {
        let globalURL = backupDirectoryURL.standardizedFileURL == Self.defaultBackupDirectoryURL.standardizedFileURL
            ? OperationLock.defaultFileURL : backupDirectoryURL.deletingLastPathComponent().appendingPathComponent("operation.lock")
        let global = OperationLock(fileURL: globalURL)
        guard global.tryAcquire() else {
            if let reason = global.admissionFailureReason { throw SigningError.incompatibleWriter(reason) }
            throw SigningError.operationInProgress
        }
        let signature = OperationLock(fileURL: backupDirectoryURL.appendingPathComponent("signature-operation.lock"))
        guard signature.tryAcquire() else {
            global.release()
            if let reason = signature.admissionFailureReason { throw SigningError.incompatibleWriter(reason) }
            throw SigningError.operationInProgress
        }
        return [signature, global]
    }

    private func requireWriterAdmission() throws {
        try WriterAdmission.recheck(dataDirectory: backupDirectoryURL.deletingLastPathComponent())
    }

    private func requireSigningInspection(at app: URL, allowSandboxed: Bool) throws -> SignatureInspection {
        let inspection: SignatureInspection
        do { inspection = try inspectSignature(app) }
        catch { throw SigningError.entitlementsUnavailable(error.localizedDescription) }
        switch inspection.sandboxStatus {
        case .sandboxed where !allowSandboxed: throw SigningError.sandboxedApplication(app)
        case .unavailable(let reason): throw SigningError.entitlementsUnavailable(reason)
        default: return inspection
        }
    }

    private func operationsForApplication(_ app: URL) throws -> [SignatureOperationRecord] {
        let identity = try DataPathIdentity.capture(app)
        let inventory = try operations.inventory()
        if let unreadable = inventory.unreadableRecords.first(where: { $0.concerns(app, identity: identity) }) {
            throw SigningError.unreadableOperationRecord(unreadable.url)
        }
        return inventory.records.filter { $0.applicationPath == app.path }
    }

    private func requireNoPreparation(for app: URL, records: [SignatureOperationRecord]? = nil) throws {
        for record in try records ?? operationsForApplication(app)
            where ![.committed, .cleaning, .abandoned].contains(record.phase) {
            throw SigningError.operationInProgress
        }
    }

    private func write(_ record: SignatureOperationRecord) throws {
        try checkpoint(record)
        try operations.write(record)
    }

    private func startOperation(kind: SignatureOperationRecord.Kind, app: URL, identity: DataPathIdentity,
                                version: SignatureAppVersion, fingerprint: String) throws -> SignatureOperationRecord {
        try Task.checkCancellation()
        try requireUnchangedApplication(app, identity: identity, version: version, fingerprint: fingerprint)
        let id = UUID()
        let directory = app.deletingLastPathComponent().appendingPathComponent(".AppPorts-signature-" + id.uuidString)
        let record = SignatureOperationRecord(id: id, kind: kind, createdAt: Date(), applicationPath: app.path,
            applicationIdentity: identity,
            applicationParentIdentity: try DataPathIdentity.capture(app.deletingLastPathComponent()),
            version: version, originalFingerprint: fingerprint, directoryPath: directory.path, phase: .preparing,
            updateProtection: try protection.captureForExchange(at: app))
        try write(record) // creation intent precedes mkdir; no adoption by a guessed name
        return record
    }

    private func requireUnchangedApplication(_ app: URL, identity: DataPathIdentity,
                                             version: SignatureAppVersion, fingerprint: String) throws {
        guard try DataPathIdentity.capture(app).matchesFilesystemObject(identity),
              try SignatureAppVersion.read(at: app) == version,
              try SignatureSnapshot.fingerprint(of: app) == fingerprint,
              try DataPathIdentity.capture(app).matchesFilesystemObject(identity) else { throw SigningError.applicationChanged }
    }

    private func createCandidate(_ record: inout SignatureOperationRecord, copying source: URL) throws {
        try requireParent(record)
        let requirement = try Self.temporarySpaceRequirement(appURL: record.applicationURL, sourceURL: source)
        guard requirement.parentURL.path == record.applicationURL.deletingLastPathComponent().path else { throw SigningError.applicationChanged }
        try requireTemporarySpace(requirement)
        try requireParent(record)
        guard mkdir(record.directoryPath, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        record.directoryIdentity = try DataPathIdentity.capture(record.directoryURL)
        try write(record)
        guard mkdir(record.candidateURL.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        record.candidateIdentity = try DataPathIdentity.capture(record.candidateURL)
        try write(record)
        try copyApplication(source, record.candidateURL)
        guard try DataPathIdentity.capture(record.candidateURL).matchesFilesystemObject(record.candidateIdentity!) else { throw SigningError.applicationChanged }
    }

    private func commit(_ record: inout SignatureOperationRecord) async throws -> SignatureOperationResult {
        try Task.checkCancellation()
        try requireParent(record)
        try requireCandidate(record)
        try await requireStopped(record.applicationURL, record.version.bundleIdentifier)
        if let recovery = record.recoveryRequirements { try await recoveryDependencyCheck(recovery.requirements(for: record)) }
        guard try DataPathIdentity.capture(record.applicationURL).matchesFilesystemObject(record.applicationIdentity),
              try SignatureAppVersion.read(at: record.applicationURL) == record.version,
              try SignatureSnapshot.fingerprint(of: record.applicationURL) == record.originalFingerprint,
              try SignatureSnapshot.fingerprint(of: record.candidateURL) == record.candidateFingerprint else { throw SigningError.applicationChanged }
        // A prepared/resumed candidate already occupies its full-copy budget.
        // Recheck only the remaining metadata headroom before exchange.
        try requireTemporarySpace(.init(parentURL: record.applicationURL.deletingLastPathComponent(),
            logicalSourceBytes: 0, requiredAdditionalBytes: Self.temporaryMetadataReserveBytes))
        try requireWriterAdmission()
        if let token = record.updateProtection { try protection.suspendForExchange(token, at: record.applicationURL) }
        guard try SignatureSnapshot.info(at: record.applicationURL).st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) == 0 else {
            throw SigningError.lockedApplication(record.applicationURL)
        }
        record.oldApplicationManifest = try SignatureRemovalManifest.capture(at: record.applicationURL)
        guard try SignatureSnapshot.fingerprint(of: record.applicationURL) == record.originalFingerprint else { throw SigningError.applicationChanged }
        try Task.checkCancellation()
        record.phase = .switching
        try write(record)
        try requireWriterAdmission()
        // No suspension/cancellation point between durable intent and a durable
        // committed record. A late cancellation is reported as a completed change.
        try exchangeApplications(record.applicationURL, record.candidateURL)
        record.phase = .committed
        return await finishCommitted(record)
    }

    private func requireTemporarySpace(_ requirement: SignatureTemporarySpaceRequirement) throws {
        let available = try availableTemporaryCapacity(requirement.parentURL)
        guard available >= 0 else { throw SigningError.temporaryCapacityUnavailable(requirement.parentURL) }
        guard available >= requirement.requiredAdditionalBytes else {
            throw SigningError.insufficientTemporarySpace(parent: requirement.parentURL,
                requiredBytes: requirement.requiredAdditionalBytes, availableBytes: available)
        }
    }

    private func hasExchanged(_ record: SignatureOperationRecord) throws -> Bool {
        try requireParent(record)
        guard let candidate = record.candidateIdentity else { return false }
        let current = try DataPathIdentity.capture(record.applicationURL)
        if current.matchesFilesystemObject(candidate) {
            if try SignatureSnapshot.entryExists(record.candidateURL) {
                guard try DataPathIdentity.capture(record.candidateURL).matchesFilesystemObject(record.applicationIdentity) else { throw SigningError.applicationChanged }
            } else if ![.committed, .cleaning].contains(record.phase) { throw SigningError.applicationChanged }
            return true
        }
        if [.committed, .cleaning].contains(record.phase), !current.matchesFilesystemObject(record.applicationIdentity) {
            // The committed application may have been legitimately updated. It
            // is never compared with the inactive original's cleanup baseline.
            return true
        }
        guard current.matchesFilesystemObject(record.applicationIdentity) else { throw SigningError.applicationChanged }
        return false
    }

    private func finishCommitted(_ input: SignatureOperationRecord, priorWarning: String? = nil) async -> SignatureOperationResult {
        var record = input
        do {
            guard try hasExchanged(record) else { throw SigningError.applicationChanged }
            try synchronizeConfirmedDirectory(record.applicationURL.deletingLastPathComponent(), identity: record.applicationParentIdentity)
            if try SignatureSnapshot.entryExists(record.directoryURL) { try DurableFileIO.syncDirectory(at: record.directoryURL) }
            record.phase = .committed
            try write(record)
            // Cancellation defers large scans/cleanup, not the small identity
            // evidence needed by a later signature or location transfer.
            let committedFact = try facts.finishCommittedMetadata(record)
            if Task.isCancelled {
                let warning = "应用替换已完成；取消到达提交之后，请从副本页继续补记状态和清理临时旧包。".localized
                record.warning = warning
                try write(record)
                return .init(applicationURL: record.applicationURL, operationID: record.id, committed: true, cleanupWarning: warning)
            }
            if let fact = committedFact {
                try facts.write(fact)
            }
            if let token = record.updateProtection,
               record.candidateIdentity?.matchesFilesystemObject(try DataPathIdentity.capture(record.applicationURL)) == true {
                try protection.commitExchange(token, to: record.applicationURL)
            }
            try await cleanupCommitted(&record)
            if let priorWarning { AppLogger.shared.logContext("签名提交已重新对账并完成清理", details: [("recovered_error", priorWarning)]) }
            return .init(applicationURL: record.applicationURL, operationID: record.id, committed: true, cleanupWarning: nil)
        } catch {
            record.warning = error.localizedDescription
            try? write(record)
            return .init(applicationURL: record.applicationURL, operationID: record.id, committed: true,
                         cleanupWarning: error.localizedDescription)
        }
    }

    private func cleanupCommitted(_ record: inout SignatureOperationRecord) async throws {
        try requireParent(record)
        guard try hasExchanged(record) else { throw SigningError.applicationChanged }
        if try SignatureSnapshot.entryExists(record.directoryURL) {
            try requireDirectory(record)
            if try SignatureSnapshot.entryExists(record.candidateURL) {
                guard let manifest = record.oldApplicationManifest else { throw SigningError.snapshotInvalid }
                try await requireStopped(record.candidateURL, record.version.bundleIdentifier)
                record.phase = .cleaning
                let partial = record.cleanupStarted
                try manifest.verify(at: record.candidateURL, allowingPartial: partial)
                record.cleanupStarted = true
                try write(record)
                try requireWriterAdmission()
                try deleteTemporaryTree(record.candidateURL, manifest, partial, false)
                try DurableFileIO.syncDirectory(at: record.directoryURL)
            } else if !record.cleanupStarted { throw SigningError.snapshotInvalid }
            try requireWriterAdmission()
            guard rmdir(record.directoryPath) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try DurableFileIO.syncDirectory(at: record.applicationURL.deletingLastPathComponent())
        } else if !record.cleanupStarted { throw SigningError.snapshotInvalid }
        if record.kind == .restore, let path = record.legacyRecordPath, let fingerprint = record.candidateFingerprint {
            let url = URL(fileURLWithPath: path)
            // Old operations may have linked an unavailable history record.
            // Completing the temporary package never requires inventing proof
            // that those independent historical files were deleted.
            let backup = try? history.read(at: url)
            if let backup, try canCleanHistoricalOriginal(backup, recordURL: url, restoredFingerprint: fingerprint) {
                try finishBackupCleanup(backup, recordURL: url, app: record.applicationURL,
                                        applicationFingerprint: fingerprint)
            }
        }
        try requireWriterAdmission()
        try operations.remove(record)
    }

    private func cleanFailedPreparation(_ record: SignatureOperationRecord, failure: Error) async {
        if let unconfirmed = failure as? ShellCommandUnconfirmedTermination {
            var pending = (try? operations.record(id: record.id)) ?? record
            pending.unconfirmedCommand = unconfirmed.process
            pending.warning = unconfirmed.localizedDescription
            try? write(pending)
            return // a child might still be writing; do not remove its workspace
        }
        if failure is CancellationError {
            // A cancelled task must not start another full-tree scan merely to
            // delete its candidate. The confirmed-stopped workspace remains a
            // visible explicit cleanup action, with no work running after return.
            var pending = (try? operations.record(id: record.id)) ?? record
            pending.phase = .cancelling
            pending.warning = "签名准备已取消，原应用未替换。请从副本页清理本次临时副本。".localized
            if let token = pending.updateProtection {
                do {
                    try requireParent(pending)
                    guard try DataPathIdentity.capture(pending.applicationURL).matchesFilesystemObject(pending.applicationIdentity) else { throw SigningError.applicationChanged }
                    try protection.commitExchange(token, to: pending.applicationURL)
                } catch {
                    pending.warning! += "\n" + error.localizedDescription
                }
            }
            try? write(pending)
            return
        }
        do { _ = try cancelUncommitted(record) }
        catch {
            // Preserve the most recent deletion checkpoint, including a
            // partially removed candidate. Never overwrite it with stale input.
            var pending = (try? operations.record(id: record.id)) ?? record
            pending.warning = failure.localizedDescription + "\n" + error.localizedDescription
            try? write(pending)
        }
    }

    private func cancelUncommitted(_ input: SignatureOperationRecord) throws -> SignatureOperationResult {
        var record = input
        try requireWriterAdmission()
        try requireParent(record)
        try requireCommandStopped(&record)
        if record.phase == .abandoned {
            if try !SignatureSnapshot.entryExists(record.directoryURL) {
                try synchronizeConfirmedDirectory(record.applicationURL.deletingLastPathComponent(), identity: record.applicationParentIdentity)
                try requireWriterAdmission()
                try operations.remove(record)
            }
            return .init(applicationURL: record.applicationURL, operationID: record.id, committed: false,
                         cleanupWarning: (try SignatureSnapshot.entryExists(record.directoryURL)) ? record.warning : nil)
        }
        guard try DataPathIdentity.capture(record.applicationURL).matchesFilesystemObject(record.applicationIdentity) else { throw SigningError.applicationChanged }
        if let token = record.updateProtection { try protection.commitExchange(token, to: record.applicationURL) }
        if try SignatureSnapshot.entryExists(record.directoryURL) {
            guard let identity = record.directoryIdentity,
                  try DataPathIdentity.capture(record.directoryURL).matchesFilesystemObject(identity) else {
                record.phase = .abandoned
                record.warning = "临时目录的创建身份未能落盘；已结束本次准备，请检查保留的未知目录：".localized + record.directoryPath
                try write(record)
                return .init(applicationURL: record.applicationURL, operationID: record.id, committed: false, cleanupWarning: record.warning)
            }
            if try SignatureSnapshot.entryExists(record.candidateURL) {
                guard let identity = record.candidateIdentity,
                      try DataPathIdentity.capture(record.candidateURL).matchesFilesystemObject(identity) else {
                    record.phase = .abandoned
                    record.warning = "候选应用的创建身份无法确认；已结束准备并保留该对象：".localized + record.candidateURL.path
                    try write(record)
                    return .init(applicationURL: record.applicationURL, operationID: record.id, committed: false, cleanupWarning: record.warning)
                }
                if record.cleanupManifest == nil { record.cleanupManifest = try SignatureRemovalManifest.capture(at: record.candidateURL) }
                record.phase = .cancelling
                let partial = record.cleanupStarted
                record.cleanupStarted = true
                try write(record)
                try requireWriterAdmission()
                try deleteTemporaryTree(record.candidateURL, record.cleanupManifest!, partial, true)
                try DurableFileIO.syncDirectory(at: record.directoryURL)
            }
            try requireWriterAdmission()
            guard rmdir(record.directoryPath) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        // The directory can already be absent after rmdir succeeded but its
        // parent sync failed. A cold retry must still complete that barrier
        // before losing the only cancellation receipt.
        try synchronizeConfirmedDirectory(record.applicationURL.deletingLastPathComponent(), identity: record.applicationParentIdentity)
        try requireWriterAdmission()
        try operations.remove(record)
        return .init(applicationURL: record.applicationURL, operationID: record.id, committed: false, cleanupWarning: nil)
    }

    private func requireParent(_ record: SignatureOperationRecord) throws {
        guard try DataPathIdentity.capture(record.applicationURL.deletingLastPathComponent()).matchesFilesystemObject(record.applicationParentIdentity) else { throw SigningError.applicationChanged }
    }
    private func synchronizeConfirmedDirectory(_ directory: URL, identity: DataPathIdentity) throws {
        guard try DataPathIdentity.capture(directory).matchesFilesystemObject(identity) else { throw SigningError.applicationChanged }
        try synchronizeDirectory(directory)
        guard try DataPathIdentity.capture(directory).matchesFilesystemObject(identity) else { throw SigningError.applicationChanged }
    }
    private func requireDirectory(_ record: SignatureOperationRecord) throws {
        guard let identity = record.directoryIdentity,
              try DataPathIdentity.capture(record.directoryURL).matchesFilesystemObject(identity) else { throw SigningError.applicationChanged }
    }
    private func requireCandidate(_ record: SignatureOperationRecord) throws {
        try requireDirectory(record)
        guard let identity = record.candidateIdentity,
              try DataPathIdentity.capture(record.candidateURL).matchesFilesystemObject(identity) else { throw SigningError.applicationChanged }
    }

    private func unlockCandidate(_ app: URL) throws -> [URL] {
        var locked: [URL] = []
        for url in try SignatureSnapshot.items(in: app) {
            let info = try SignatureSnapshot.info(at: url)
            if info.st_flags & UInt32(UF_IMMUTABLE) != 0 {
                guard info.st_mode & S_IFMT != S_IFREG || info.st_nlink == 1 else { throw SigningError.lockedApplication(url) }
                guard lchflags(url.path, info.st_flags & ~UInt32(UF_IMMUTABLE)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                locked.append(url)
            }
        }
        return locked
    }
    private func restoreCandidateLocks(_ urls: [URL]) throws {
        for url in urls.reversed() where try SignatureSnapshot.entryExists(url) {
            let info = try SignatureSnapshot.info(at: url)
            guard lchflags(url.path, info.st_flags | UInt32(UF_IMMUTABLE)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }
    private func clearCandidateRootLock(_ app: URL) throws {
        let info = try SignatureSnapshot.info(at: app)
        if info.st_flags & UInt32(UF_IMMUTABLE) != 0,
           lchflags(app.path, info.st_flags & ~UInt32(UF_IMMUTABLE)) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    private func stripSigningDetritus(in app: URL) throws {
        for url in try SignatureSnapshot.items(in: app) {
            for name in ["com.apple.ResourceFork", "com.apple.FinderInfo"] {
                if getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW) < 0 {
                    if errno == ENOATTR || errno == ENOTSUP { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if removexattr(url.path, name, XATTR_NOFOLLOW) != 0,
                   errno != ENOATTR && errno != ENOTSUP { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
        }
        // Unknown bundle-root files are preserved. If codesign refuses them,
        // the original remains intact and the precise diagnostic is returned.
    }
    @discardableResult
    private func runCodesign(_ arguments: [String]) async throws -> ShellCommandResult {
        let result = try await runner.run(executable: "/usr/bin/codesign", arguments: arguments, timeout: commandTimeout)
        if let process = result.runningProcess { throw ShellCommandUnconfirmedTermination(process: process) }
        if result.timedOut { throw SigningError.codesignFailed("codesign 超时，原应用已保留".localized) }
        guard result.status == 0 else { throw SigningError.codesignFailed(result.combinedText) }
        return result
    }
    private func verifyStrict(_ app: URL) async throws {
        try await runCodesign(["--verify", "--deep", "--strict", app.path])
    }

    private func requireCommandStopped(_ record: inout SignatureOperationRecord) throws {
        guard let process = record.unconfirmedCommand else { return }
        guard try !ProcessCommandRunner.isRunning(process) else { throw ShellCommandUnconfirmedTermination(process: process) }
        record.unconfirmedCommand = nil
        try write(record)
    }
}

extension CodeSigner {
    private struct RestorationSource {
        let url: URL
        let recordURL: URL?
        let applicationIdentity: DataPathIdentity
        let applicationVersion: SignatureAppVersion
        let applicationFingerprint: String
        let requirements: SignatureRecoveryRequirements
        let verifySignature: Bool
    }

    private func matchingBackup(app: URL, fingerprint: String, fact: SignatureFact?) throws -> (url: URL, backup: SignatureBackup)? {
        guard let identifier = Self.bundleIdentifier(at: app), let backup = try history.read(bundleIdentifier: identifier),
              try history.belongs(backup, to: app, currentFingerprint: fingerprint, fact: fact),
              backup.schemaVersion == 2 else { return nil }
        _ = try history.verifiedSnapshot(for: backup)
        return (try history.recordURL(bundleIdentifier: identifier), backup)
    }

    private func restorationSource(app: URL, bundleIdentifier: String, originalApplication: URL?,
                                   historicalMaterialID: String?) async throws -> RestorationSource {
        let applicationIdentity = try DataPathIdentity.capture(app)
        let version = try SignatureAppVersion.read(at: app)
        guard version.bundleIdentifier == bundleIdentifier else { throw SigningError.applicationChanged }
        let fingerprint = try SignatureSnapshot.fingerprint(of: app)
        let fact = try facts.currentFact(at: app, verifyContent: true)
        let record: (URL, SignatureBackup)?
        if let historicalMaterialID {
            record = try history.selectedRecord(materialID: historicalMaterialID)
            guard record != nil else { throw SigningError.snapshotInvalid }
        } else if originalApplication != nil {
            // An unrelated unreadable legacy record stays visible, but does
            // not veto a separately verified official repair backed by facts.
            if let backup = try? history.read(bundleIdentifier: bundleIdentifier) {
                record = (try history.recordURL(bundleIdentifier: bundleIdentifier), backup)
            } else { record = nil }
        } else if let backup = try history.read(bundleIdentifier: bundleIdentifier) {
            record = (try history.recordURL(bundleIdentifier: bundleIdentifier), backup)
        } else { record = nil }

        let original: URL
        let originalIdentity: DataPathIdentity
        let originalFingerprint: String
        let verifySignature: Bool
        if let originalApplication {
            original = try Self.resolveAppURL(at: originalApplication)
            guard original != app, try SignatureAppVersion.read(at: original) == version else { throw SigningError.originalApplicationMismatch }
            originalIdentity = try DataPathIdentity.capture(original)
            originalFingerprint = try SignatureSnapshot.fingerprint(of: original)
            let selected = try inspectSignature(original)
            guard let developer = selected.developerIdentity else { throw SigningError.originalApplicationMismatch }
            var expected = fact?.originalDeveloper
            if expected == nil, let record, (try? history.belongs(record.1, to: app, currentFingerprint: fingerprint, fact: fact)) == true,
               let snapshot = try? history.verifiedSnapshot(for: record.1), record.1.originalSignatureWasValid == true {
                try await verifyStrict(snapshot)
                expected = try inspectSignature(snapshot).developerIdentity
            }
            if expected == nil, let current = try? inspectSignature(app), let currentDeveloper = current.developerIdentity {
                try await verifyStrict(app)
                expected = currentDeveloper
            }
            guard let expected else { throw SigningError.originalIdentityUnavailable }
            guard expected.matches(developer) else { throw SigningError.originalApplicationMismatch }
            do {
                try await verifyStrict(original)
                try requireDeveloperIdentity(expected, original)
            } catch is CancellationError { throw CancellationError() }
            catch { throw SigningError.originalApplicationMismatch }
            verifySignature = true
        } else {
            guard let record else { throw SigningError.noBackupFound }
            guard !(try history.hasPendingDeletion(for: record.0, snapshot: history.snapshotURL(for: record.1))) else {
                throw SigningError.snapshotInvalid
            }
            original = try history.verifiedSnapshot(for: record.1)
            originalIdentity = try DataPathIdentity.capture(original)
            originalFingerprint = try SignatureSnapshot.fingerprint(of: original)
            guard try history.belongs(record.1, to: app, currentFingerprint: fingerprint, fact: fact),
                  try SignatureAppVersion.read(at: original) == version else { throw SigningError.applicationChanged }
            verifySignature = record.1.originalSignatureWasValid == true
            if verifySignature { try await verifyStrict(original) }
        }
        let inspection: SignatureInspection
        do { inspection = try inspectSignature(original) }
        catch { throw SigningError.entitlementsUnavailable(error.localizedDescription) }
        if case .unavailable(let reason) = inspection.sandboxStatus { throw SigningError.entitlementsUnavailable(reason) }
        try requireUnchangedApplication(app, identity: applicationIdentity, version: version, fingerprint: fingerprint)
        try requireUnchangedApplication(original, identity: originalIdentity, version: version, fingerprint: originalFingerprint)
        let requirements = SignatureRecoveryRequirements(applicationURL: app, originalApplicationURL: original,
            originalIdentity: originalIdentity, originalFingerprint: originalFingerprint,
            bundleIdentifier: version.bundleIdentifier, isSandboxed: inspection.sandboxStatus == .sandboxed,
            applicationGroups: inspection.applicationGroups, keychainAccessGroups: inspection.keychainAccessGroups)
        // Unrelated history is never cleaned merely because an official original
        // successfully repaired a different installation/version at the same path.
        var applicableRecord: URL?
        if let record, (try? history.belongs(record.1, to: app, currentFingerprint: fingerprint, fact: fact)) == true,
           try canCleanHistoricalOriginal(record.1, recordURL: record.0, restoredFingerprint: originalFingerprint) {
            applicableRecord = record.0
        }
        return .init(url: original, recordURL: applicableRecord, applicationIdentity: applicationIdentity,
                     applicationVersion: version, applicationFingerprint: fingerprint,
                     requirements: requirements, verifySignature: verifySignature)
    }

    @discardableResult
    func discardUnusedOriginalBackup(bundleIdentifier: String, appURL: URL? = nil) async throws -> Bool {
        guard let backup = try history.read(bundleIdentifier: bundleIdentifier),
              backup.schemaVersion == 2, let original = backup.originalFingerprint else { return false }
        try await prepareServices()
        let locks = try acquireLocks()
        defer { locks.forEach { $0.release() } }
        guard let current = try? Self.resolveAppURL(at: appURL ?? URL(fileURLWithPath: backup.originalPath)) else { return false }
        let fact = try facts.currentFact(at: current)
        guard try history.belongs(backup, to: current, fact: fact) else { return false }
        let expected = backup.cleanup?.applicationFingerprint ?? original
        guard try SignatureSnapshot.fingerprint(of: current) == expected else { return false }
        try finishBackupCleanup(backup, recordURL: history.recordURL(bundleIdentifier: bundleIdentifier), app: current,
                                applicationFingerprint: expected)
        return true
    }

    private func canCleanHistoricalOriginal(_ backup: SignatureBackup, recordURL: URL,
                                             restoredFingerprint: String) throws -> Bool {
        do {
            guard !(try history.hasPendingDeletion(for: recordURL, snapshot: history.snapshotURL(for: backup))) else { return false }
            if let cleanup = backup.cleanup {
                guard cleanup.applicationFingerprint == restoredFingerprint, let snapshot = history.snapshotURL(for: backup) else { return false }
                if try !SignatureSnapshot.entryExists(snapshot) {
                    return cleanup.actualDeletionStarted == true && cleanup.removalManifest != nil && cleanup.snapshotIdentity != nil
                }
                return true
            }
            guard backup.schemaVersion == 2, backup.originalFingerprint == restoredFingerprint else { return false }
            _ = try history.verifiedSnapshot(for: backup)
            return true
        } catch is CancellationError { throw CancellationError() }
        catch { return false }
    }

    private func finishBackupCleanup(_ original: SignatureBackup, recordURL: URL, app: URL,
                                     applicationFingerprint: String) throws {
        let parent = backupDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
        let app = try Self.resolveAppURL(at: app)
        guard !app.path.hasPrefix(parent.path + "/"), app != parent,
              Self.bundleIdentifier(at: app) == original.bundleIdentifier,
              try SignatureSnapshot.fingerprint(of: app) == applicationFingerprint,
              try history.read(at: recordURL) == original,
              !(try history.hasPendingDeletion(for: recordURL, snapshot: history.snapshotURL(for: original))) else { throw SigningError.applicationChanged }
        let appIdentity = try DataPathIdentity.capture(app)
        let parentIdentity = try DataPathIdentity.capture(parent)
        var backup = original
        let snapshot = history.snapshotURL(for: backup)
        if backup.snapshotName != nil, snapshot == nil { throw SigningError.snapshotInvalid }
        if let cleanup = backup.cleanup {
            guard cleanup.parentIdentity.matchesFilesystemObject(parentIdentity),
                  cleanup.applicationFingerprint == applicationFingerprint else { throw SigningError.snapshotInvalid }
        } else {
            let snapshotIdentity: DataPathIdentity?
            if let snapshot {
                _ = try history.verifiedSnapshot(for: backup)
                snapshotIdentity = try DataPathIdentity.capture(snapshot)
                guard snapshotIdentity?.matchesFilesystemObject(appIdentity) != true else { throw SigningError.applicationChanged }
            } else { snapshotIdentity = nil }
            backup.cleanup = .init(parentIdentity: parentIdentity, snapshotIdentity: snapshotIdentity,
                                   applicationFingerprint: applicationFingerprint)
            try history.write(backup, to: recordURL)
        }
        guard var cleanup = backup.cleanup else { throw SigningError.snapshotInvalid }
        if let snapshot, try SignatureSnapshot.entryExists(snapshot) {
            guard let expected = cleanup.snapshotIdentity,
                  try DataPathIdentity.capture(snapshot).matchesFilesystemObject(expected),
                  !expected.matchesFilesystemObject(appIdentity) else { throw SigningError.snapshotInvalid }
            let partial = cleanup.actualDeletionStarted == true
            if cleanup.removalManifest == nil {
                _ = try history.verifiedSnapshot(for: backup)
                cleanup.removalManifest = try SignatureRemovalManifest.capture(at: snapshot)
            }
            try cleanup.removalManifest!.verify(at: snapshot, allowingPartial: partial)
            cleanup.actualDeletionStarted = true
            backup.cleanup = cleanup
            try history.write(backup, to: recordURL)
            guard try DataPathIdentity.capture(parent).matchesFilesystemObject(parentIdentity),
                  try DataPathIdentity.capture(app).matchesFilesystemObject(appIdentity),
                  try SignatureSnapshot.fingerprint(of: app) == applicationFingerprint else { throw SigningError.applicationChanged }
            // Keep the injected historical deletion seam for migration of old
            // checkpoints. Default deletion is real deletion, never hidden Trash.
            try requireWriterAdmission()
            if let trashBackupSnapshot { try trashBackupSnapshot(snapshot) }
            else { try cleanup.removalManifest!.remove(at: snapshot, allowingPartial: partial, unlockCopiedFlags: true) }
            guard try !SignatureSnapshot.entryExists(snapshot) else { throw SigningError.snapshotInvalid }
        } else if snapshot != nil && (cleanup.actualDeletionStarted != true || cleanup.removalManifest == nil || cleanup.snapshotIdentity == nil) {
            // A missing old source before any durable deletion intent is not
            // proof of cleanup; it remains an independently removable record.
            throw SigningError.snapshotInvalid
        }
        // Absence after a persisted deletion intent still needs the material's
        // parent barrier. Keep the sole backup record until it has succeeded.
        try synchronizeConfirmedDirectory(parent, identity: cleanup.parentIdentity)
        guard try DataPathIdentity.capture(parent).matchesFilesystemObject(parentIdentity),
              try DataPathIdentity.capture(app).matchesFilesystemObject(appIdentity),
              try SignatureSnapshot.fingerprint(of: app) == applicationFingerprint,
              try history.read(at: recordURL) == backup else { throw SigningError.applicationChanged }
        try requireWriterAdmission()
        try deleteBackupRecordFile(recordURL)
        try synchronizeDirectory(recordURL.deletingLastPathComponent())
        NotificationCenter.default.post(name: .signatureMaterialsDidChange, object: nil)
        NotificationCenter.default.post(name: .appPortsRecordsDidChange, object: nil)
    }

    func signatureMaterials() async throws -> [SignatureMaterial] {
        var materials: [SignatureMaterial] = []
        do { materials += try history.materials() }
        catch is CancellationError { throw CancellationError() }
        catch { materials.append(.unreadableDirectory(at: history.directoryURL, detail: error.localizedDescription)) }
        do { materials += try facts.inventory().unreadableRecords.map(\.material) }
        catch is CancellationError { throw CancellationError() }
        catch { materials.append(.unreadableDirectory(at: facts.directoryURL, detail: error.localizedDescription)) }
        let inventory: SignatureOperationStore.Inventory
        do { inventory = try operations.inventory() }
        catch is CancellationError { throw CancellationError() }
        catch {
            materials.append(.unreadableDirectory(at: operations.directoryURL, detail: error.localizedDescription))
            return materials.sorted { $0.appName.localizedStandardCompare($1.appName) == .orderedAscending }
        }
        materials += inventory.unreadableRecords.map(\.material)
        for record in inventory.records {
            let committed = (try? hasExchanged(record)) == true
            let detail = record.warning ?? (committed ? "应用替换已完成，临时旧包待清理".localized
                : record.phase == .prepared || record.phase == .switching ? "候选已验证，可继续本次交换或取消准备".localized
                : "准备尚未完成，可取消并清理本次临时副本".localized)
            materials.append(.init(id: "operation:" + record.id.uuidString,
                kind: record.phase == .abandoned ? .unclaimedTemporary : .temporaryOperation,
                url: record.directoryURL, appURL: record.applicationURL, appName: record.applicationURL.lastPathComponent,
                bundleIdentifier: record.version.bundleIdentifier, sizeBytes: try? history.allocatedBytes(at: record.directoryURL),
                detail: detail, canResume: committed || [.prepared, .switching, .cancelling].contains(record.phase),
                canCancel: !committed, canRestore: false, canDelete: false))
        }
        return materials.sorted { $0.appName.localizedStandardCompare($1.appName) == .orderedAscending }
    }

    @discardableResult
    func resumeSignatureMaterial(id: String) async throws -> SignatureOperationResult { try await resumeSignatureOperation(id: id) }
    @discardableResult
    func cancelSignatureMaterial(id: String) async throws -> SignatureOperationResult { try await cancelSignatureOperation(id: id) }

    /// Explicitly discards one unusable historical metadata record. Selection
    /// binds its bytes and object identity, and removal uses the existing
    /// single-file manifest; no original application contents are scanned.
    func removeSignatureMaterialRecord(id: String, confirmation: RecordRemovalConfirmation) async throws -> RecordRemovalResult {
        try await prepareServices()
        let locks = try acquireLocks()
        defer { locks.forEach { $0.release() } }
        try Task.checkCancellation()
        guard id.hasPrefix("history:") else { throw SigningError.snapshotInvalid }
        guard let url = try history.selectedRecordURL(materialID: id) else { return .recordUnavailable }
        guard try history.canRemoveRecord(at: url, materialID: id) else {
            throw SigningError.snapshotInvalid
        }
        let manifest = try SignatureRemovalManifest.capture(at: url)
        guard try history.materialID(for: url) == id else { throw SigningError.applicationChanged }
        switch confirmation {
        case .keepAllFilesAndVolumes:
            try requireWriterAdmission()
            try manifest.remove(at: url, allowingPartial: false, unlockCopiedFlags: false)
            try DurableFileIO.syncDirectory(at: url.deletingLastPathComponent())
        }
        NotificationCenter.default.post(name: .signatureMaterialsDidChange, object: nil)
        NotificationCenter.default.post(name: .appPortsRecordsDidChange, object: nil)
        return .recordRemoved
    }

    @discardableResult
    func resumeSignatureOperation(id: String) async throws -> SignatureOperationResult {
        try await prepareServices()
        let locks = try acquireLocks()
        defer { locks.forEach { $0.release() } }
        if let uuid = operationID(id) {
            var record = try operations.record(id: uuid)
            try requireCommandStopped(&record)
            if try hasExchanged(record) { return await finishCommitted(record) }
            if record.phase == .cancelling { return try cancelUncommitted(record) }
            guard [.prepared, .switching].contains(record.phase) else { throw SigningError.incompletePreparation }
            // A user explicitly resumes an already verified candidate. No
            // background restart repeats codesign or creates another full app.
            return try await commit(&record)
        }
        if let deletion = try history.deletions().first(where: { "history-cleanup:" + $0.id.uuidString == id }) {
            return try finishMaterialDeletion(deletion)
        }
        guard let (url, backup) = try history.selectedRecord(materialID: id), let cleanup = backup.cleanup else { throw SigningError.snapshotInvalid }
        let app = try Self.resolveAppURL(at: URL(fileURLWithPath: backup.originalPath))
        try finishBackupCleanup(backup, recordURL: url, app: app, applicationFingerprint: cleanup.applicationFingerprint)
        return .init(applicationURL: app, operationID: nil, committed: true, cleanupWarning: nil)
    }

    @discardableResult
    func cancelSignatureOperation(id: String) async throws -> SignatureOperationResult {
        try await prepareServices()
        let locks = try acquireLocks()
        defer { locks.forEach { $0.release() } }
        guard let uuid = operationID(id) else { throw SigningError.snapshotInvalid }
        let record = try operations.record(id: uuid)
        if record.phase == .abandoned { return try cancelUncommitted(record) }
        if try hasExchanged(record) { return await finishCommitted(record) }
        return try cancelUncommitted(record)
    }

    @discardableResult
    func deleteSignatureMaterial(id: String, moveToTrash: Bool = false) async throws -> SignatureOperationResult {
        if operationID(id) != nil {
            // Temporary operations use their existing cancellation/cleanup
            // protocol. Never turn a requested Trash action into actual deletion.
            guard !moveToTrash else { throw SigningError.temporaryMaterialCannotBeTrashed }
            return try await cancelSignatureOperation(id: id)
        }
        try await prepareServices()
        let locks = try acquireLocks()
        defer { locks.forEach { $0.release() } }
        if let deletion = try history.deletions().first(where: { "history-cleanup:" + $0.id.uuidString == id }) {
            guard deletion.moveToTrash == moveToTrash else { throw SigningError.deletionDispositionChanged }
            return try finishMaterialDeletion(deletion)
        }
        guard let material = try history.materials().first(where: { $0.id == id }), material.canDelete else { throw SigningError.snapshotInvalid }
        let record = try history.selectedRecord(materialID: id)
        let target = material.url
        let identity = try DataPathIdentity.capture(target)
        if let appURL = material.appURL, let app = try? Self.resolveAppURL(at: appURL),
           try DataPathIdentity.capture(app).matchesFilesystemObject(identity) { throw SigningError.applicationChanged }
        // Deletion is a separately explicit choice. A changing material ID or
        // a substituted object cannot inherit the user's selected item.
        guard (try history.materials().first(where: { $0.id == id })) != nil else { throw SigningError.applicationChanged }
        let deletion = SignatureMaterialDeletion(id: UUID(), targetPath: target.path,
            parentIdentity: try DataPathIdentity.capture(target.deletingLastPathComponent()), targetIdentity: identity,
            manifest: try SignatureRemovalManifest.capture(at: target), recordPath: record?.0.path,
            recordDigest: try record.map { try history.materialID(for: $0.0) }, moveToTrash: moveToTrash,
            recordParentIdentity: try record.map { try DataPathIdentity.capture($0.0.deletingLastPathComponent()) })
        try history.writeDeletion(deletion)
        return try finishMaterialDeletion(deletion)
    }

    private func finishMaterialDeletion(_ input: SignatureMaterialDeletion) throws -> SignatureOperationResult {
        var deletion = input
        let target = URL(fileURLWithPath: deletion.targetPath)
        let parent = target.deletingLastPathComponent()
        guard try DataPathIdentity.capture(parent).matchesFilesystemObject(deletion.parentIdentity) else { throw SigningError.snapshotInvalid }
        if try SignatureSnapshot.entryExists(target) {
            guard try DataPathIdentity.capture(target).matchesFilesystemObject(deletion.targetIdentity) else { throw SigningError.snapshotInvalid }
            try deletion.manifest.verify(at: target, allowingPartial: deletion.started && !deletion.moveToTrash)
            let partial = deletion.started
            deletion.started = true
            try history.writeDeletion(deletion)
            try requireWriterAdmission()
            if deletion.moveToTrash {
                try trashHistoricalMaterial(target)
            } else {
                try deletion.manifest.remove(at: target, allowingPartial: partial, unlockCopiedFlags: true)
            }
            guard try !SignatureSnapshot.entryExists(target) else { throw SigningError.snapshotInvalid }
        } else if !deletion.started { throw SigningError.snapshotInvalid }
        try synchronizeConfirmedDirectory(parent, identity: deletion.parentIdentity)
        if let path = deletion.recordPath, path != deletion.targetPath {
            let record = URL(fileURLWithPath: path)
            guard history.containsRecord(record) else { throw SigningError.snapshotInvalid }
            let recordParent = record.deletingLastPathComponent()
            if deletion.recordParentIdentity == nil {
                if recordParent.standardizedFileURL == parent.standardizedFileURL {
                    deletion.recordParentIdentity = deletion.parentIdentity
                } else {
                    // Older receipts can bind the still-existing selected
                    // metadata before removing it, never a missing replacement.
                    guard try SignatureSnapshot.entryExists(record), try history.materialID(for: record) == deletion.recordDigest else {
                        throw SigningError.snapshotInvalid
                    }
                    deletion.recordParentIdentity = try DataPathIdentity.capture(recordParent)
                }
                try history.writeDeletion(deletion)
            }
            guard let recordParentIdentity = deletion.recordParentIdentity,
                  try DataPathIdentity.capture(recordParent).matchesFilesystemObject(recordParentIdentity) else { throw SigningError.snapshotInvalid }
            if try SignatureSnapshot.entryExists(record) {
                guard try history.materialID(for: record) == deletion.recordDigest else { throw SigningError.snapshotInvalid }
                try requireWriterAdmission()
                try deleteBackupRecordFile(record)
            }
            try synchronizeConfirmedDirectory(recordParent, identity: recordParentIdentity)
        }
        guard try DataPathIdentity.capture(parent).matchesFilesystemObject(deletion.parentIdentity) else { throw SigningError.snapshotInvalid }
        try requireWriterAdmission()
        try history.removeDeletion(deletion)
        return .init(applicationURL: nil, operationID: deletion.id, committed: true,
                     cleanupWarning: deletion.moveToTrash ? "已移入废纸篓，仍占存储空间。".localized : nil)
    }

    private func operationID(_ value: String) -> UUID? {
        UUID(uuidString: value.hasPrefix("operation:") ? String(value.dropFirst("operation:".count)) : value)
    }
}
