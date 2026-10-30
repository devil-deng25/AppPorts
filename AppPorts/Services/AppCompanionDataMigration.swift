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
        /// 目录内部已有子孙项被单独迁移，父目录不能整体搬运（详见 `containsMigratedDescendant`）。
        /// 这类项不是失败：数据已经在外部存储上，只是父目录本身没有可搬的剩余内容。
        var blockedByMigratedDescendant: [String] = []

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
    static func plan(for app: AppItem, externalRoot: URL,
                     store: ContainerMountStore = .shared) async -> Plan {
        guard !app.isFolder else { return Plan() }
        let items = await DataDirScanner().scanLibraryDirs(for: app, externalRootURL: externalRoot)
        let migratedPaths = migratedOriginalPaths(store: store)
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
            // 目录里已有子孙项单独迁移过：父目录在外部存储里的规范目标，正是那个子项
            // 数据的容器。整体搬过去会把「指向外置的子链接」再复制进同一位置，形成自指，
            // 因此只能跳过——数据本来就已经在外部存储上了。
            guard !containsMigratedDescendant(of: item.path, among: migratedPaths) else {
                plan.blockedByMigratedDescendant.append(item.name)
                continue
            }
            plan.candidates.append(item)
        }
        AppLogger.shared.logContext(
            "随应用迁移数据目录：规划完成",
            details: [
                ("app_name", app.displayName),
                ("external_root", externalRoot.path),
                ("candidate_count", String(plan.candidates.count)),
                ("candidates", plan.candidates.map(\.name).joined(separator: ", ")),
                ("mount_required", plan.mountRequired.joined(separator: ", ")),
                ("blocked_by_migrated_children", plan.blockedByMigratedDescendant.joined(separator: ", "))
            ]
        )
        return plan
    }

    /// 已被 AppPorts 接管、搬到外部存储的原始路径：受管链接 + 挂载迁移点。
    static func migratedOriginalPaths(store: ContainerMountStore = .shared) -> [String] {
        var paths: [String] = []
        if let links = try? store.managedLinks() { paths += links.map(\.originalPath) }
        if let records = try? store.recordsStrict() { paths += records.map(\.mountPointPath) }
        return paths
    }

    /// 该目录下是否有子孙项已被单独迁移。用路径前缀判定，边界必须落在 `/` 上，
    /// 否则 `com.foo` 会把 `com.foobar` 也算成自己的子孙。
    static func containsMigratedDescendant(of directory: URL, among migratedPaths: [String]) -> Bool {
        let path = directory.standardizedFileURL.path
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return migratedPaths.contains { $0.hasPrefix(prefix) }
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
            // 目标路径必须和「数据目录」页同一个公式（`<外部根>/<Library 相对路径>`）。
            // 只把外部根交给搬运器、由它拼「根 + 目录名」，会让同名但不同类的目录
            // （Caches 与 HTTPStorages 下都叫 com.x）抢同一个目标，第二个直接失败；
            // 写出的还是非规范路径，落地即「待规范」。
            let destination = item.canonicalExternalDestination(under: externalRoot)
            do {
                _ = try await mover.migrateAndComplete(item: item, to: destination.deletingLastPathComponent(),
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
                        ("data_dir_type", item.type.rawValue),
                        ("destination", destination.path)
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
