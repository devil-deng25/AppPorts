//
//  AppCompanionDataMigration.swift
//  AppPorts
//
//  应用本体迁移成功后，连同它的关联数据目录一起搬到同一块外部存储。
//

import Foundation

/// 「随应用一起迁移」的数据目录。
///
/// 应用本体与数据原本是两条独立流程：搬完 `/Applications` 里的 App，数据仍留在
/// `~/Library`，用户必须再去「数据目录」页逐个勾选迁移，否则外置盘上的应用只有程序、
/// 没有数据。这里把可以用符号链接迁移的目录并入同一次任务，在应用搬家成功后立即搬运。
///
/// 只覆盖符号链接迁移能安全处理、且搬走确有收益的类型：
/// - `Application Support` / `Caches` / `WebKit` / `HTTPStorages`：应用真正读写的数据；
/// - 沙盒容器（`Containers`、`Group Containers`）必须走挂载迁移，这里跳过并回报；
/// - `Preferences` 有 cfprefsd 的全进程缓存，改符号链接可能被系统当场重写；
///   `Logs`、`Saved State`、`Application Scripts` 体量小或受 TCC 保护，搬走没有收益，
///   都留给「数据目录」页由用户自己决定。
///
/// 调用约定：本类型的两个入口都必须在持有 `OperationLock` 的任务里调用
/// （`MigrationTaskCenter` 提交的任务天然满足），内部不再重复加锁。
enum AppCompanionDataMigration {
    /// 允许随应用一起迁移的数据目录类型。
    static let companionTypes: Set<DataDirType> = [.applicationSupport, .caches, .webKit, .httpStorages]

    /// 迁移前的规划结果。应用搬家后再扫描会读到不同的入口状态，所以先算好再动手。
    struct Plan: Sendable {
        var candidates: [DataDirItem] = []
        /// 需要挂载迁移、本次不做但应当告知用户的目录名。
        var mountRequired: [String] = []

        var isEmpty: Bool { candidates.isEmpty }
    }

    struct Outcome: Sendable {
        var migrated: [String] = []
        var failed: [(name: String, message: String)] = []
        var mountRequired: [String] = []
        var cancelled = false

        /// 只有需要用户知道的情况才返回文字：任务会把非空消息标成「需要注意」。
        var message: String? {
            if !failed.isEmpty {
                let detail = failed.prefix(3)
                    .map { String(format: "%@：%@", $0.name, $0.message) }
                    .joined(separator: "；")
                return String(format: "应用已迁移，但有 %d 个关联数据目录未迁移（%@）。可在「数据目录」页重试。".localized,
                              failed.count, detail)
            }
            if migrated.isEmpty, !mountRequired.isEmpty {
                return String(format: "应用已迁移；%@ 属于沙盒容器，需要挂载迁移，请在「数据目录」页单独处理。".localized,
                              mountRequired.prefix(3).joined(separator: "、"))
            }
            return nil
        }
    }

    // MARK: - 规划

    /// 找出这个应用当前还能一起搬走的数据目录。
    static func plan(for app: AppItem, externalRoot: URL) async -> Plan {
        guard !app.isFolder else { return Plan() }
        let items = await DataDirScanner().scanLibraryDirs(for: app, externalRootURL: externalRoot)
        var plan = Plan()
        for item in items {
            // 已链接/已挂载/待完成等状态都属于「不用再动」，只有纯本地目录才参与。
            guard item.status == DataDirStatus.local else { continue }
            if item.requiresMountMigration || DataDirStatus.mountStatuses.contains(item.status) {
                plan.mountRequired.append(item.name)
                continue
            }
            guard companionTypes.contains(item.type), item.isMigratable else { continue }
            // 微信多开、容器拆分有自己的流程，不在这里抢。
            guard item.weChatSplitMembers.isEmpty else { continue }
            guard item.pathPolicy?.canMigrate != false else { continue }
            // 空目录搬过去只会多一个符号链接。
            guard !item.isEmptyLocalDirectory else { continue }
            plan.candidates.append(item)
        }
        AppLogger.shared.logContext(
            "随应用迁移数据目录：规划完成",
            details: [
                ("app_name", app.displayName),
                ("external_root", externalRoot.path),
                ("candidate_count", String(plan.candidates.count)),
                ("candidates", plan.candidates.map(\.name).joined(separator: ", ")),
                ("mount_required", plan.mountRequired.joined(separator: ", "))
            ]
        )
        return plan
    }

    // MARK: - 执行

    /// 逐个搬运，单个目录失败不影响其余目录，也不影响已经完成的应用迁移。
    static func migrate(_ plan: Plan, externalRoot: URL,
                        progressHandler: FileCopier.ProgressHandler?) async -> Outcome {
        var outcome = Outcome(mountRequired: plan.mountRequired)
        guard !plan.candidates.isEmpty else { return outcome }
        let mover = DataDirMover()
        for item in plan.candidates {
            if Task.isCancelled {
                outcome.cancelled = true
                break
            }
            do {
                _ = try await mover.migrateAndComplete(item: item, to: externalRoot,
                                                       progressHandler: progressHandler)
                outcome.migrated.append(item.name)
            } catch is CancellationError {
                outcome.cancelled = true
                break
            } catch {
                outcome.failed.append((item.name, error.localizedDescription))
                AppLogger.shared.logError(
                    "随应用迁移数据目录失败",
                    error: error,
                    context: [
                        ("app_name", item.associatedAppName ?? ""),
                        ("item_name", item.name),
                        ("data_dir_type", item.type.rawValue)
                    ],
                    relatedURLs: [("path", item.path)]
                )
            }
        }
        AppLogger.shared.logContext(
            "随应用迁移数据目录：执行完成",
            details: [
                ("migrated", outcome.migrated.joined(separator: ", ")),
                ("failed_count", String(outcome.failed.count)),
                ("cancelled", outcome.cancelled ? "true" : "false")
            ]
        )
        return outcome
    }
}
