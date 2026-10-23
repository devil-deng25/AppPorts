import XCTest
@testable import AppPorts

/// 图库状态判定是这块功能里唯一有分支的地方：软链指向哪里、外置盘在不在、
/// 受管副本还在不在。发现与判定都不碰迁移逻辑，因此可以完全用构造的事实来测。
final class PhotoLibraryTests: XCTestCase {
    // MARK: - 发现

    func testDiscoveryFindsOnlyPhotoLibraryPackages() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoLibraryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // 包目录：应当被发现（扩展名大小写不作为判据）。
        let package = root.appendingPathComponent("Photos Library.photoslibrary")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let upperCase = root.appendingPathComponent("Second.PHOTOSLIBRARY")
        try FileManager.default.createDirectory(at: upperCase, withIntermediateDirectories: true)
        // 同名但其实是文件：Finder 里看不出来，文件系统上却不是目录，必须排除。
        let plainFile = root.appendingPathComponent("Broken.photoslibrary")
        try Data("x".utf8).write(to: plainFile)
        // 普通目录：与图库无关。
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Screenshots"),
            withIntermediateDirectories: true
        )

        let found = PhotoLibraryDiscovery.libraryURLs(in: root)
            .map { $0.lastPathComponent }
            .sorted()

        XCTAssertEqual(found, ["Photos Library.photoslibrary", "Second.PHOTOSLIBRARY"])
    }

    func testDiscoveryReturnsEmptyWhenDirectoryMissing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoLibraryTests-missing-\(UUID().uuidString)")
        XCTAssertTrue(PhotoLibraryDiscovery.libraryURLs(in: missing).isEmpty)
    }

    // MARK: - 状态判定

    private func facts(localExists: Bool,
                       isSymlink: Bool = false,
                       destination: String? = nil,
                       destinationExists: Bool = false,
                       externalCopyExists: Bool = false) -> PhotoLibraryFacts {
        PhotoLibraryFacts(
            localExists: localExists,
            localIsSymlink: isSymlink,
            symlinkDestination: destination.map { URL(fileURLWithPath: $0) },
            symlinkDestinationExists: destinationExists,
            externalCopyExists: externalCopyExists
        )
    }

    func testResolutionMarksPlainDirectoryAsMovable() {
        let state = PhotoLibraryStateResolver.resolve(
            localURL: URL(fileURLWithPath: "/Users/x/Pictures/Photos Library.photoslibrary"),
            externalDestination: nil,
            facts: facts(localExists: true)
        )
        XCTAssertEqual(state, .movable)
        XCTAssertTrue(state.canMove)
        XCTAssertFalse(state.canRestore)
    }

    func testResolutionMarksResolvedSymlinkAsOnExternal() {
        let destination = "/Volumes/Ext/Pictures/Photos Library.photoslibrary"
        let state = PhotoLibraryStateResolver.resolve(
            localURL: URL(fileURLWithPath: "/Users/x/Pictures/Photos Library.photoslibrary"),
            externalDestination: URL(fileURLWithPath: destination),
            facts: facts(localExists: true, isSymlink: true, destination: destination, destinationExists: true)
        )
        XCTAssertEqual(state, .onExternal(URL(fileURLWithPath: destination)))
        XCTAssertTrue(state.canRestore)
        XCTAssertFalse(state.needsAttention)
    }

    /// 外置盘没接上时，软链还在但这不等于「已在外置盘」——必须让人看到问题。
    func testResolutionMarksDanglingSymlinkAsUnavailable() {
        let destination = "/Volumes/Ext/Pictures/Photos Library.photoslibrary"
        let state = PhotoLibraryStateResolver.resolve(
            localURL: URL(fileURLWithPath: "/Users/x/Pictures/Photos Library.photoslibrary"),
            externalDestination: URL(fileURLWithPath: destination),
            facts: facts(localExists: false, isSymlink: true, destination: destination, destinationExists: false)
        )
        XCTAssertEqual(state, .externalUnavailable(URL(fileURLWithPath: destination)))
        XCTAssertTrue(state.needsAttention)
        XCTAssertFalse(state.canMove)
    }

    func testResolutionMarksPendingRelinkWhenLocalMissingButCopyExists() {
        let destination = "/Volumes/Ext/Pictures/Photos Library.photoslibrary"
        let state = PhotoLibraryStateResolver.resolve(
            localURL: URL(fileURLWithPath: "/Users/x/Pictures/Photos Library.photoslibrary"),
            externalDestination: URL(fileURLWithPath: destination),
            facts: facts(localExists: false, externalCopyExists: true)
        )
        XCTAssertEqual(state, .pendingRelink(URL(fileURLWithPath: destination)))
        XCTAssertTrue(state.canRelink)
        XCTAssertTrue(state.needsAttention)
    }

    func testResolutionMarksMissingWhenNothingCanBeFound() {
        let state = PhotoLibraryStateResolver.resolve(
            localURL: URL(fileURLWithPath: "/Users/x/Pictures/Photos Library.photoslibrary"),
            externalDestination: URL(fileURLWithPath: "/Volumes/Ext/Pictures/Photos Library.photoslibrary"),
            facts: facts(localExists: false, externalCopyExists: false)
        )
        XCTAssertEqual(state, .missing)
        XCTAssertTrue(state.needsAttention)
    }

    /// 迁移过又还原回来的图库，本地又是实体目录，应当允许再搬一次。
    func testResolutionAllowsMovingRestoredLibraryAgain() {
        let state = PhotoLibraryStateResolver.resolve(
            localURL: URL(fileURLWithPath: "/Users/x/Pictures/Photos Library.photoslibrary"),
            externalDestination: URL(fileURLWithPath: "/Volumes/Ext/Pictures/Photos Library.photoslibrary"),
            facts: facts(localExists: true, externalCopyExists: true)
        )
        XCTAssertEqual(state, .movable)
        XCTAssertTrue(state.canMove)
    }

    /// 整个「图片」文件夹被迁移后，图库自己不是软链，但真实位置已经在外置盘上。
    /// 这时再提供「移动到外置盘」只会撞上「与已管理目录存在包含关系」。
    func testResolutionTreatsLibraryOnAnotherVolumeAsAlreadyExternal() {
        let resolved = URL(fileURLWithPath: "/Volumes/Ext/Pictures/Photos Library.photoslibrary")
        let state = PhotoLibraryStateResolver.resolve(
            localURL: URL(fileURLWithPath: "/Users/x/Pictures/Photos Library.photoslibrary"),
            externalDestination: nil,
            facts: PhotoLibraryFacts(
                localExists: true,
                localIsSymlink: false,
                symlinkDestination: nil,
                symlinkDestinationExists: false,
                externalCopyExists: false,
                resolvedURL: resolved,
                sameVolumeAsHome: false
            )
        )
        XCTAssertEqual(state, .onExternal(resolved))
        XCTAssertFalse(state.canMove)
    }

    // MARK: - 事实采集

    func testCaptureReadsSymlinkDestinationFromDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoLibraryFacts-\(UUID().uuidString)")
        let target = root.appendingPathComponent("Ext/Pictures/Photos Library.photoslibrary")
        let link = root.appendingPathComponent("Photos Library.photoslibrary")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Pictures"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: root) }

        let captured = PhotoLibraryFacts.capture(localURL: link, externalDestination: target)

        XCTAssertTrue(captured.localIsSymlink)
        XCTAssertTrue(captured.localExists)
        XCTAssertEqual(captured.symlinkDestination?.standardizedFileURL.path,
                       target.standardizedFileURL.path)
        XCTAssertTrue(captured.symlinkDestinationExists)
        XCTAssertTrue(captured.externalCopyExists)
        XCTAssertEqual(
            PhotoLibraryStateResolver.resolve(
                localURL: link,
                externalDestination: target,
                facts: captured
            ),
            .onExternal(target.standardizedFileURL)
        )
    }

    /// 本地是实体目录时，`externalCopyExists` 只影响能否接回，不影响「可移动」。
    func testItemExposesConfigDestinationForRestore() {
        let config = CustomDirConfig(
            localPath: "/Users/x/Pictures/Photos Library.photoslibrary",
            externalBasePath: "/Volumes/Ext/Pictures"
        )
        let item = PhotoLibraryItem(
            url: config.localURL,
            state: .onExternal(config.externalDestinationURL),
            config: config
        )
        XCTAssertEqual(item.externalDestination?.path, config.externalDestinationURL.path)
        XCTAssertEqual(item.displayName, "Photos Library")
    }
}
