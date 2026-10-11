import Foundation

/// One application location change. A committed transfer can still own cleanup
/// work; that work never turns the location change back into a failed migration.
struct AppTransferRecord: Codable, Identifiable, Sendable {
    enum Direction: String, Codable, Sendable { case migrate, restore }
    enum Phase: String, Codable, Sendable { case preparing, copying, verified, switching, committed, cancelled }

    var id: UUID { operationID }
    let operationID: UUID
    let appName: String
    let direction: Direction
    let usesFolderOperation: Bool
    let sourcePath: String
    let destinationPath: String
    let sourceIdentity: DataPathIdentity
    let sourceParentIdentity: DataPathIdentity
    let destinationParentIdentity: DataPathIdentity
    let createdAt: Date
    let stagePath: String
    let portalStagePath: String?
    let portalKind: String?
    let protectDestination: Bool
    var applicationPaths: [String] = []
    var signatureChecks: [String: Bool] = [:]
    var signatureRelocations: [AppTransferSignatureRelocation] = []
    /// Only retained while this operation still owns work. A later verified
    /// transfer replaces this receipt; completed transfers keep no history.
    var successorActivation: AppTransferActivation?
    /// Captured before copying the active source. Clear only after the new
    /// activation is durably recorded in every still-pending predecessor.
    var predecessorActivations: [AppTransferPredecessor]?
    var stageIdentity: DataPathIdentity?
    var candidateIdentity: DataPathIdentity?
    var portalStageIdentity: DataPathIdentity?
    var portalIdentity: DataPathIdentity?
    var existingDestinationIdentity: DataPathIdentity?
    /// Captured from the original protection records and persisted before any
    /// source or existing-target flags change. Nil is the older v3 schema.
    var protectionRecovery: AppTransferProtectionRecovery?
    var sourceProtectionSuspended = false
    var hasSourceBaseline = false
    var hasCandidateBaseline = false
    var hasExistingDestinationBaseline = false
    var phase: Phase = .preparing
    var switchIntentRecorded = false
    var committedAt: Date?
    var signatureFactsCommitted = false
    var destinationProtected = false
    var dockSynchronized = false
    var stagingCleanupComplete = false
    var cleanupItems: [AppTransferCleanupItem] = []
    var legacyPortals: [AppTransferLegacyPortal] = []
    var unclaimedPaths: [String] = []
    var recoverableReason: String?

    var isSwitchComplete: Bool { committedAt != nil }
    var canCancel: Bool { !isSwitchComplete && phase != .cancelled }
    var activeDestinationPath: String { successorActivation?.path ?? destinationPath }
    var activation: AppTransferActivation? {
        if let successorActivation { return successorActivation }
        guard let candidateIdentity else { return nil }
        return .init(operationID: operationID, path: destinationPath, identity: candidateIdentity,
                     parentIdentity: destinationParentIdentity)
    }
    var candidateURL: URL { URL(fileURLWithPath: stagePath).appendingPathComponent(URL(fileURLWithPath: destinationPath).lastPathComponent) }
    var stagedPortalURL: URL? {
        portalStagePath.map { URL(fileURLWithPath: $0).appendingPathComponent(URL(fileURLWithPath: sourcePath).lastPathComponent) }
    }
    var pendingTasks: [AppTransferPendingTask] {
        var result: [AppTransferPendingTask] = []
        if phase == .cancelled {
            return unclaimedPaths.map { .init(kind: .unclaimedArtifact, path: $0,
                message: "暂存对象归属无法确认，已保留；此尝试已结束。".localized) }
        }
        if !isSwitchComplete {
            result.append(.init(kind: .prepare, path: sourcePath,
                message: recoverableReason ?? "应用转移尚未切换，可以继续或取消。".localized))
            return result
        }
        if phase != .committed || predecessorActivations?.isEmpty == false {
            result.append(.init(kind: .recordCommit, path: activeDestinationPath, message: "应用位置已切换，完成记录待写入。".localized))
        }
        if !signatureFactsCommitted {
            result.append(.init(kind: .signatureFacts, path: activeDestinationPath, message: "应用签名状态关联待更新。".localized))
        }
        if protectDestination && !destinationProtected && successorActivation == nil {
            result.append(.init(kind: .updateProtection, path: destinationPath, message: "本次选择的应用更新保护待完成。".localized))
        }
        if !dockSynchronized {
            result.append(.init(kind: .dock, path: activeDestinationPath, message: "Dock 入口待更新。".localized))
        }
        for item in cleanupItems where !item.completed {
            result.append(.init(kind: .oldCopy, path: item.path,
                message: item.lastError ?? "应用位置已切换，旧副本待清理。".localized))
        }
        for portal in legacyPortals where !portal.retired || !portal.dockSynchronized {
            result.append(.init(kind: .portal, path: portal.path,
                message: portal.lastError ?? "旧应用入口待清理或更新。".localized))
        }
        for path in unclaimedPaths {
            result.append(.init(kind: .unclaimedArtifact, path: path, message: "暂存对象归属无法确认，已保留。".localized))
        }
        if !stagingCleanupComplete {
            result.append(.init(kind: .staging, path: stagePath, message: "应用暂存目录待清理。".localized))
        }
        return result
    }
}

struct AppTransferActivation: Codable, Equatable, Sendable {
    let operationID: UUID
    let path: String
    let identity: DataPathIdentity
    let parentIdentity: DataPathIdentity
}

struct AppTransferPredecessor: Codable, Sendable {
    let operationID: UUID
    /// The predecessor's exact receipt at admission, before the source is
    /// verified and copied. A later change to that receipt cannot be overwritten.
    let activation: AppTransferActivation
}

struct AppTransferProtectionRecovery: Codable, Equatable, Sendable {
    let source: AppUpdateProtectionRelocation?
    let existingDestination: AppUpdateProtectionRelocation?
}

struct AppTransferSignatureRelocation: Codable, Sendable {
    let relativePath: String
    let relocation: SignatureFactRelocation
}

struct AppTransferCleanupItem: Codable, Identifiable, Sendable {
    enum Role: String, Codable, Sendable { case source, replacedDestination, originalPortal }
    let id: UUID
    let role: Role
    let path: String
    let originalPath: String
    let identity: DataPathIdentity
    let parentIdentity: DataPathIdentity
    let baselineName: String
    var deletionStarted = false
    var completed = false
    var lastError: String?
}

struct AppTransferLegacyPortal: Codable, Sendable {
    let path: String
    let externalPath: String
    let identity: DataPathIdentity
    let parentIdentity: DataPathIdentity
    let baselineName: String
    let baseline: AppTransferBaseline
    let removalID: UUID
    var deletionStarted = false
    var retired = false
    var dockSynchronized = false
    var lastError: String?
}

struct AppTransferPendingTask: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case prepare, recordCommit, signatureFacts, updateProtection, dock, oldCopy, portal, staging, unclaimedArtifact
    }
    var id: String { kind.rawValue + ":" + (path ?? "") }
    let kind: Kind
    let path: String?
    let message: String
}

struct AppTransferResult: Sendable {
    let operationID: UUID
    let direction: AppTransferRecord.Direction
    let destinationURL: URL
    let isSwitchComplete: Bool
    let pendingTasks: [AppTransferPendingTask]
    let warnings: [String]
    let retiredLocalPortalURLs: [URL]
    let externalSourceRemains: Bool

    var isComplete: Bool { isSwitchComplete && pendingTasks.isEmpty }
}

/// A root link has no traversable tree. Keep its no-follow identity and target
/// separately; app/portal directories use the existing verified tree manifest.
struct AppTransferBaseline: Codable, Sendable {
    let tree: TreeCopySnapshot?
    let linkTarget: String?
    let linkIdentity: DataPathIdentity?
    var volumeUUID: String? = nil
}
