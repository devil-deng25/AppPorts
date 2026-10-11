import Foundation

/// Restoring an official sandbox identity must not strand data behind a
/// classic link. The verified original supplies the shared-group identifiers.
enum SignatureRecoveryDependencyCheck {
    struct Inspection: Sendable {
        let linkedItems: [DataDirItem]
        let readIssues: [DataDirReadIssue]
        var isConfirmedClear: Bool { linkedItems.isEmpty && readIssues.isEmpty }
    }

    struct Failure: LocalizedError {
        let paths: [String]
        let unreadable: Bool
        var errorDescription: String? {
            let message = unreadable
                ? "无法确认相关容器的数据位置，请先重新检查：".localized
                : "请先还原以下经典模式容器链接，再恢复官方应用：".localized
            return message + "\n" + paths.joined(separator: "\n")
        }
    }

    static func requireSafeRestore(_ requirements: SignatureRecoveryRequirements) async throws {
        guard requirements.isSandboxed else { return }
        try Task.checkCancellation()
        let result = await inspect(bundleIdentifier: requirements.bundleIdentifier,
                                   applicationGroups: requirements.applicationGroups)
        if !result.readIssues.isEmpty {
            throw Failure(paths: result.readIssues.map { $0.url.path }, unreadable: true)
        }
        if !result.linkedItems.isEmpty {
            throw Failure(paths: result.linkedItems.map { $0.path.path }, unreadable: false)
        }
        try Task.checkCancellation()
    }

    static func inspect(bundleIdentifier: String, applicationGroups: [String],
                        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                        store: ContainerMountStore = .shared) async -> Inspection {
        let scan = await DataDirScanner(homeDir: homeDirectory, mountStore: store)
            .scanSignatureDependencies(bundleIdentifier: bundleIdentifier, applicationGroups: applicationGroups)
        let roots = [homeDirectory.appendingPathComponent("Library/Containers/" + bundleIdentifier)]
            + applicationGroups.map { homeDirectory.appendingPathComponent("Library/Group Containers/" + $0) }
        let allowedRoots = roots.map { $0.standardizedFileURL.path }
        let linked = scan.items.filter { item in
            guard !item.isUserDirectoryLink, let target = item.linkedDestination else { return false }
            let path = target.standardizedFileURL.resolvingSymlinksInPath().path
            // A link inside an entitled container remains within the same
            // sandbox scope. A mounted container preserves that original path.
            return !allowedRoots.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        var issues = scan.readIssues
        for item in scan.items where item.hasManagedLinkRecord && item.linkedDestination == nil {
            issues.append(DataDirReadIssue(url: item.path,
                error: ContainerMountStore.StoreError.conflict("Recorded container link could not be confirmed")))
        }
        return Inspection(linkedItems: linked, readIssues: issues)
    }
}
