import XCTest
@testable import AppPorts

/// 随应用迁移的规划边界。
///
/// 回归点：父目录在外部存储里的规范目标，正是它「已单独迁移的子项」的数据容器。
/// 曾经这种父目录会被当成候选，搬运时必然撞上 `destinationExists`
/// （「目标路径已存在真实目录，无法覆盖」），而提示又让用户去「数据目录」页重试 ——
/// 那里用同一个公式算目标，同样失败。数据其实早已在外部存储上。
final class AppCompanionDataMigrationTests: XCTestCase {
    private let fileManager = FileManager.default
    private var originalLogEnabledValue: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalLogEnabledValue = UserDefaults.standard.object(forKey: "LogEnabled")
        UserDefaults.standard.set(false, forKey: "LogEnabled")
    }

    override func tearDownWithError() throws {
        if let originalLogEnabledValue {
            UserDefaults.standard.set(originalLogEnabledValue, forKey: "LogEnabled")
        } else {
            UserDefaults.standard.removeObject(forKey: "LogEnabled")
        }
        try super.tearDownWithError()
    }

    // MARK: - 纯判定

    func testDescendantDetectionRespectsPathBoundaries() throws {
        let parent = URL(fileURLWithPath: "/Users/t/Library/Application Support/com.foo")
        XCTAssertTrue(AppCompanionDataMigration.containsMigratedDescendant(
            of: parent, among: ["/Users/t/Library/Application Support/com.foo/com.child"]))
        XCTAssertTrue(AppCompanionDataMigration.containsMigratedDescendant(
            of: parent, among: ["/Users/t/Library/Application Support/com.foo/deep/nested/leaf"]))
        XCTAssertFalse(AppCompanionDataMigration.containsMigratedDescendant(
            of: parent, among: ["/Users/t/Library/Application Support/com.foobar/child"]),
            "com.foo 不能把 com.foobar 的子项算成自己的子孙")
        XCTAssertFalse(AppCompanionDataMigration.containsMigratedDescendant(
            of: parent, among: ["/Users/t/Library/Application Support/com.foo"]),
            "路径本身不是自己的子孙")
        XCTAssertFalse(AppCompanionDataMigration.containsMigratedDescendant(of: parent, among: []))
    }

    func testDescendantDetectionAcceptsTrailingSlashDirectory() {
        let parent = URL(fileURLWithPath: "/Users/t/Library/Application Support/com.foo/")
        XCTAssertTrue(AppCompanionDataMigration.containsMigratedDescendant(
            of: parent, among: ["/Users/t/Library/Application Support/com.foo/com.child"]))
    }

    // MARK: - 规划

    /// 父目录下已有子项被单独迁移 → 不进候选，也不计入失败，而是记为「跳过」。
    func testPlanSkipsParentWhoseChildIsAlreadyMigrated() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let appURL = try createAppBundle(named: "Parent.app", bundleID: "com.example.parent", in: workspace.appsURL)
        let parentURL = workspace.homeURL.appendingPathComponent("Library/Application Support/com.example.parent")
        let childURL = parentURL.appendingPathComponent("com.example.child")
        try createDirectoryWithPayload(at: childURL)

        // 子项已迁到外部，登记为受管链接。
        let externalChildURL = workspace.externalRootURL
            .appendingPathComponent("Application Support/com.example.parent/com.example.child")
        try createDirectoryWithPayload(at: externalChildURL)
        let store = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("mounts.plist"))
        try store.upsertManagedLink(ManagedDataLinkRecord(
            operationID: UUID(),
            originalPath: childURL.standardizedFileURL.path,
            destinationPath: externalChildURL.standardizedFileURL.path,
            destinationIdentity: try DataPathIdentity.capture(externalChildURL),
            appName: "Parent",
            bundleIdentifier: "com.example.parent",
            dataDirType: DataDirType.applicationSupport.rawValue
        ))

        let plan = await AppCompanionDataMigration.plan(
            for: AppItem(name: "Parent.app", path: appURL, status: AppStatus.local),
            externalRoot: workspace.externalRootURL,
            store: store
        )

        XCTAssertFalse(plan.candidates.contains { $0.path.standardizedFileURL == parentURL.standardizedFileURL },
                       "子项已迁移的父目录不能整体搬运")
        XCTAssertTrue(plan.blockedByMigratedDescendant.contains("com.example.parent"))
        XCTAssertTrue(plan.blockedByMigratedDescendant.count == 1)
    }

    /// 没有已迁移子孙的普通目录照常进候选，避免过滤把正常情况一起吞掉。
    func testPlanKeepsDirectoryWithoutMigratedDescendant() async throws {
        let workspace = try makeWorkspace()
        defer { cleanupWorkspace(workspace.rootURL) }

        let appURL = try createAppBundle(named: "Plain.app", bundleID: "com.example.plain", in: workspace.appsURL)
        let dataURL = workspace.homeURL.appendingPathComponent("Library/Application Support/com.example.plain")
        try createDirectoryWithPayload(at: dataURL)
        let store = ContainerMountStore(fileURL: workspace.rootURL.appendingPathComponent("mounts.plist"))

        let plan = await AppCompanionDataMigration.plan(
            for: AppItem(name: "Plain.app", path: appURL, status: AppStatus.local),
            externalRoot: workspace.externalRootURL,
            store: store
        )

        XCTAssertTrue(plan.candidates.contains { $0.path.standardizedFileURL == dataURL.standardizedFileURL })
        XCTAssertTrue(plan.blockedByMigratedDescendant.isEmpty)
    }

    // MARK: - 夹具

    private func makeWorkspace() throws -> (rootURL: URL, homeURL: URL, appsURL: URL, externalRootURL: URL) {
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent("CompanionDataTests-\(UUID().uuidString)")
        let homeURL = rootURL.appendingPathComponent("Home")
        let appsURL = rootURL.appendingPathComponent("Applications")
        let externalRootURL = rootURL.appendingPathComponent("External")
        for url in [homeURL, appsURL, externalRootURL] {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return (rootURL, homeURL, appsURL, externalRootURL)
    }

    private func cleanupWorkspace(_ rootURL: URL) {
        guard rootURL.lastPathComponent.hasPrefix("CompanionDataTests-") else { return }
        try? fileManager.removeItem(at: rootURL)
    }

    private func createAppBundle(named name: String, bundleID: String, in appsURL: URL) throws -> URL {
        let appURL = appsURL.appendingPathComponent(name)
        let contentsURL = appURL.appendingPathComponent("Contents")
        let macOSURL = contentsURL.appendingPathComponent("MacOS")
        try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try "echo test".write(to: macOSURL.appendingPathComponent(name.replacingOccurrences(of: ".app", with: "")),
                              atomically: true, encoding: .utf8)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": name.replacingOccurrences(of: ".app", with: "")
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contentsURL.appendingPathComponent("Info.plist"))
        return appURL
    }

    private func createDirectoryWithPayload(at directoryURL: URL) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try "payload".write(to: directoryURL.appendingPathComponent("payload.txt"), atomically: true, encoding: .utf8)
    }
}
