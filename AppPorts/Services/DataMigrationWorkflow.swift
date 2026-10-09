import Foundation

/// 已授权的签名属于数据迁移流程：备份完成后才迁移，重签完成后才向调用方返回成功。
enum DataMigrationWorkflow {
    enum Stage: Equatable, Sendable {
        case backingUpApplication
        case migratingData
        case resigningApplication
    }

    /// 隐藏的旧偏好不能在经典模式关闭后继续修改关联应用。
    /// 确认界面和执行流程共用同一策略；本次选择优先于自动开关。
    static func shouldResignAssociatedApp(
        classicModeActive: Bool,
        autoResignEnabled: Bool,
        explicitChoice: Bool?
    ) -> Bool {
        classicModeActive && (explicitChoice ?? autoResignEnabled)
    }

    /// 确认框对应的真实应用；批准不能沿着后来改变的本地入口传给另一应用。
    struct SigningTarget: Equatable, Sendable {
        let url: URL
        let isSandboxed: Bool

        init(url: URL, isSandboxed: Bool) {
            self.url = url.standardizedFileURL
            self.isSandboxed = isSandboxed
        }
    }

    static func signingTarget(at appURL: URL) throws -> SigningTarget {
        let realURL = try CodeSigner.resolveAppURL(at: appURL)
        return SigningTarget(url: realURL, isSandboxed: CodeSigner.isSandboxed(at: realURL))
    }

    enum Failure: LocalizedError {
        case signingFailed(Error)

        var errorDescription: String? {
            switch self {
            case .signingFailed(let error):
                return String(
                    format: "数据已迁移，但关联应用重签名失败：%@\n\n请在应用列表中重试重签名，或还原数据目录。".localized,
                    error.localizedDescription
                )
            }
        }
    }

    @discardableResult
    static func run(
        associatedAppURL: URL?,
        classicModeActive: Bool = false,
        autoResignEnabled: Bool = false,
        explicitSigningChoice: Bool? = nil,
        approvedSandboxedTarget: SigningTarget? = nil,
        inspectSigningTarget: (URL) async throws -> SigningTarget = { try signingTarget(at: $0) },
        validateBeforeMigration: () async throws -> Void = {},
        stageChanged: (Stage) async -> Void = { _ in },
        backupSignature: (URL) async throws -> Void,
        migrate: () async throws -> Void,
        resignApp: (URL, Bool) async throws -> Void,
        cleanupUnusedBackup: (URL) async throws -> Void = { _ in }
    ) async throws -> String? {
        let signingAppURL = shouldResignAssociatedApp(
            classicModeActive: classicModeActive,
            autoResignEnabled: autoResignEnabled,
            explicitChoice: explicitSigningChoice
        ) ? associatedAppURL : nil
        var backupTargetURL: URL?
        do {
            let target: SigningTarget?
            if let signingAppURL {
                let inspected = try await inspectSigningTarget(signingAppURL)
                if let approvedSandboxedTarget, approvedSandboxedTarget != inspected {
                    throw CodeSigner.SigningError.applicationChanged
                }
                // 全局经典模式只是功能开关，不能替代这个真实应用的逐次批准。
                if inspected.isSandboxed,
                   !(classicModeActive && approvedSandboxedTarget == inspected) {
                    throw CodeSigner.SigningError.sandboxedApplication(inspected.url)
                }
                target = inspected
                // Remember the actual app before backup starts: even a failed
                // backup may have left an artifact, and the portal may retarget.
                backupTargetURL = inspected.url
                await stageChanged(.backingUpApplication)
                try await backupSignature(inspected.url)
                // 备份可能耗时很长；入口或沙盒状态改变时，先停下，不搬动任何数据。
                guard try await inspectSigningTarget(signingAppURL) == inspected else {
                    throw CodeSigner.SigningError.applicationChanged
                }
            } else {
                target = nil
            }

            try await validateBeforeMigration()
            await stageChanged(.migratingData)
            try await migrate()

            if let signingAppURL, let target {
                do {
                    guard try await inspectSigningTarget(signingAppURL) == target else {
                        throw CodeSigner.SigningError.applicationChanged
                    }
                    let sandboxedAppApproved = target.isSandboxed
                        && classicModeActive && approvedSandboxedTarget == target
                    await stageChanged(.resigningApplication)
                    try await resignApp(target.url, sandboxedAppApproved)
                } catch {
                    // 数据已经成功迁移；不要误报为迁移失败或自动再次搬运数据。
                    throw Failure.signingFailed(error)
                }
            }
        } catch let workflowError {
            if let backupTargetURL {
                do {
                    try await cleanupUnusedBackup(backupTargetURL)
                } catch let cleanupError {
                    AppLogger.shared.logError("数据迁移失败后清理未用应用备份失败", error: cleanupError,
                        context: [("operation_error", workflowError.localizedDescription)],
                        relatedURLs: [("application", backupTargetURL)])
                }
            }
            throw workflowError
        }

        // Signing must finish before the cleanup policy decides whether this
        // backup is still needed. Without signing, also check unused history.
        guard let cleanupTargetURL = backupTargetURL ?? associatedAppURL else { return nil }
        do {
            try await cleanupUnusedBackup(cleanupTargetURL)
            return nil
        } catch {
            AppLogger.shared.logError("数据迁移完成后清理未用应用备份失败", error: error,
                relatedURLs: [("application", cleanupTargetURL)])
            return error.localizedDescription
        }
    }
}
