import Foundation
import Testing
@testable import AppPorts

struct ManualSigningSelectionTests {
    @Test("Manual confirmation reports the selected installation and its full-copy space budget")
    func selectionIncludesRealTemporaryLocationAndCapacity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ManualSigningSelection-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Selected.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"),
            to: contents.appendingPathComponent("MacOS/Fixture"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.appports.selection.fixture",
            "CFBundleExecutable": "Fixture", "CFBundleName": "Selected", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0"], format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let entry = root.appendingPathComponent("Entry.app")
        try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: app)
        let selected = try DataMigrationWorkflow.signingTarget(at: entry)
        #expect(selected.url.path == app.path)
        #expect(selected.identity?.matchesFilesystemObject(try DataPathIdentity.capture(app)) == true)
        #expect(selected.fingerprint == (try SignatureSnapshot.fingerprint(of: app)))
        #expect(selected.temporarySpaceRequirement.parentURL.path == root.path)
        #expect(selected.temporarySpaceRequirement.requiredAdditionalBytes > selected.temporarySpaceRequirement.logicalSourceBytes)
        #expect(selected.confirmationMessage.contains(app.lastPathComponent))
        #expect(selected.confirmationMessage.contains(root.path))
        #expect(selected.confirmationMessage.contains(LocalizedByteCountFormatter.string(
            fromByteCount: selected.temporarySpaceRequirement.requiredAdditionalBytes)))
    }
}
