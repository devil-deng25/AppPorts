import Darwin
import Foundation
import Testing
@testable import AppPorts

/// 真实证书签名的测试应用，只读取、从不修改。
///
/// 优先用 `APPPORTS_SIGNED_TEST_APP` 指定的应用；否则取当前 Xcode 自带的 Apple 签名工具，
/// 跑测试时它一定在。系统卷上的平台应用不能再当回退：macOS 27 上复制出来的副本会以
/// "resource envelope is obsolete (custom omit rules)" 校验失败。
/// 找不到复制后仍能严格校验的应用时，相关测试标为跳过，而不是误报签名逻辑失败。
private enum SignedTestApplication {
    static let source: URL? = {
        let configured = ProcessInfo.processInfo.environment["APPPORTS_SIGNED_TEST_APP"].map { URL(fileURLWithPath: $0) }
        return ([configured].compactMap { $0 } + xcodeBundledApplications).lazy
            .compactMap { try? CodeSigner.resolveAppURL(at: $0) }
            .first(where: verifiesStrictlyAfterCopy)
    }()

    private static var xcodeBundledApplications: [URL] {
        // 测试框架从当前 Xcode 里加载（…/Xcode.app/Contents/SharedFrameworks/Testing.framework）。
        let frameworks = Bundle.allFrameworks.map(\.bundlePath)
        guard let frameworkPath = frameworks.first(where: { $0.hasSuffix("/Testing.framework") || $0.hasSuffix("/XCTest.framework") }),
              let range = frameworkPath.range(of: ".app/Contents/") else { return [] }
        let xcode = URL(fileURLWithPath: String(frameworkPath[..<range.lowerBound]) + ".app")
        // Accessibility Inspector 带私有授权，能顺带验证授权的恢复。
        return ["Accessibility Inspector.app", "FileMerge.app"].map {
            xcode.appendingPathComponent("Contents/Applications").appendingPathComponent($0)
        }
    }

    private static func verifiesStrictlyAfterCopy(_ app: URL) -> Bool {
        let probe = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppPortsSignedTestApplication-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: probe) }
        do {
            try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
            let copy = probe.appendingPathComponent(app.lastPathComponent)
            try SignatureSnapshot.copy(from: app, to: copy)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = ["--verify", "--deep", "--strict", copy.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

@Suite("Code signing")
struct CodeSignerTests {
    enum PortalKind: CaseIterable {
        case native, legacyScript, wholeAppSymlink, contentsSymlink
    }

    @Test("Every supported portal resolves to the real application", arguments: PortalKind.allCases)
    func resolvesRealApplication(kind: PortalKind) throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let realApp = workspace.root.appendingPathComponent("External/Chat's app.app")
        try makeBundle(at: realApp)
        let portal = workspace.root.appendingPathComponent("Chat.app")

        switch kind {
        case .native:
            try makeBundle(at: portal, identifier: "com.appports.tests.chat.appports.stub")
            try (realApp.path + "\n").write(
                to: portal.appendingPathComponent("Contents/Resources/real_app_path.txt"),
                atomically: true, encoding: .utf8
            )
        case .legacyScript:
            try makeBundle(at: portal, identifier: "com.appports.tests.chat.appports.stub")
            let quotedPath = realApp.path.replacingOccurrences(of: "'", with: "'\\''")
            try "#!/bin/bash\nREAL_APP='\(quotedPath)'\nopen \"$REAL_APP\"\n".write(
                to: portal.appendingPathComponent("Contents/MacOS/launcher"),
                atomically: true, encoding: .utf8
            )
        case .wholeAppSymlink:
            try FileManager.default.createSymbolicLink(atPath: portal.path, withDestinationPath: "External/Chat's app.app")
        case .contentsSymlink:
            try FileManager.default.createDirectory(at: portal, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                atPath: portal.appendingPathComponent("Contents").path,
                withDestinationPath: "../External/Chat's app.app/Contents"
            )
        }

        #expect(try CodeSigner.resolveAppURL(at: portal).path == realApp.path)
    }

    enum BrokenPortal: CaseIterable {
        case missingTarget, emptyPath, relativePath, missingMetadata, cycle, brokenMetadataLink
    }

    @Test("Broken portals fail before the stub or backups are modified", arguments: BrokenPortal.allCases)
    func refusesBrokenPortal(kind: BrokenPortal) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let portal = workspace.root.appendingPathComponent("Chat.app")
        try makeBundle(at: portal, identifier: "com.appports.tests.chat.appports.stub")
        let pathFile = portal.appendingPathComponent("Contents/Resources/real_app_path.txt")
        switch kind {
        case .missingTarget:
            try workspace.root.appendingPathComponent("Missing.app").path.write(to: pathFile, atomically: true, encoding: .utf8)
        case .emptyPath:
            try "\n".write(to: pathFile, atomically: true, encoding: .utf8)
        case .relativePath:
            try "../Missing.app".write(to: pathFile, atomically: true, encoding: .utf8)
        case .missingMetadata:
            break
        case .cycle:
            try portal.path.write(to: pathFile, atomically: true, encoding: .utf8)
        case .brokenMetadataLink:
            try FileManager.default.createSymbolicLink(atPath: pathFile.path, withDestinationPath: "missing.txt")
        }
        let executable = portal.appendingPathComponent("Contents/MacOS/Fixture")
        let original = try Data(contentsOf: executable)
        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false)

        do {
            try await signer.sign(appURL: portal, bundleIdentifier: nil)
            Issue.record("A broken portal must not be signed as a normal application")
        } catch CodeSigner.SigningError.applicationUnavailable {
            // Expected: fail before changing the local portal.
        }

        #expect(try Data(contentsOf: executable) == original)
        #expect(FileManager.default.fileExists(atPath: workspace.backups.path) == false)
    }

    @Test("A backup records the real application's identity and location")
    func backupUsesRealApplication() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let realApp = workspace.root.appendingPathComponent("External/Chat.app")
        let identifier = "com.appports.tests.real-chat"
        try makeBundle(at: realApp, identifier: identifier)
        let portal = workspace.root.appendingPathComponent("Chat.app")
        let stubIdentifier = identifier + ".appports.stub"
        try makeBundle(at: portal, identifier: stubIdentifier)
        try realApp.path.write(to: portal.appendingPathComponent("Contents/Resources/real_app_path.txt"), atomically: true, encoding: .utf8)

        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false)
        try await signer.backupOriginalSignature(appURL: portal, bundleIdentifier: stubIdentifier)

        let backupData = try Data(contentsOf: workspace.backups.appendingPathComponent(identifier + ".plist"))
        let backup = try #require(PropertyListSerialization.propertyList(from: backupData, format: nil) as? [String: Any])
        #expect(backup["bundleIdentifier"] as? String == identifier)
        #expect(backup["originalPath"] as? String == realApp.path)
        #expect(FileManager.default.fileExists(atPath: workspace.backups.appendingPathComponent(stubIdentifier + ".plist").path) == false)
    }

    @Test("Signing unlocks nested files even when the bundle root is not locked")
    func signingPreservesMixedFlags() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let app = workspace.root.appendingPathComponent("Mixed Locks.app")
        try makeBundle(at: app)
        let helper = app.appendingPathComponent("Contents/Helpers/Helper.app")
        try makeBundle(at: helper, identifier: "com.appports.tests.helper")
        try codesign(["--force", "--deep", "--sign", "-", app.path])
        let main = app.appendingPathComponent("Contents/MacOS/Fixture")
        let helperExecutable = helper.appendingPathComponent("Contents/MacOS/Fixture")
        try setFlags(UInt32(UF_IMMUTABLE | UF_HIDDEN), at: main)
        try setFlags(UInt32(UF_IMMUTABLE), at: helperExecutable)
        try setFlags(UInt32(UF_IMMUTABLE), at: app.appendingPathComponent("Contents/Helpers"))
        let before = try allFlags(in: app)
        try #require(before[app.path] == 0)

        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false)
        try await signer.sign(appURL: app, bundleIdentifier: nil)

        #expect(await signer.verify(appURL: app) == .valid)
        #expect(await signer.verify(appURL: helper) == .valid)
        #expect(try allFlags(in: app) == before)
    }

    @Test("Read-only code and resources can be signed without changing their permissions or unrelated metadata")
    func signingAllowsReadOnlyFiles() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let app = workspace.root.appendingPathComponent("Read Only.app")
        try makeBundle(at: app)
        let main = app.appendingPathComponent("Contents/MacOS/Fixture")
        let info = app.appendingPathComponent("Contents/Info.plist")
        let resources = app.appendingPathComponent("Contents/Resources")
        let payload = resources.appendingPathComponent("payload.txt")
        let detritusFile = resources.appendingPathComponent("metadata.bin")
        try Data("read-only resource".utf8).write(to: payload)
        try Data("resource with a fork".utf8).write(to: detritusFile)
        let metadata = Data("preserve this attribute".utf8)
        let attribute = "com.appports.tests.metadata"
        try #require(metadata.withUnsafeBytes {
            setxattr(app.path, attribute, $0.baseAddress, $0.count, 0, 0)
        } == 0)
        let resourceFork = Data("unsealed resource fork".utf8)
        try #require(resourceFork.withUnsafeBytes {
            setxattr(detritusFile.path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, 0)
        } == 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: main.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: info.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: payload.path)

        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false)
        try await signer.sign(appURL: app, bundleIdentifier: nil)

        #expect(await signer.verify(appURL: app) == .valid)
        #expect((try FileManager.default.attributesOfItem(atPath: main.path))[.posixPermissions] as? Int == 0o555)
        #expect((try FileManager.default.attributesOfItem(atPath: info.path))[.posixPermissions] as? Int == 0o444)
        #expect((try FileManager.default.attributesOfItem(atPath: payload.path))[.posixPermissions] as? Int == 0o444)
        #expect(getxattr(app.path, attribute, nil, 0, 0, 0) == metadata.count)
        #expect(getxattr(detritusFile.path, "com.apple.ResourceFork", nil, 0, 0, 0) == -1)
        #expect(errno == ENOATTR)
        try await signer.restoreSignature(appURL: app, bundleIdentifier: "com.appports.tests.fixture")
        #expect(try readAttribute("com.apple.ResourceFork", at: detritusFile) == resourceFork)
        #expect(try readAttribute(attribute, at: app) == metadata)
    }

    @Test("Entitlements are read from the signed bundle and the sandbox flag is detected")
    func readsEntitlements() throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let sandboxed = workspace.root.appendingPathComponent("Sandboxed.app")
        try makeBundle(at: sandboxed, identifier: "com.appports.tests.sandboxed")
        let sandboxEntitlements = try writeEntitlements(sandbox: true, in: workspace)
        try codesign(["--force", "--sign", "-", "--entitlements", sandboxEntitlements.path, sandboxed.path])
        let plain = workspace.root.appendingPathComponent("Plain.app")
        try makeBundle(at: plain, identifier: "com.appports.tests.plain")
        try codesign(["--force", "--sign", "-", plain.path])
        let unsigned = workspace.root.appendingPathComponent("Unsigned.app")
        try makeBundle(at: unsigned, identifier: "com.appports.tests.unsigned")

        #expect(CodeSigner.entitlements(at: sandboxed)?["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(CodeSigner.isSandboxed(at: sandboxed))
        #expect(CodeSigner.isSandboxed(at: plain) == false)
        #expect(CodeSigner.isSandboxed(at: unsigned) == false)
        #expect(CodeSigner.entitlements(at: unsigned) == nil)
    }

    @Test("Sandboxed applications are refused before the bundle or backups are modified")
    func refusesSandboxedApplication() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let realApp = workspace.root.appendingPathComponent("External/Chat.app")
        try makeBundle(at: realApp, identifier: "com.appports.tests.sandboxed-chat")
        let sandboxEntitlements = try writeEntitlements(sandbox: true, in: workspace)
        try codesign(["--force", "--sign", "-", "--entitlements", sandboxEntitlements.path, realApp.path])
        let portal = workspace.root.appendingPathComponent("Chat.app")
        try makeBundle(at: portal, identifier: "com.appports.tests.sandboxed-chat.appports.stub")
        try realApp.path.write(to: portal.appendingPathComponent("Contents/Resources/real_app_path.txt"), atomically: true, encoding: .utf8)
        let executable = realApp.appendingPathComponent("Contents/MacOS/Fixture")
        let original = try Data(contentsOf: executable)
        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false)

        do {
            try await signer.sign(appURL: portal, bundleIdentifier: nil)
            Issue.record("A sandboxed application must never be ad-hoc re-signed")
        } catch CodeSigner.SigningError.sandboxedApplication(let url) {
            #expect(url.path == realApp.path)
        }

        #expect(try Data(contentsOf: executable) == original)
        #expect(CodeSigner.isSandboxed(at: realApp))
        #expect(FileManager.default.fileExists(atPath: workspace.backups.path) == false)
    }

    @Test("Automatic signing of Application Support data inspects the real sandbox app before any stage")
    func ordinaryDataMigrationRequiresSandboxApproval() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let realApp = workspace.root.appendingPathComponent("External/Chat.app")
        try makeBundle(at: realApp, identifier: "com.appports.tests.data-sandbox")
        let entitlements = try writeEntitlements(sandbox: true, in: workspace)
        try codesign(["--force", "--sign", "-", "--entitlements", entitlements.path, realApp.path])
        let portal = workspace.root.appendingPathComponent("Chat.app")
        try makeBundle(at: portal, identifier: "com.appports.tests.data-sandbox.appports.stub")
        try realApp.path.write(to: portal.appendingPathComponent("Contents/Resources/real_app_path.txt"), atomically: true, encoding: .utf8)
        let dataDirectory = workspace.root.appendingPathComponent("Library/Application Support/Chat")
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let dataFile = dataDirectory.appendingPathComponent("state.txt")
        let originalData = Data("original application data".utf8)
        try originalData.write(to: dataFile)
        let originalApp = try SignatureSnapshot.fingerprint(of: realApp)
        #expect(CodeSigner.isSandboxed(at: portal) == false)

        do {
            try await DataMigrationWorkflow.run(
                associatedAppURL: portal,
                classicModeActive: true,
                explicitSigningChoice: true,
                backupSignature: { _ in Issue.record("A global setting must not authorize a sandbox backup") },
                migrate: { Issue.record("Application Support migration must wait for sandbox signing approval") },
                resignApp: { _, _ in Issue.record("The real sandboxed app must not be signed without approval") }
            )
            Issue.record("A plain portal must not bypass approval for its real sandboxed target")
        } catch CodeSigner.SigningError.sandboxedApplication(let url) {
            // 已存在的目录 URL 可能多一个尾斜杠；仍比较解析后的完整目标路径。
            #expect(url.resolvingSymlinksInPath().standardizedFileURL.path
                == realApp.resolvingSymlinksInPath().standardizedFileURL.path)
        }

        #expect(try Data(contentsOf: dataFile) == originalData)
        #expect(try SignatureSnapshot.fingerprint(of: realApp) == originalApp)
        #expect(CodeSigner.isSandboxed(at: realApp))
    }

    @Test("Signature-replaced classification reads developer and ad-hoc backup identities")
    func signatureReplacedDetection() throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        try FileManager.default.createDirectory(at: workspace.backups, withIntermediateDirectories: true)
        let identifier = "com.appports.tests.replaced"
        let backupURL = workspace.backups.appendingPathComponent(identifier + ".plist")
        try PropertyListSerialization.data(fromPropertyList: [
            "bundleIdentifier": identifier,
            "signingIdentity": "Developer ID Application: Nobody (APPPORTS00)",
            "originalPath": "/Applications/Nobody.app",
            "backupDate": Date()
        ], format: .xml, options: 0).write(to: backupURL)

        let original = CodeSigner.originalSigningIdentity(bundleIdentifier: identifier, backupDirectoryURL: workspace.backups)
        #expect(original == "Developer ID Application: Nobody (APPPORTS00)")
        #expect(CodeSigner.isSignatureReplaced(originalIdentity: original, currentlyAdHoc: true))
        #expect(CodeSigner.isSignatureReplaced(originalIdentity: original, currentlyAdHoc: false) == false)
        #expect(CodeSigner.isSignatureReplaced(originalIdentity: "ad-hoc", currentlyAdHoc: true) == false)
        #expect(CodeSigner.isSignatureReplaced(originalIdentity: nil, currentlyAdHoc: true) == false)

        // Still ad-hoc: the backup must survive so the repair flow can find the app later.
        #expect(FileManager.default.fileExists(atPath: backupURL.path))

        // Developer signatures also occur between pre-backup and re-sign: scanning must preserve the record.
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        #expect(CodeSigner.originalSigningIdentity(bundleIdentifier: identifier, backupDirectoryURL: workspace.backups) == original)
    }

    @Test("Classic mode can opt in to re-signing a sandboxed application")
    func classicModeAllowsSandboxedResign() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let app = workspace.root.appendingPathComponent("Classic.app")
        try makeBundle(at: app, identifier: "com.appports.tests.classic")
        let sandboxEntitlements = try writeEntitlements(sandbox: true, in: workspace)
        try codesign(["--force", "--sign", "-", "--entitlements", sandboxEntitlements.path, app.path])
        try #require(CodeSigner.isSandboxed(at: app))
        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false)

        try await signer.sign(appURL: app, bundleIdentifier: nil, allowSandboxed: true)

        #expect(await signer.verify(appURL: app) == .valid)
        #expect(await signer.hasBackup(bundleIdentifier: "com.appports.tests.classic"))
    }

    @Test("Legacy identity-only backups never pretend to restore signed or unsigned state", arguments: ["Developer ID Application: Nobody (APPPORTS00)", "ad-hoc"])
    func restoreRefusesMissingIdentity(identity: String) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let app = workspace.root.appendingPathComponent("Chat.app")
        let identifier = "com.appports.tests.restore-chat"
        try makeBundle(at: app, identifier: identifier)
        try codesign(["--force", "--sign", "-", app.path])
        try FileManager.default.createDirectory(at: workspace.backups, withIntermediateDirectories: true)
        let backupURL = workspace.backups.appendingPathComponent(identifier + ".plist")
        try PropertyListSerialization.data(fromPropertyList: [
            "bundleIdentifier": identifier,
            "signingIdentity": identity,
            "originalPath": app.path,
            "backupDate": Date()
        ], format: .xml, options: 0).write(to: backupURL)
        let executable = app.appendingPathComponent("Contents/MacOS/Fixture")
        let original = try Data(contentsOf: executable)
        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false)

        do {
            try await signer.restoreSignature(appURL: app, bundleIdentifier: identifier)
            Issue.record("Restoring without the original certificate must fail")
        } catch CodeSigner.SigningError.legacyBackupIncomplete {
            // Neither an authority name nor an ad-hoc label contains the original signature bytes.
        }

        #expect(try Data(contentsOf: executable) == original)
        #expect(FileManager.default.fileExists(atPath: backupURL.path), "The backup must survive a refused restore")
        #expect(await signer.hasBackup(bundleIdentifier: identifier))
    }

    @Test("Signing failure restores locks and leaves linked external data untouched")
    func failureRestoresLocksWithoutFollowingLinks() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let app = workspace.root.appendingPathComponent("Invalid.app")
        try makeBundle(at: app)
        let main = app.appendingPathComponent("Contents/MacOS/Fixture")
        try Data("invalid Mach-O".utf8).write(to: main)
        let outside = workspace.root.appendingPathComponent("ExternalData")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let payload = outside.appendingPathComponent("payload.txt")
        let originalData = Data("unchanged external data".utf8)
        try originalData.write(to: payload)
        let attribute = "com.appports.tests.external-data"
        try #require(originalData.withUnsafeBytes {
            setxattr(payload.path, attribute, $0.baseAddress, $0.count, 0, 0)
        } == 0)
        try setFlags(UInt32(UF_IMMUTABLE), at: outside)
        try setFlags(UInt32(UF_IMMUTABLE | UF_HIDDEN), at: payload)
        try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("Contents/Resources/external-data"), withDestinationURL: outside)
        try setFlags(UInt32(UF_IMMUTABLE), at: app)
        try setFlags(UInt32(UF_IMMUTABLE), at: main)
        let before = try allFlags(in: app)
        let outsideBefore = try allFlags(in: outside)

        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false)
        do {
            try await signer.sign(appURL: app, bundleIdentifier: nil)
            Issue.record("Malformed code must fail signing")
        } catch CodeSigner.SigningError.codesignFailed {
            // Expected: even an actual codesign failure must restore the original flags.
        }

        for (path, flags) in before {
            #expect(try fileFlags(at: URL(fileURLWithPath: path)) == flags)
        }
        #expect(try allFlags(in: outside) == outsideBefore)
        #expect(try Data(contentsOf: payload) == originalData)
        #expect(getxattr(payload.path, attribute, nil, 0, 0, 0) == originalData.count)
    }

    @Test("Complete backups restore unsigned and sandboxed ad-hoc apps byte for byte", arguments: [false, true])
    func snapshotRoundTrip(sandboxed: Bool) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let app = workspace.root.appendingPathComponent("Original.app")
        let helper = app.appendingPathComponent("Contents/Helpers/Helper.app")
        try makeBundle(at: app)
        try makeBundle(at: helper, identifier: "com.appports.tests.helper")
        let entitlements = try writeEntitlements(sandbox: true, in: workspace)
        try codesign(["--force", "--sign", "-", "--entitlements", entitlements.path, helper.path])
        if sandboxed {
            try codesign(["--force", "--sign", "-", "--entitlements", entitlements.path, app.path])
        } else {
            try codesign(["--remove-signature", app.path])
        }
        try Data("original resource".utf8).write(to: app.appendingPathComponent("Contents/Resources/data.txt"))
        try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("Contents/Resources/link").path, withDestinationPath: "data.txt")
        if sandboxed { try codesign(["--force", "--sign", "-", "--entitlements", entitlements.path, app.path]) }
        let before = try SignatureSnapshot.fingerprint(of: app)
        let helperBytes = try Data(contentsOf: helper.appendingPathComponent("Contents/MacOS/Fixture"))
        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false)
        try await signer.sign(appURL: app, bundleIdentifier: nil, allowSandboxed: true)
        #expect(CodeSigner.isSandboxed(at: app) == false)
        try await signer.sign(appURL: app, bundleIdentifier: nil, allowSandboxed: true)

        // 移动过应用也能恢复，不能依赖备份中的旧绝对路径。
        let moved = workspace.root.appendingPathComponent("Moved.app")
        try FileManager.default.moveItem(at: app, to: moved)
        try await signer.restoreSignature(appURL: moved, bundleIdentifier: "com.appports.tests.fixture")
        #expect(try SignatureSnapshot.fingerprint(of: moved) == before)
        #expect(try Data(contentsOf: moved.appendingPathComponent("Contents/Helpers/Helper.app/Contents/MacOS/Fixture")) == helperBytes)
        #expect(CodeSigner.isSandboxed(at: moved) == sandboxed)
        #expect(await signer.hasBackup(bundleIdentifier: "com.appports.tests.fixture") == false)
    }

    @Test("A real certificate-signed application is restored without its private key",
          .enabled(if: SignedTestApplication.source != nil))
    func restoresCertificateSignedApplication() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        // 真实 CMS 签名的应用；只读源程序，所有变更都在测试副本里。
        let source = try #require(SignedTestApplication.source)
        let app = workspace.root.appendingPathComponent("Vendor.app")
        try SignatureSnapshot.copy(from: source, to: app)
        let identifier = try #require(CodeSigner.bundleIdentifier(at: app))
        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false)
        let authority = try #require(await signer.getSigningIdentity(appURL: app))
        try codesign(["--verify", "--deep", app.path])
        let originalVerification = await signer.verify(appURL: app)
        try #require(originalVerification == .valid)
        let original = try SignatureSnapshot.fingerprint(of: app)
        let entitlements = CodeSigner.entitlements(at: app) as NSDictionary?

        try await signer.sign(appURL: app, bundleIdentifier: identifier, allowSandboxed: true)
        #expect(await signer.getSigningIdentity(appURL: app) == nil)
        try await signer.restoreSignature(appURL: app, bundleIdentifier: identifier)

        try codesign(["--verify", "--deep", app.path])
        #expect(await signer.verify(appURL: app) == originalVerification)
        #expect(await signer.getSigningIdentity(appURL: app) == authority)
        #expect(try SignatureSnapshot.fingerprint(of: app) == original)
        #expect(CodeSigner.entitlements(at: app) as NSDictionary? == entitlements)
    }

    @Test("Changed applications cannot be overwritten or paired with an older snapshot")
    func refusesChangesSinceSigning() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let app = workspace.root.appendingPathComponent("Chat.app")
        try makeBundle(at: app)
        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false)
        try await signer.sign(appURL: app, bundleIdentifier: nil)
        let changed = app.appendingPathComponent("Contents/Resources/new-version.txt")
        try Data("new app content".utf8).write(to: changed)
        let before = try SignatureSnapshot.fingerprint(of: app)
        do {
            try await signer.restoreSignature(appURL: app, bundleIdentifier: "com.appports.tests.fixture")
            Issue.record("A restore must not overwrite updates")
        } catch CodeSigner.SigningError.applicationChanged {}
        do {
            try await signer.sign(appURL: app, bundleIdentifier: nil)
            Issue.record("A new version must not reuse the old version's original backup")
        } catch CodeSigner.SigningError.applicationChanged {}
        #expect(try SignatureSnapshot.fingerprint(of: app) == before)
        #expect(await signer.hasBackup(bundleIdentifier: "com.appports.tests.fixture"))
    }

    @Test("An app update during work-copy creation never becomes restorable from the old snapshot")
    func refusesUpdateDuringSigningCopy() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let app = workspace.root.appendingPathComponent("Chat.app")
        try makeBundle(at: app)
        let original = try SignatureSnapshot.fingerprint(of: app)
        let changed = app.appendingPathComponent("Contents/Resources/update.txt")
        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false,
            copyApplication: { source, destination in
                if destination.deletingLastPathComponent().lastPathComponent.hasPrefix(".AppPorts-signature-") {
                    try Data("updated while preparing signature".utf8).write(to: changed)
                }
                try SignatureSnapshot.copy(from: source, to: destination)
            })
        do {
            try await signer.sign(appURL: app, bundleIdentifier: nil)
            Issue.record("The copied update must not be signed against the old backup")
        } catch CodeSigner.SigningError.applicationChanged {}
        #expect(try String(contentsOf: changed, encoding: .utf8) == "updated while preparing signature")
        let record = try readBackup(in: workspace, identifier: "com.appports.tests.fixture")
        #expect(record["restorableFingerprints"] as? [String] == [original])
        #expect(try SignatureSnapshot.fingerprint(of: app) != original)
    }

    @Test("Restoration restores metadata even when the content digest has not changed")
    func restoresMetadataWithIdenticalContent() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let app = workspace.root.appendingPathComponent("Chat.app")
        try makeBundle(at: app)
        let attribute = "com.appports.tests.metadata"
        let original = Data("original metadata".utf8)
        try #require(original.withUnsafeBytes { setxattr(app.path, attribute, $0.baseAddress, $0.count, 0, 0) } == 0)
        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false)
        try await signer.backupOriginalSignature(appURL: app, bundleIdentifier: "com.appports.tests.fixture")
        let before = try SignatureSnapshot.fingerprint(of: app)
        try #require(removexattr(app.path, attribute, 0) == 0)
        #expect(try SignatureSnapshot.fingerprint(of: app) == before)
        try await signer.restoreSignature(appURL: app, bundleIdentifier: "com.appports.tests.fixture")
        #expect(try readAttribute(attribute, at: app) == original)
    }

    @Test("A verified official reinstall starts a fresh backup and retains the old recovery material",
          .enabled(if: SignedTestApplication.source != nil),
          arguments: [false, true])
    func renewsBackupAfterOfficialReinstall(legacy: Bool) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = try #require(SignedTestApplication.source)
        let app = workspace.root.appendingPathComponent("Vendor.app")
        try SignatureSnapshot.copy(from: source, to: app)
        let identifier = try #require(CodeSigner.bundleIdentifier(at: app))
        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false)
        try await signer.sign(appURL: app, bundleIdentifier: identifier, allowSandboxed: true)
        var oldRecord = try readBackup(in: workspace, identifier: identifier)
        let oldSnapshot = workspace.backups.appendingPathComponent(try #require(oldRecord["snapshotName"] as? String))
        if legacy {
            for key in ["schemaVersion", "snapshotName", "originalFingerprint", "restorableFingerprints", "originalSignatureWasValid"] {
                oldRecord.removeValue(forKey: key)
            }
            try PropertyListSerialization.data(fromPropertyList: oldRecord, format: .xml, options: 0)
                .write(to: workspace.backups.appendingPathComponent(identifier + ".plist"))
        }
        try SignatureSnapshot.remove(app)
        try SignatureSnapshot.copy(from: source, to: app)
        // 安装器可能改变目录权限；新内容摘要不能与旧快照混用，官方签名仍须严格有效。
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: app.path)
        try #require(await signer.verify(appURL: app) == .valid)
        let reinstalled = try SignatureSnapshot.fingerprint(of: app)
        try #require((oldRecord["restorableFingerprints"] as? [String])?.contains(reinstalled) != true)
        try await signer.sign(appURL: app, bundleIdentifier: identifier, allowSandboxed: true)
        let newRecord = try readBackup(in: workspace, identifier: identifier)
        #expect(newRecord["originalFingerprint"] as? String == reinstalled)
        #expect(newRecord["snapshotName"] as? String != oldSnapshot.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: oldSnapshot.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.backups.appendingPathComponent("retired").path).count == 1)
        try await signer.restoreSignature(appURL: app, bundleIdentifier: identifier)
        #expect(try SignatureSnapshot.fingerprint(of: app) == reinstalled)
        #expect(await signer.verify(appURL: app) == .valid)
    }

    @Test("Corrupt snapshots leave the current application and recovery record untouched")
    func refusesCorruptSnapshot() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let app = workspace.root.appendingPathComponent("Chat.app")
        try makeBundle(at: app)
        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false)
        try await signer.sign(appURL: app, bundleIdentifier: nil)
        let snapshot = try #require(FileManager.default.contentsOfDirectory(at: workspace.backups, includingPropertiesForKeys: nil).first { $0.pathExtension == "app" })
        try Data("corrupt".utf8).write(to: snapshot.appendingPathComponent("Contents/MacOS/Fixture"))
        let before = try SignatureSnapshot.fingerprint(of: app)
        do {
            try await signer.restoreSignature(appURL: app, bundleIdentifier: "com.appports.tests.fixture")
            Issue.record("A corrupt snapshot must not be restored")
        } catch CodeSigner.SigningError.snapshotInvalid {}
        #expect(try SignatureSnapshot.fingerprint(of: app) == before)
        #expect(await signer.hasBackup(bundleIdentifier: "com.appports.tests.fixture"))
    }

    @Test("Failed exchanges preserve both application and backup and allow retry")
    func exchangeFailureIsRecoverable() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let app = workspace.root.appendingPathComponent("Chat.app")
        try makeBundle(at: app)
        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false)
        let failing = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false,
            exchangeApplications: { _, _ in throw CodeSigner.SigningError.atomicReplacementUnavailable })
        let original = try SignatureSnapshot.fingerprint(of: app)
        do {
            try await failing.sign(appURL: app, bundleIdentifier: nil)
            Issue.record("Forced sign exchange must fail")
        } catch CodeSigner.SigningError.atomicReplacementUnavailable {}
        #expect(try SignatureSnapshot.fingerprint(of: app) == original)
        try await signer.sign(appURL: app, bundleIdentifier: nil)
        let signed = try SignatureSnapshot.fingerprint(of: app)
        do {
            try await failing.restoreSignature(appURL: app, bundleIdentifier: "com.appports.tests.fixture")
            Issue.record("Forced restore exchange must fail")
        } catch CodeSigner.SigningError.atomicReplacementUnavailable {}
        #expect(try SignatureSnapshot.fingerprint(of: app) == signed)
        #expect(await signer.hasBackup(bundleIdentifier: "com.appports.tests.fixture"))
        try await signer.restoreSignature(appURL: app, bundleIdentifier: "com.appports.tests.fixture")
        #expect(try SignatureSnapshot.fingerprint(of: app) == original)
    }

    @Test("Legacy backups can be repaired using a matching original application")
    func restoresLegacyBackupFromOriginal() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let original = workspace.root.appendingPathComponent("Original.app")
        let app = workspace.root.appendingPathComponent("Installed.app")
        try makeBundle(at: original)
        let entitlements = try writeEntitlements(sandbox: true, in: workspace)
        try codesign(["--force", "--sign", "-", "--entitlements", entitlements.path, original.path])
        try SignatureSnapshot.copy(from: original, to: app)
        try codesign(["--force", "--sign", "-", app.path])
        try FileManager.default.createDirectory(at: workspace.backups, withIntermediateDirectories: true)
        let identifier = "com.appports.tests.fixture"
        try PropertyListSerialization.data(fromPropertyList: [
            "bundleIdentifier": identifier, "signingIdentity": "ad-hoc",
            "originalPath": app.path, "backupDate": Date()
        ], format: .xml, options: 0).write(to: workspace.backups.appendingPathComponent(identifier + ".plist"))
        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false)
        try await signer.restoreSignature(appURL: app, bundleIdentifier: identifier, originalApplication: original)
        #expect(try SignatureSnapshot.fingerprint(of: app) == SignatureSnapshot.fingerprint(of: original))
        #expect(CodeSigner.isSandboxed(at: app))
    }

    @Test("Different CodeSigner instances share a filesystem transaction lock")
    func preventsConcurrentSigningInstances() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let app = workspace.root.appendingPathComponent("Chat.app")
        try makeBundle(at: app)
        let lock = OperationLock(fileURL: workspace.backups.appendingPathComponent("signature-operation.lock"))
        try #require(lock.tryAcquire())
        defer { lock.release() }
        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false)
        let before = try SignatureSnapshot.fingerprint(of: app)
        do {
            try await signer.sign(appURL: app, bundleIdentifier: nil)
            Issue.record("Another signing transaction holds the lock")
        } catch CodeSigner.SigningError.operationInProgress {}
        #expect(try SignatureSnapshot.fingerprint(of: app) == before)
    }

    @Test("A selected original must match the installed app identity and version", arguments: ["CFBundleIdentifier", "CFBundleVersion"])
    func rejectsMismatchedOriginal(key: String) async throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let app = workspace.root.appendingPathComponent("Installed.app")
        let original = workspace.root.appendingPathComponent("Wrong.app")
        try makeBundle(at: app)
        let signer = CodeSigner(backupDirectoryURL: workspace.backups, allowAdministratorPrompt: false)
        try await signer.sign(appURL: app, bundleIdentifier: nil)
        try SignatureSnapshot.copy(from: app, to: original)
        let info = original.appendingPathComponent("Contents/Info.plist")
        var plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any])
        plist[key] = "wrong"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: info)
        try codesign(["--force", "--sign", "-", original.path])
        let before = try SignatureSnapshot.fingerprint(of: app)
        do {
            try await signer.restoreSignature(appURL: app, bundleIdentifier: "com.appports.tests.fixture", originalApplication: original)
            Issue.record("A different app or version must not replace the installed app")
        } catch CodeSigner.SigningError.originalApplicationMismatch {}
        #expect(try SignatureSnapshot.fingerprint(of: app) == before)
        #expect(await signer.hasBackup(bundleIdentifier: "com.appports.tests.fixture"))
    }

    @Test("Refreshing an installed re-sign script preserves the old script if the source is missing")
    func refreshInstalledResignScript() throws {
        let workspace = try Workspace()
        defer { workspace.cleanup() }
        let source = workspace.root.appendingPathComponent("Bundled.sh")
        let installed = workspace.root.appendingPathComponent("Installed.sh")
        try Data("old script".utf8).write(to: installed)
        #expect(throws: (any Error).self) {
            try AutoResignInstaller.synchronizeScript(from: source, to: installed)
        }
        #expect(try String(contentsOf: installed, encoding: .utf8) == "old script")
        try Data("new script".utf8).write(to: source)
        try AutoResignInstaller.synchronizeScript(from: source, to: installed)
        #expect(try String(contentsOf: installed, encoding: .utf8) == "new script")
        #expect(try FileManager.default.attributesOfItem(atPath: installed.path)[.posixPermissions] as? Int == 0o755)
    }

    private struct Workspace {
        let root: URL
        var backups: URL { root.appendingPathComponent("SignatureBackups") }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("AppPortsCodeSignerTests-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func cleanup() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
            process.arguments = ["-R", "nouchg", root.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil { process.waitUntilExit() }
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func readBackup(in workspace: Workspace, identifier: String) throws -> [String: Any] {
        let data = try Data(contentsOf: workspace.backups.appendingPathComponent(identifier + ".plist"))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func readAttribute(_ name: String, at url: URL) throws -> Data {
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        try #require(size >= 0)
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, 0) }
        try #require(read == size)
        return data
    }

    private func makeBundle(at url: URL, identifier: String = "com.appports.tests.fixture") throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let binary = try #require(Bundle.main.url(forResource: "StubLauncherBinary", withExtension: nil))
        let executable = url.appendingPathComponent("Contents/MacOS/Fixture")
        try fileManager.copyItem(at: binary, to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let info = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Fixture",
                    "CFBundlePackageType": "APPL", "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
    }

    private func writeEntitlements(sandbox: Bool, in workspace: Workspace) throws -> URL {
        let url = workspace.root.appendingPathComponent("\(UUID().uuidString)-entitlements.plist")
        try PropertyListSerialization.data(
            fromPropertyList: ["com.apple.security.app-sandbox": sandbox], format: .xml, options: 0
        ).write(to: url)
        return url
    }

    private func setFlags(_ flags: UInt32, at url: URL) throws {
        try #require(lchflags(url.path, flags) == 0)
    }

    private func fileFlags(at url: URL) throws -> UInt32 {
        var info = stat()
        try #require(lstat(url.path, &info) == 0)
        return info.st_flags
    }

    private func allFlags(in root: URL) throws -> [String: UInt32] {
        var result = [root.path: try fileFlags(at: root)]
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator {
            result[url.path] = try fileFlags(at: url)
        }
        return result
    }

    private func codesign(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "\(String(decoding: output, as: UTF8.self))")
    }
}

@Suite("Data migration signing workflow")
struct DataMigrationWorkflowTests {
    private let appURL = URL(fileURLWithPath: "/test/Chat.app")

    @Test("Migration waits for backup, and completion waits for signing")
    func awaitsEveryStage() async throws {
        let events = Events()
        let backupStarted = Gate()
        let finishBackup = Gate()
        let signingStarted = Gate()
        let finishSigning = Gate()
        let operation = Task {
            try await DataMigrationWorkflow.run(
                associatedAppURL: appURL,
                classicModeActive: true,
                autoResignEnabled: true,
                inspectSigningTarget: { DataMigrationWorkflow.SigningTarget(url: $0, isSandboxed: false) },
                stageChanged: { stage in
                    await events.append("stage-\(stage)")
                },
                backupSignature: { _ in
                    await events.append("backup-started")
                    await backupStarted.open()
                    await finishBackup.wait()
                    await events.append("backup-finished")
                },
                migrate: { await events.append("migrate") },
                resignApp: { url, sandboxedAppApproved in
                    #expect(url == appURL)
                    #expect(sandboxedAppApproved == false)
                    await events.append("signing-started")
                    await signingStarted.open()
                    await finishSigning.wait()
                    await events.append("signing-finished")
                }
            )
            await events.append("completed")
        }

        await backupStarted.wait()
        #expect(await events.values == ["stage-backingUpApplication", "backup-started"])
        await finishBackup.open()
        await signingStarted.wait()
        #expect(await events.values == ["stage-backingUpApplication", "backup-started", "backup-finished", "stage-migratingData", "migrate", "stage-resigningApplication", "signing-started"])
        await finishSigning.open()
        try await operation.value
        #expect(await events.values == ["stage-backingUpApplication", "backup-started", "backup-finished", "stage-migratingData", "migrate", "stage-resigningApplication", "signing-started", "signing-finished", "completed"])
    }

    enum Stage: CaseIterable { case backup, migration, signing }
    private enum TestFailure: Error { case expected }

    @Test("Failures propagate at the correct stage", arguments: Stage.allCases)
    func propagatesFailure(stage: Stage) async throws {
        let events = Events()
        do {
            try await DataMigrationWorkflow.run(
                associatedAppURL: appURL,
                classicModeActive: true,
                explicitSigningChoice: true,
                inspectSigningTarget: { DataMigrationWorkflow.SigningTarget(url: $0, isSandboxed: false) },
                backupSignature: { _ in
                    await events.append("backup")
                    if stage == .backup { throw TestFailure.expected }
                },
                migrate: {
                    await events.append("migration")
                    if stage == .migration { throw TestFailure.expected }
                },
                resignApp: { _, _ in
                    await events.append("signing")
                    throw TestFailure.expected
                }
            )
            Issue.record("Failure must reach the caller")
        } catch DataMigrationWorkflow.Failure.signingFailed(let underlying) {
            #expect(stage == .signing)
            #expect(underlying is TestFailure)
        } catch TestFailure.expected {
            #expect(stage != .signing)
        }
        let expectedEvents: [String]
        switch stage {
        case .backup: expectedEvents = ["backup"]
        case .migration: expectedEvents = ["backup", "migration"]
        case .signing: expectedEvents = ["backup", "migration", "signing"]
        }
        #expect(await events.values == expectedEvents)
    }

    @Test("Declining signing runs only the data migration")
    func respectsSigningChoice() async throws {
        let events = Events()
        try await DataMigrationWorkflow.run(
            associatedAppURL: appURL,
            classicModeActive: true,
            autoResignEnabled: true,
            explicitSigningChoice: false,
            inspectSigningTarget: { _ in
                Issue.record("Declining signing must not inspect the app signature")
                return .init(url: appURL, isSandboxed: false)
            },
            backupSignature: { _ in Issue.record("Backup must not run when signing is disabled") },
            migrate: { await events.append("migration") },
            resignApp: { _, _ in Issue.record("Signing must not run when disabled") }
        )
        #expect(await events.values == ["migration"])
    }

    @Test("An old automatic-signing preference cannot affect ordinary data outside classic mode", arguments: [nil, false, true] as [Bool?])
    func ignoresSigningOutsideClassicMode(explicitChoice: Bool?) async throws {
        let events = Events()
        try await DataMigrationWorkflow.run(
            associatedAppURL: appURL,
            classicModeActive: false,
            autoResignEnabled: true,
            explicitSigningChoice: explicitChoice,
            inspectSigningTarget: { _ in
                Issue.record("Ordinary Application Support migration must not query the app signature")
                return .init(url: appURL, isSandboxed: false)
            },
            stageChanged: { stage in
                #expect(stage == .migratingData)
                await events.append("migration-stage")
            },
            backupSignature: { _ in Issue.record("A hidden old preference must not back up the app") },
            migrate: { await events.append("migration") },
            resignApp: { _, _ in Issue.record("A hidden old preference must not re-sign the app") }
        )
        #expect(await events.values == ["migration-stage", "migration"])
    }

    @Test("A newly running app stops data movement even after a signature backup", arguments: [false, true])
    func validatesRunningStateImmediatelyBeforeMigration(signingEnabled: Bool) async throws {
        let events = Events()
        if !signingEnabled { await events.append("launched") }
        do {
            try await DataMigrationWorkflow.run(
                associatedAppURL: appURL,
                classicModeActive: true,
                explicitSigningChoice: signingEnabled,
                inspectSigningTarget: { DataMigrationWorkflow.SigningTarget(url: $0, isSandboxed: false) },
                validateBeforeMigration: {
                    let launched = await events.values.contains("launched")
                    let running: [AppRunningState.RunningApplication] = launched
                        ? [.init(bundleURL: appURL, bundleIdentifier: nil)] : []
                    if AppRunningState.isRunning(appURL: appURL, applications: running) {
                        throw AppMoverError.appIsRunning
                    }
                },
                backupSignature: { _ in await events.append("launched") },
                migrate: { await events.append("migration") },
                resignApp: { _, _ in await events.append("signing") }
            )
            Issue.record("The app started before data movement and must block migration")
        } catch AppMoverError.appIsRunning {}
        #expect(await events.values == ["launched"])
    }

    @Test("Classic mode still requires per-app approval before signing a sandboxed app")
    func requiresSandboxApproval() async throws {
        let target = DataMigrationWorkflow.SigningTarget(url: appURL, isSandboxed: true)
        let events = Events()
        do {
            try await DataMigrationWorkflow.run(
                associatedAppURL: appURL,
                classicModeActive: true,
                explicitSigningChoice: true,
                inspectSigningTarget: { _ in target },
                backupSignature: { _ in await events.append("backup") },
                migrate: { await events.append("migration") },
                resignApp: { _, _ in await events.append("signing") }
            )
            Issue.record("Classic mode must not replace per-app sandbox signing approval")
        } catch CodeSigner.SigningError.sandboxedApplication(let url) {
            #expect(url == target.url)
        }
        #expect(await events.values.isEmpty)
    }

    @Test("Matching sandbox approval signs only the resolved app after backup and migration")
    func signsExplicitlyApprovedTarget() async throws {
        let target = DataMigrationWorkflow.SigningTarget(
            url: URL(fileURLWithPath: "/test/External/Chat.app"), isSandboxed: true
        )
        let inspector = TargetInspector(target)
        let events = Events()
        try await DataMigrationWorkflow.run(
            associatedAppURL: appURL,
            classicModeActive: true,
            explicitSigningChoice: true,
            approvedSandboxedTarget: target,
            inspectSigningTarget: { await inspector.inspect(at: $0) },
            backupSignature: { url in
                #expect(url == target.url)
                await events.append("backup")
            },
            migrate: { await events.append("migration") },
            resignApp: { url, sandboxedAppApproved in
                #expect(url == target.url)
                #expect(sandboxedAppApproved)
                await events.append("signing")
            }
        )
        #expect(await events.values == ["backup", "migration", "signing"])
        #expect(await inspector.requestedURLs == [appURL, appURL, appURL])
    }

    @Test("Approval for a previous portal target cannot authorize another sandboxed app")
    func refusesRetargetedApproval() async throws {
        let approved = DataMigrationWorkflow.SigningTarget(
            url: URL(fileURLWithPath: "/test/External/Chat.app"), isSandboxed: true
        )
        let actual = DataMigrationWorkflow.SigningTarget(
            url: URL(fileURLWithPath: "/test/External/Other.app"), isSandboxed: true
        )
        let events = Events()
        do {
            try await DataMigrationWorkflow.run(
                associatedAppURL: appURL,
                classicModeActive: true,
                explicitSigningChoice: true,
                approvedSandboxedTarget: approved,
                inspectSigningTarget: { _ in actual },
                backupSignature: { _ in await events.append("backup") },
                migrate: { await events.append("migration") },
                resignApp: { _, _ in await events.append("signing") }
            )
            Issue.record("Approval belongs to the app named in the warning")
        } catch CodeSigner.SigningError.applicationChanged {}
        #expect(await events.values.isEmpty)
    }

    @Test("Target and sandbox state are rechecked after long operations", arguments: [Stage.backup, .migration], [false, true])
    func rechecksTarget(stage: Stage, changesSandboxStatus: Bool) async throws {
        let target = DataMigrationWorkflow.SigningTarget(
            url: URL(fileURLWithPath: "/test/External/Chat.app"), isSandboxed: false
        )
        let changed = DataMigrationWorkflow.SigningTarget(
            url: changesSandboxStatus ? target.url : URL(fileURLWithPath: "/test/External/Other.app"),
            isSandboxed: changesSandboxStatus
        )
        let inspector = TargetInspector(target)
        let events = Events()
        do {
            try await DataMigrationWorkflow.run(
                associatedAppURL: appURL,
                classicModeActive: true,
                explicitSigningChoice: true,
                inspectSigningTarget: { await inspector.inspect(at: $0) },
                backupSignature: { _ in
                    await events.append("backup")
                    if stage == .backup { await inspector.change(to: changed) }
                },
                migrate: {
                    await events.append("migration")
                    if stage == .migration { await inspector.change(to: changed) }
                },
                resignApp: { _, _ in await events.append("signing") }
            )
            Issue.record("A changed target must stop the remaining signing workflow")
        } catch DataMigrationWorkflow.Failure.signingFailed(let underlying) {
            #expect(stage == .migration)
            guard case CodeSigner.SigningError.applicationChanged = underlying else {
                Issue.record("Expected an application-changed error after migration")
                return
            }
        } catch CodeSigner.SigningError.applicationChanged {
            #expect(stage == .backup)
        }
        #expect(await events.values == (stage == .backup ? ["backup"] : ["backup", "migration"]))
    }

    private actor TargetInspector {
        private var target: DataMigrationWorkflow.SigningTarget
        private(set) var requestedURLs: [URL] = []

        init(_ target: DataMigrationWorkflow.SigningTarget) {
            self.target = target
        }

        func inspect(at url: URL) -> DataMigrationWorkflow.SigningTarget {
            requestedURLs.append(url)
            return target
        }

        func change(to target: DataMigrationWorkflow.SigningTarget) {
            self.target = target
        }
    }

    private actor Events {
        private(set) var values: [String] = []
        func append(_ value: String) { values.append(value) }
    }

    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }
}
