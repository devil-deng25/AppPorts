import Combine
import Foundation

/// UI actions dispatch to their owning service. No extra transaction or copy
/// lifecycle lives here; every mutation is revalidated by that service.
@MainActor
final class CopyManagementModel: ObservableObject {
    struct Snapshot: Sendable {
        var dataGroups: [DataTransferGroup] = []
        var legacyCleanups: [ContainerCleanupRecord] = []
        var dataMaterials: [DataTransferMaterial] = []
        var appTransfers: [AppTransferRecord] = []
        var appTransferIssues: [AppTransferRecordIssue] = []
        var signatureMaterials: [SignatureMaterial] = []
        var readErrors: [String] = []

        var isEmpty: Bool {
            dataGroups.isEmpty && legacyCleanups.isEmpty && dataMaterials.isEmpty
                && appTransfers.isEmpty && appTransferIssues.isEmpty && signatureMaterials.isEmpty
        }
    }

    enum Action: Sendable {
        case resumeData(DataTransferRecord)
        case cancelData(DataTransferRecord, preserveMaterials: Bool)
        case cleanupData(DataTransferGroup)
        case cleanupLegacy(ContainerCleanupRecord)
        case removeLegacyCleanupRecord(ContainerCleanupRecord, confirmation: DataTransferMaterialService.RecordRemovalConfirmation)
        case recheckDataMaterial(UUID)
        case removeDataMaterialRecord(UUID, confirmation: DataTransferMaterialService.RecordRemovalConfirmation)
        case resumeApp(UUID)
        case cancelApp(UUID)
        case resumeSignature(String)
        case cancelSignature(String)
        case restoreSignature(SignatureMaterial)
        case deleteSignature(String, moveToTrash: Bool)
        case removeSignatureRecord(String, confirmation: CodeSigner.RecordRemovalConfirmation)
    }

    struct Dependencies: Sendable {
        let load: @Sendable () async -> Snapshot
        let execute: @Sendable (Action) async throws -> String?

        static let live = Dependencies(load: {
            await Task.detached(priority: .utility) {
                var snapshot = Snapshot()
                do {
                    let inspection = try ContainerMountStore.shared.recordsForInspection()
                    snapshot.dataGroups = DataTransferGroup.groups(from: inspection.transfers)
                    snapshot.legacyCleanups = inspection.cleanups
                    snapshot.dataMaterials = inspection.preservedMaterials
                    if let error = inspection.validationError { snapshot.readErrors.append(error.localizedDescription) }
                } catch { snapshot.readErrors.append(error.localizedDescription) }
                do {
                    let inspection = try AppMigrationService().pendingTransferInspection()
                    snapshot.appTransfers = inspection.records
                    snapshot.appTransferIssues = inspection.issues
                }
                catch { snapshot.readErrors.append(error.localizedDescription) }
                do { snapshot.signatureMaterials = try await CodeSigner().signatureMaterials() }
                catch { snapshot.readErrors.append(error.localizedDescription) }
                return snapshot
            }.value
        }, execute: { action in
            switch action {
            case .resumeApp(let id):
                let result = try await AppMigrationService().retryTransfer(operationID: id, progressHandler: nil)
                return result.pendingMessage
            case .cancelApp(let id):
                let result = try await AppMigrationService().cancelTransfer(operationID: id)
                return result.pendingMessage
            case .resumeSignature, .cancelSignature, .restoreSignature, .deleteSignature, .removeSignatureRecord:
                return try await performSignatureAction(action)
            default:
                return try await performDataAction(action)
            }
        })

        static func performSignatureAction(_ action: Action, signer: CodeSigner = CodeSigner()) async throws -> String? {
            switch action {
            case .resumeSignature(let id):
                return try await signer.resumeSignatureMaterial(id: id).cleanupWarning
            case .cancelSignature(let id):
                return try await signer.cancelSignatureMaterial(id: id).cleanupWarning
            case .restoreSignature(let material):
                guard let app = material.appURL, let bundleID = material.bundleIdentifier else {
                    throw CodeSigner.SigningError.applicationUnavailable(material.url)
                }
                return try await signer.restoreSignature(appURL: app, bundleIdentifier: bundleID,
                    historicalMaterialID: material.id).cleanupWarning
            case .deleteSignature(let id, let trash):
                let result = try await signer.deleteSignatureMaterial(id: id, moveToTrash: trash)
                return result.cleanupWarning ?? (trash ? "已移入废纸篓，仍占存储空间。".localized : nil)
            case .removeSignatureRecord(let id, let confirmation):
                switch try await signer.removeSignatureMaterialRecord(id: id, confirmation: confirmation) {
                case .recordRemoved:
                    return "仅移除了记录。文件和卷均未更改，此操作没有释放存储空间。".localized
                case .recordUnavailable:
                    return "所选记录已不存在或已改变；请查看刷新后的列表。未更改任何文件或卷。".localized
                }
            default:
                preconditionFailure("Only signature actions use the signature service")
            }
        }

        static func performDataAction(_ action: Action, store: ContainerMountStore = .shared,
                                      lock: OperationLock = OperationLock()) async throws -> String? {
            guard await lock.acquire(timeout: OperationLock.appWaitTimeout) else {
                throw DataOperationSafety.Failure.occupied("AppPorts")
            }
            defer { lock.release() }
            try Task.checkCancellation()
            switch action {
            case .resumeData(let transfer):
                if transfer.mode == .mount {
                    return try await ContainerVolumeMigrator(store: store).resumeVerifiedTransfer(operationID: transfer.operationID, progressHandler: nil)
                }
                return try await DataDirMover(store: store).resumeVerifiedTransfer(operationID: transfer.operationID, progressHandler: nil)
            case .cancelData(let transfer, let preserve):
                if transfer.mode == .mount {
                    try await ContainerVolumeMigrator(store: store).cancelPreparation(operationID: transfer.operationID, preserveUnclaimedMaterials: preserve)
                } else {
                    try await DataDirMover(store: store).cancelPreparation(operationID: transfer.operationID, preserveUnclaimedMaterials: preserve)
                }
                return preserve ? "本次尝试已结束，未确认的材料已保留并列出。".localized : nil
            case .cleanupData(let group):
                var failures: [String] = []
                for transfer in group.cleanupTransfers {
                    try Task.checkCancellation()
                    do {
                        if transfer.mode == .mount {
                            try await ContainerVolumeMigrator(store: store).cleanupRetainedTransfer(operationID: transfer.operationID)
                        } else {
                            try await DataDirMover(store: store).cleanupRetainedTransfer(operationID: transfer.operationID)
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        failures.append(error.localizedDescription)
                    }
                }
                if !failures.isEmpty {
                    throw NSError(domain: "AppPorts.CopyManagement", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "\n")])
                }
                return nil
            case .cleanupLegacy(let cleanup):
                let warning = ContainerVolumeMigrator.CleanupWarning(cleanup: cleanup, details: "")
                return await ContainerVolumeMigrator(store: store).retryCleanup(warning)?.message
            case .removeLegacyCleanupRecord(let cleanup, .keepAllFilesAndVolumes):
                try await ContainerVolumeMigrator(store: store).discardCleanupRecord(cleanup)
                return "仅移除了记录。文件和卷均未更改，此操作没有释放存储空间。".localized
            case .recheckDataMaterial(let id):
                switch try await DataTransferMaterialService(store: store).recheckPreservedMaterial(id: id) {
                case .listedPathsStillExist:
                    return "已保留的材料仍在所列位置。可在访达中处理，或仅移除这条记录。".localized
                case .absenceUnverified:
                    return "未找到所列材料；位置可能离线或已改变。记录已保留，可在确认自行处理后移除记录。".localized
                case .recordAlreadyRemoved:
                    return "这项操作已处理完成。".localized
                }
            case .removeDataMaterialRecord(let id, let confirmation):
                _ = try await DataTransferMaterialService(store: store).removePreservedMaterialRecord(id: id,
                    confirmation: confirmation)
                return "仅移除了记录。文件和卷均未更改，此操作没有释放存储空间。".localized
            default:
                preconditionFailure("Only data actions use the data operation lock")
            }
        }
    }

    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var isRefreshing = false
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?
    @Published var notice: String?
    private let dependencies: Dependencies
    private let operationState: AppOperationState
    private var refreshID = UUID()

    init(dependencies: Dependencies = .live, operationState: AppOperationState? = nil) {
        self.dependencies = dependencies
        self.operationState = operationState ?? .shared
    }

    func refresh() async {
        let id = UUID()
        refreshID = id
        isRefreshing = true
        let next = await dependencies.load()
        guard id == refreshID else { return }
        snapshot = next
        isRefreshing = false
    }

    @discardableResult
    func start(_ action: Action) -> Task<Void, Never>? {
        guard let token = operationState.begin() else { return nil }
        isWorking = true
        errorMessage = nil
        notice = nil
        let task = Task { @MainActor in
            defer {
                isWorking = false
                operationState.finish(token)
            }
            do { notice = try await dependencies.execute(action) }
            catch is CancellationError { notice = "操作已停止，可从当前记录继续。".localized }
            catch { errorMessage = error.localizedDescription }
            await refresh()
        }
        operationState.registerCancellation(for: token) { task.cancel() }
        return task
    }
}

extension AppTransferResult {
    var pendingMessage: String? {
        let messages = warnings + pendingTasks.map(\.message)
        var seen = Set<String>()
        let unique = messages.filter { !$0.isEmpty && seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique.joined(separator: "\n")
    }
}
