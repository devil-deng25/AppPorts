import Darwin
import Foundation
import XCTest
@testable import AppPorts

/// Opt-in resources; ordinary regression runs skip these measured workloads.
/// The coordinator owns the temporary root and an optional private APFS image.
final class AppPortsResourceValidationTests: XCTestCase {
    func testFourGiBApplicationSignAndLocationRoundTrip() async throws {
        let fixture = try Fixture(requiredCase: "large-app")
        try await fixture.stage("started")
        let app = fixture.local.appendingPathComponent("Synthetic.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: contents.appendingPathComponent("MacOS/Synthetic"))
        let plist: [String: String] = ["CFBundleIdentifier": "org.appports.synthetic.resource", "CFBundleExecutable": "Synthetic", "CFBundleName": "Synthetic", "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let payload = contents.appendingPathComponent("Resources/payload.bin")
        FileManager.default.createFile(atPath: payload.path, contents: nil)
        let output = try FileHandle(forWritingTo: payload)
        let block = Data((0..<1_048_576).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 17) })
        for _ in 0..<4096 { try autoreleasepool { try output.write(contentsOf: block) } }
        try output.synchronize()
        try output.close()
        try await fixture.stage("fixture-ready")
        let signer = CodeSigner(backupDirectoryURL: fixture.root.appendingPathComponent("SignatureBackups"),
            allowAdministratorPrompt: false, commandTimeout: 300, requireStopped: { _, _ in })
        let signed = try await signer.sign(appURL: app, bundleIdentifier: nil)
        XCTAssertTrue(signed.committed)
        XCTAssertNil(signed.cleanupWarning)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent("SignatureBackups").path), ["signature-operation.lock"])
        let materials = try await signer.signatureMaterials()
        XCTAssertTrue(materials.isEmpty)
        try await fixture.stage("manual-sign-complete")
        let before = try SignatureSnapshot.fingerprint(of: app)
        let destination = fixture.external.appendingPathComponent("Synthetic.app")
        let service = AppMigrationService(dockShortcutUpdater: { _, _ in 0 },
            transferStore: AppTransferStore(directoryURL: fixture.root.appendingPathComponent("AppTransfers")),
            signatureFactStore: SignatureFactStore(backupDirectoryURL: fixture.root.appendingPathComponent("SignatureBackups")), runningApplications: { [] })
        let moved = try await service.moveAndLink(appToMove: AppItem(name: "Synthetic.app", path: app, status: AppStatus.local),
            destinationURL: destination, isRunning: false, lockExternal: false, progressHandler: nil)
        XCTAssertTrue(moved.isComplete, moved.pendingMessage ?? "")
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: destination), before)
        try await fixture.stage("application-moved")
        let restored = try await service.moveBack(app: AppItem(name: "Synthetic.app", path: destination, status: AppStatus.external),
            localDestinationURL: app, progressHandler: nil)
        XCTAssertTrue(restored.transferResult.isComplete, restored.transferResult.pendingMessage ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: app), before)
        XCTAssertTrue(try service.pendingTransfers().isEmpty)
        try await fixture.stage("application-restored")
    }

    func testHundredThousandSmallFilesDataRoundTrip() async throws {
        let fixture = try Fixture(requiredCase: "many-files")
        try await fixture.stage("started")
        let source = fixture.local.appendingPathComponent("Payload")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        for directoryIndex in 0..<100 {
            let directory = source.appendingPathComponent(String(directoryIndex))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            for fileIndex in 0..<1000 {
                try autoreleasepool {
                    try Data("payload \(directoryIndex)/\(fileIndex)".utf8).write(to: directory.appendingPathComponent(String(fileIndex)))
                }
            }
        }
        try await fixture.stage("fixture-ready")
        let store = ContainerMountStore(fileURL: fixture.root.appendingPathComponent("data-records.plist"))
        let mover = DataDirMover(homeDir: fixture.local, store: store)
        let item = DataDirItem(name: "Payload", path: source, type: .custom, priority: .recommended, description: "Synthetic fixture")
        let migrated = try await mover.migrateAndComplete(item: item, to: fixture.external, progressHandler: nil)
        XCTAssertNil(migrated.cleanupWarning)
        try await fixture.stage("data-moved")
        try Data("written after activation".utf8).write(to: source.appendingPathComponent("new-file"))
        let restored = try await mover.restoreAndComplete(item: item, progressHandler: nil)
        XCTAssertNil(restored.cleanupWarning)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("new-file"), encoding: .utf8), "written after activation")
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("99/999"), encoding: .utf8), "payload 99/999")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.external.appendingPathComponent("Payload").path))
        XCTAssertTrue(try store.transfers().isEmpty)
        try await fixture.stage("data-restored")
    }

    private struct Fixture {
        let root: URL
        let local: URL
        let external: URL
        init(requiredCase: String) throws {
            let environment = ProcessInfo.processInfo.environment
            guard environment["APPPORTS_RESOURCE_CASE"] == requiredCase,
                  let path = environment["APPPORTS_RESOURCE_ROOT"] else {
                throw XCTSkip("Set APPPORTS_RESOURCE_CASE and a private APPPORTS_RESOURCE_ROOT for measured validation")
            }
            root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            guard root.path.hasPrefix(temporary.path + "/"), root.lastPathComponent.hasPrefix("AppPortsResource-") else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            local = root.appendingPathComponent("Local")
            external = root.appendingPathComponent("External")
            guard !FileManager.default.fileExists(atPath: local.path),
                  FileManager.default.fileExists(atPath: external.path) else { throw CocoaError(.fileWriteFileExists) }
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
        }
        func stage(_ name: String) async throws {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let record: [String: Any] = ["stage": name, "pid": Int(getpid()), "time": Date().timeIntervalSince1970,
                "maximumRSSBytes": usage.ru_maxrss]
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            try data.write(to: root.appendingPathComponent("status.json"), options: .atomic)
            try data.write(to: root.appendingPathComponent(name + ".json"), options: .atomic)
            if name == "fixture-ready", ProcessInfo.processInfo.environment["APPPORTS_RESOURCE_COORDINATED"] == "1" {
                let acknowledgement = root.appendingPathComponent("operation-baseline-ready.json")
                let deadline = Date().addingTimeInterval(45)
                while true {
                    if let bytes = try? Data(contentsOf: acknowledgement),
                       let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                       object["pid"] as? Int == Int(getpid()) { break }
                    guard Date() < deadline else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT),
                            userInfo: [NSLocalizedDescriptionKey: "Resource coordinator did not record the operation baseline"])
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            print("Resource validation: \(name), pid \(getpid()), maximum RSS \(usage.ru_maxrss)")
        }
    }
}
