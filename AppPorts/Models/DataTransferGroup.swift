import Foundation

/// Presentation of one directory's recorded migration chain. Completed history
/// must not make an earlier external copy look like the currently active data.
struct DataTransferGroup: Equatable, Identifiable, Sendable {
    enum State: Equatable, Sendable { case migrated, restored, needsAttention }
    enum Storage: Equatable, Sendable { case local, external }

    struct RetainedCopy: Equatable, Identifiable, Sendable {
        let transfer: DataTransferRecord
        let storage: Storage
        let path: String?
        let volumeUUID: String?

        var id: UUID { transfer.operationID }
        var title: String {
            let action = transfer.direction == .migrate ? "迁移前副本".localized : "还原前副本".localized
            let location = storage == .local ? "本地".localized : "外部存储".localized
            return action + " · " + location
        }
    }

    /// Parents precede children even when a clock change reverses createdAt.
    let transfers: [DataTransferRecord]
    let currentTransfer: DataTransferRecord
    private let isLinear: Bool

    var id: UUID { currentTransfer.operationID }
    var originalPath: String { currentTransfer.originalPath }
    var activePath: String { currentTransfer.activePath }
    var displayName: String {
        currentTransfer.appName + " · " + URL(fileURLWithPath: originalPath).lastPathComponent
    }

    var state: State {
        guard isLinear, transfers.allSatisfy(Self.isCompleted) else { return .needsAttention }
        return currentTransfer.direction == .restore ? .restored : .migrated
    }

    var statusTitle: String {
        switch state {
        case .migrated: return "已迁移到外部存储".localized
        case .restored: return "已还原到本地".localized
        case .needsAttention: return "需要检查".localized
        }
    }

    var menuTitle: String { displayName + " · " + statusTitle }

    var retainedCopies: [RetainedCopy] {
        transfers.filter { Self.isCompleted($0) && $0.retainedCopyRemovedAt == nil }.compactMap { transfer in
            if transfer.mode == .mount, transfer.direction == .restore,
               let uuid = transfer.sourceIdentity.volumeUUID {
                // The recorded private mount point is no longer mounted after
                // restoration. Identify the retained volume, not an empty path.
                return RetainedCopy(transfer: transfer, storage: .external, path: nil, volumeUUID: uuid)
            }
            guard let path = transfer.backupPath else { return nil }
            let isLocal = transfer.direction == .migrate
                && Self.standardPath(URL(fileURLWithPath: path).deletingLastPathComponent().path)
                    == Self.standardPath(URL(fileURLWithPath: transfer.originalPath).deletingLastPathComponent().path)
            return RetainedCopy(transfer: transfer, storage: isLocal ? .local : .external, path: path, volumeUUID: nil)
        }
    }

    var canCleanup: Bool {
        state != .needsAttention && transfers.allSatisfy { $0.baseline != nil || $0.retainedCopyRemovedAt != nil }
            && !retainedCopies.isEmpty
            && retainedCopies.count == transfers.filter({ $0.retainedCopyRemovedAt == nil }).count
    }

    /// One cleanup attempt covers these recorded copies in dependency order.
    /// The service still rechecks every record and filesystem object.
    var cleanupTransfers: [DataTransferRecord] { canCleanup ? transfers.filter { $0.retainedCopyRemovedAt == nil } : [] }

    /// Cancellation is available for all four uncommitted preparations. The
    /// service decides whether a partial artifact is owned and safe to remove.
    var unlockTransfer: DataTransferRecord? {
        guard isLinear, currentTransfer.isPreparationRecoverable,
              transfers.filter({ $0.operationID != currentTransfer.operationID }).allSatisfy(Self.isCompleted) else { return nil }
        return currentTransfer
    }

    var resumeTransfer: DataTransferRecord? {
        guard isLinear else { return nil }
        let pending = transfers.filter { !Self.isCompleted($0) }
        guard pending.count == 1, let transfer = pending.first,
              transfer.isVerifiedSwitchRecoverable || transfer.isPreparationRecoverable else { return nil }
        if transfer.operationID == currentTransfer.operationID { return transfer }
        // Historical builds permitted a restore after the migration's final
        // save failed. Expose its checked bookkeeping continuation as well.
        if currentTransfer.mode == .symlink, currentTransfer.direction == .restore, Self.isCompleted(currentTransfer),
           transfer.direction == .migrate, transfer.backupIdentity != nil { return transfer }
        return nil
    }

    init(transfer: DataTransferRecord) {
        self.init(transfers: [transfer])
    }

    private init(transfers: [DataTransferRecord]) {
        let records = Dictionary(uniqueKeysWithValues: transfers.map { ($0.operationID, $0) })
        var visited = Set<UUID>()
        var ordered: [DataTransferRecord] = []
        func append(_ record: DataTransferRecord) {
            guard visited.insert(record.operationID).inserted else { return }
            if let priorID = record.priorOperationID, let prior = records[priorID] { append(prior) }
            ordered.append(record)
        }
        for record in transfers.sorted(by: Self.createdBefore) { append(record) }
        let parents = Set(transfers.compactMap(\.priorOperationID))
        let terminals = ordered.filter { !parents.contains($0.operationID) }
        self.transfers = ordered
        self.currentTransfer = terminals.last ?? ordered[ordered.count - 1]
        self.isLinear = terminals.count == 1
            && transfers.filter { $0.priorOperationID.flatMap { records[$0] } == nil }.count == 1
    }

    /// A common name/path alone never merges independent or conflicting work.
    /// Missing cleaned ancestors are allowed; each remaining chain still shows.
    static func groups(from transfers: [DataTransferRecord]) -> [DataTransferGroup] {
        let transfers = transfers.filter { $0.rollbackCompletedAt == nil }
        let records = Dictionary(uniqueKeysWithValues: transfers.map { ($0.operationID, $0) })
        var neighbors: [UUID: Set<UUID>] = [:]
        for transfer in transfers {
            guard let priorID = transfer.priorOperationID, let prior = records[priorID],
                  standardPath(prior.originalPath) == standardPath(transfer.originalPath) else { continue }
            neighbors[transfer.operationID, default: []].insert(priorID)
            neighbors[priorID, default: []].insert(transfer.operationID)
        }
        var remaining = Set(records.keys)
        var result: [DataTransferGroup] = []
        for transfer in transfers.sorted(by: createdBefore) where remaining.contains(transfer.operationID) {
            var pending = [transfer.operationID]
            var component: [DataTransferRecord] = []
            while let id = pending.popLast() {
                guard remaining.remove(id) != nil, let record = records[id] else { continue }
                component.append(record)
                pending.append(contentsOf: neighbors[id] ?? [])
            }
            result.append(DataTransferGroup(transfers: component))
        }
        return result.sorted { createdBefore($1.currentTransfer, $0.currentTransfer) }
    }

    private static func isCompleted(_ transfer: DataTransferRecord) -> Bool {
        transfer.isDataSwitchComplete
    }

    private static func createdBefore(_ lhs: DataTransferRecord, _ rhs: DataTransferRecord) -> Bool {
        lhs.createdAt == rhs.createdAt ? lhs.operationID.uuidString < rhs.operationID.uuidString : lhs.createdAt < rhs.createdAt
    }

    private static func standardPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
