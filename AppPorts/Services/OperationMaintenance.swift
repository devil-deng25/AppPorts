import Foundation

/// Internal completion of the original user request. Calls coalesce and each
/// owning service retains its journal until the actual work has finished.
actor OperationMaintenance {
    static let shared = OperationMaintenance()
    private struct RunningMaintenance {
        let task: Task<[String], Never>
        let progress: DataTransferProgress
    }

    private var active: RunningMaintenance?
    private let perform: @Sendable () async -> [String]

    init(perform: (@Sendable () async -> [String])? = nil) {
        self.perform = perform ?? { await OperationMaintenance.performMaintenance() }
    }

    /// A foreground retry adopts the worker's reporter, including when it
    /// joins maintenance that already began in the background.
    func run(observeProgress: (@Sendable (DataTransferProgress) async -> Void)? = nil) async -> [String] {
        if let active {
            await observeProgress?(active.progress)
            return await active.task.value
        }
        let progress = DataTransferProgress()
        let perform = self.perform
        let task = Task.detached(priority: .utility) {
            await progress.track { _ in
                progress.begin(.recovering)
                return await perform()
            }
        }
        active = RunningMaintenance(task: task, progress: progress)
        defer { active = nil }
        await observeProgress?(progress)
        return await task.value
    }

    private static func performMaintenance() async -> [String] {
        var warnings = await finishDataOperations()
        let applications = AppMigrationService()
        do {
            let inventory = try applications.pendingTransferInspection()
            warnings += inventory.issues.map(\.message)
            for record in inventory.records {
                do {
                    let result = try await applications.retryTransfer(operationID: record.operationID)
                    if let message = result.pendingMessage { warnings.append(message) }
                } catch { warnings.append(record.appName + ": " + error.localizedDescription) }
            }
        } catch { warnings.append(error.localizedDescription) }
        // Signature work acquires its own locks, after data/app locks release.
        warnings += await CodeSigner().performAutomaticMaintenance()
        if !warnings.isEmpty {
            AppLogger.shared.logContext("操作自动收尾尚未完成", details: [("reason", warnings.joined(separator: "\n"))], level: "WARN")
        }
        return warnings
    }

    private static func finishDataOperations() async -> [String] {
        let lock = OperationLock()
        guard await lock.acquire(timeout: OperationLock.appWaitTimeout) else {
            return [lock.admissionFailureReason ?? "应用操作正在进行，请稍后重试。".localized]
        }
        defer { lock.release() }
        var warnings: [String] = []
        let store = ContainerMountStore.shared
        let migrator = ContainerVolumeMigrator(disk: DiskUtility(administratorRunner: nil))
        warnings += await migrator.performAutomaticMaintenance()
        let outcomes = await migrator.remountAvailableRecords()
        for outcome in outcomes {
            switch outcome.state {
            case .failed(let reason), .requiresIntervention(let reason): warnings.append(reason)
            case .unavailable: warnings.append(outcome.record.appName + ": " + "请连接保存数据的外部存储。".localized)
            default: break
            }
        }
        do {
            let transfers = try store.transfers()
            let parents = Set(transfers.filter { $0.rollbackCompletedAt == nil }.compactMap(\.priorOperationID))
            for transfer in transfers where transfer.mode == .symlink && !parents.contains(transfer.operationID) {
                do {
                    let warning = try await DataDirMover().resumeVerifiedTransfer(operationID: transfer.operationID, progressHandler: nil)
                    if let warning { warnings.append(warning) }
                } catch { warnings.append(transfer.appName + ": " + error.localizedDescription) }
            }
        } catch { warnings.append(error.localizedDescription) }
        return warnings
    }
}
