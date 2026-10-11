import Darwin
import Foundation
import Testing
@testable import AppPorts

struct SignatureRecoveryDependencyTests {
    @Test("Verified shared-group entitlement finds links recorded under another app")
    func sharedGroupHasNoNameOrOwnerHeuristic() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let link = fixture.group.appendingPathComponent("Data/Library/Database")
        try fixture.makeLink(link, destination: fixture.external)
        try fixture.store.upsertManagedLink(.init(operationID: UUID(), originalPath: link.path,
            destinationPath: fixture.external.path, destinationIdentity: DataPathIdentity.capture(fixture.external),
            appName: "Unrelated Partner", bundleIdentifier: "com.partner.other", dataDirType: DataDirType.groupContainers.rawValue))
        let result = await fixture.inspect()
        #expect(!result.isConfirmedClear)
        #expect(result.linkedItems.count == 1)
        #expect(result.linkedItems.contains { $0.path.standardizedFileURL.path == link.standardizedFileURL.path })
        #expect(result.readIssues.isEmpty)
    }

    @Test("Unmanaged hidden and deep classic links are discovered", arguments: [".hidden", (0..<18).map { "level\($0)" }.joined(separator: "/")])
    func discoversDeepLinks(relative: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let link = fixture.container.appendingPathComponent("Data/" + relative + "/Database")
        try fixture.makeLink(link, destination: fixture.external)
        let result = await fixture.inspect()
        #expect(result.linkedItems.contains { $0.path.standardizedFileURL.path == link.standardizedFileURL.path })
    }

    @Test("A dangling classic link is not treated as absent")
    func offlineDestinationStillBlocks() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let link = fixture.container.appendingPathComponent("Data/Database")
        try fixture.makeLink(link, destination: fixture.root.appendingPathComponent("OfflineVolume/Data"))
        let result = await fixture.inspect()
        #expect(!result.isConfirmedClear)
        #expect(result.linkedItems.contains { $0.path.standardizedFileURL.path == link.standardizedFileURL.path } || result.readIssues.contains { $0.url.standardizedFileURL.path == link.standardizedFileURL.path })
    }

    @Test("Links within an entitled container remain in the official sandbox scope")
    func internalLinksAreAllowed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let target = fixture.container.appendingPathComponent("Data/Actual")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try fixture.makeLink(fixture.container.appendingPathComponent("Data/Alias"), destination: target)
        #expect(await fixture.inspect().isConfirmedClear)
    }

    @Test("A normal macOS container shortcut does not block repair")
    func standardShortcutIsNotAClassicMigration() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let downloads = fixture.home.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try fixture.makeLink(fixture.container.appendingPathComponent("Data/Downloads"), destination: downloads)
        #expect(await fixture.inspect().isConfirmedClear)
    }

    @Test("A missing managed entry remains an unresolved dependency")
    func missingRecordedLinkDoesNotPass() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let link = fixture.group.appendingPathComponent("Data/Database")
        try fixture.store.upsertManagedLink(.init(operationID: UUID(), originalPath: link.path,
            destinationPath: fixture.external.path, destinationIdentity: DataPathIdentity.capture(fixture.external),
            appName: "Other", bundleIdentifier: "com.other", dataDirType: DataDirType.groupContainers.rawValue))
        let result = await fixture.inspect()
        #expect(!result.isConfirmedClear)
        #expect(result.readIssues.contains { $0.url.standardizedFileURL.path == link.standardizedFileURL.path })
    }

    @Test("Read failures are not presented as an empty dependency list")
    func unreadableContainerDoesNotPass() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try #require(getuid() != 0)
        let blocked = fixture.container.appendingPathComponent("Data/Private")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        #expect(chmod(blocked.path, 0) == 0)
        defer { _ = chmod(blocked.path, 0o700) }
        let result = await fixture.inspect()
        #expect(!result.isConfirmedClear)
        #expect(result.readIssues.contains { $0.url.standardizedFileURL.path == blocked.standardizedFileURL.path && $0.isPermissionDenied })
    }

    @Test("Unrelated undeclared shared groups do not block this app")
    func noFuzzyGroupMatching() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeLink(fixture.home.appendingPathComponent("Library/Group Containers/com.chat.similar/Data/DB"), destination: fixture.external)
        #expect(await fixture.inspect().isConfirmedClear)
    }

    @Test("Malformed entitled paths cannot escape their container", arguments: ["../outside", ".", "", "a/../../outside"])
    func rejectsPathTraversal(group: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let result = await SignatureRecoveryDependencyCheck.inspect(bundleIdentifier: "com.test.chat", applicationGroups: [group], homeDirectory: fixture.home, store: fixture.store)
        #expect(!result.isConfirmedClear)
    }

    @Test("A corrupt migration store cannot imply that there are no classic links")
    func invalidStoreDoesNotPass() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("Corrupt".utf8).write(to: fixture.ledger)
        #expect(!(await fixture.inspect().isConfirmedClear))
    }

    private struct Fixture {
        let root: URL
        var home: URL { root.appendingPathComponent("Home") }
        var external: URL { root.appendingPathComponent("External") }
        var container: URL { home.appendingPathComponent("Library/Containers/com.test.chat") }
        var group: URL { home.appendingPathComponent("Library/Group Containers/TEAM.shared.repository") }
        var ledger: URL { root.appendingPathComponent("records.plist") }
        var store: ContainerMountStore { .init(fileURL: ledger) }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("SignatureDependencies-" + UUID().uuidString).standardizedFileURL.resolvingSymlinksInPath()
            for path in [home, external, container, group] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        }
        func makeLink(_ link: URL, destination: URL) throws {
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        }
        func inspect() async -> SignatureRecoveryDependencyCheck.Inspection {
            await SignatureRecoveryDependencyCheck.inspect(bundleIdentifier: "com.test.chat", applicationGroups: ["TEAM.shared.repository"], homeDirectory: home, store: store)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
