import Foundation
import Testing
@testable import AppPorts

struct DataMigrationBackupCleanupTests {
    enum FailurePoint: CaseIterable, Sendable {
        case backup, postBackupInspection, validation, migration, preSigningInspection, signing

        var isSigningFailure: Bool { self == .preSigningInspection || self == .signing }

        var expectedEvents: [String] {
            switch self {
            case .backup: return ["inspect-1", "backup", "cleanup"]
            case .postBackupInspection: return ["inspect-1", "backup", "inspect-2", "cleanup"]
            case .validation: return ["inspect-1", "backup", "inspect-2", "validate", "cleanup"]
            case .migration: return ["inspect-1", "backup", "inspect-2", "validate", "migrate", "cleanup"]
            case .preSigningInspection: return ["inspect-1", "backup", "inspect-2", "validate", "migrate", "inspect-3", "cleanup"]
            case .signing: return ["inspect-1", "backup", "inspect-2", "validate", "migrate", "inspect-3", "sign", "cleanup"]
            }
        }
    }

    @Test("Every failure after backup starts cleans the resolved target and preserves the original error",
          arguments: FailurePoint.allCases, [false, true])
    func cleansAfterFailure(point: FailurePoint, cleanupFails: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let events = Events()
        let inspections = Counter()

        do {
            try await DataMigrationWorkflow.run(
                associatedAppURL: fixture.portal,
                classicModeActive: true,
                explicitSigningChoice: true,
                inspectSigningTarget: { url in
                    #expect(url == fixture.portal)
                    let count = await inspections.next()
                    await events.append("inspect-\(count)")
                    if point == .postBackupInspection && count == 2 || point == .preSigningInspection && count == 3 {
                        throw TestFailure.operation
                    }
                    return fixture.target
                },
                validateBeforeMigration: {
                    await events.append("validate")
                    if point == .validation { throw TestFailure.operation }
                },
                backupSignature: { url in
                    #expect(url == fixture.target.url)
                    await events.append("backup")
                    try fixture.writeBackup()
                    if point == .backup { throw TestFailure.operation }
                },
                migrate: {
                    await events.append("migrate")
                    if point == .migration { throw TestFailure.operation }
                },
                resignApp: { url, _ in
                    #expect(url == fixture.target.url)
                    await events.append("sign")
                    if point == .signing { throw TestFailure.operation }
                },
                cleanupUnusedBackup: { url in
                    #expect(url == fixture.target.url)
                    #expect(fixture.hasBackup)
                    await events.append("cleanup")
                    if cleanupFails { throw TestFailure.cleanup }
                    try fixture.removeBackup()
                }
            )
            Issue.record("The original workflow failure must reach the caller")
        } catch DataMigrationWorkflow.Failure.signingFailed(let underlying) {
            #expect(point.isSigningFailure)
            #expect(underlying as? TestFailure == .operation)
        } catch let error as TestFailure {
            #expect(!point.isSigningFailure)
            #expect(error == .operation)
        }

        #expect(await events.values == point.expectedEvents)
        #expect(fixture.hasBackup == cleanupFails)
    }

    @Test("A retargeted portal only cleans the application that was backed up", arguments: [false, true])
    func keepsOriginalCleanupTarget(retargetAfterMigration: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let events = Events()
        let inspections = Counter()

        do {
            try await DataMigrationWorkflow.run(
                associatedAppURL: fixture.portal,
                classicModeActive: true,
                explicitSigningChoice: true,
                inspectSigningTarget: { _ in
                    let count = await inspections.next()
                    return count >= (retargetAfterMigration ? 3 : 2) ? fixture.otherTarget : fixture.target
                },
                backupSignature: { url in
                    #expect(url == fixture.target.url)
                    await events.append("backup")
                    try fixture.writeBackup()
                },
                migrate: { await events.append("migrate") },
                resignApp: { _, _ in Issue.record("The changed application must not be signed") },
                cleanupUnusedBackup: { url in
                    #expect(url == fixture.target.url)
                    #expect(url != fixture.portal && url != fixture.otherTarget.url)
                    await events.append("cleanup")
                    try fixture.removeBackup()
                }
            )
            Issue.record("A changed application must stop the workflow")
        } catch DataMigrationWorkflow.Failure.signingFailed(let underlying) {
            #expect(retargetAfterMigration)
            guard case CodeSigner.SigningError.applicationChanged = underlying else {
                Issue.record("The signing failure must preserve the target-change error")
                return
            }
        } catch CodeSigner.SigningError.applicationChanged {
            #expect(!retargetAfterMigration)
        }

        #expect(await events.values == (retargetAfterMigration ? ["backup", "migrate", "cleanup"] : ["backup", "cleanup"]))
        #expect(!fixture.hasBackup)
    }

    @Test("Cleanup waits for signing to finish before workflow completion")
    func doesNotCleanBeforeSigningFinishes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let events = Events()
        let signingStarted = Gate()
        let finishSigning = Gate()
        let operation = Task {
            do {
                let warning = try await DataMigrationWorkflow.run(
                    associatedAppURL: fixture.portal,
                    classicModeActive: true,
                    explicitSigningChoice: true,
                    inspectSigningTarget: { _ in fixture.target },
                    backupSignature: { _ in
                        try fixture.writeBackup()
                        await events.append("backup")
                    },
                    migrate: { await events.append("migrate") },
                    resignApp: { _, _ in
                        #expect(fixture.hasBackup)
                        await events.append("sign-start")
                        await signingStarted.open()
                        await finishSigning.wait()
                        #expect(fixture.hasBackup)
                        await events.append("sign-finish")
                    },
                    cleanupUnusedBackup: { url in
                        #expect(url == fixture.target.url)
                        #expect(await events.values.last == "sign-finish")
                        try fixture.removeBackup()
                        await events.append("cleanup")
                    }
                )
                await events.append("completed")
                await signingStarted.open()
                return warning
            } catch {
                await signingStarted.open()
                throw error
            }
        }

        await signingStarted.wait()
        #expect(await events.values == ["backup", "migrate", "sign-start"])
        #expect(fixture.hasBackup)
        await finishSigning.open()
        #expect(try await operation.value == nil)
        #expect(await events.values == ["backup", "migrate", "sign-start", "sign-finish", "cleanup", "completed"])
        #expect(!fixture.hasBackup)
    }

    @Test("Disabled signing cleans unused history only after successful migration", arguments: [false, true])
    func cleansHistoryWithoutSigning(classicModeActive: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeBackup()
        let events = Events()

        let warning = try await DataMigrationWorkflow.run(
            associatedAppURL: fixture.portal,
            classicModeActive: classicModeActive,
            autoResignEnabled: true,
            explicitSigningChoice: false,
            inspectSigningTarget: { _ in throw TestFailure.unexpectedCallback },
            backupSignature: { _ in throw TestFailure.unexpectedCallback },
            migrate: {
                #expect(fixture.hasBackup)
                await events.append("migrate")
            },
            resignApp: { _, _ in throw TestFailure.unexpectedCallback },
            cleanupUnusedBackup: { url in
                #expect(url == fixture.portal)
                await events.append("cleanup")
                try fixture.removeBackup()
            }
        )

        #expect(warning == nil)
        #expect(await events.values == ["migrate", "cleanup"])
        #expect(!fixture.hasBackup)
    }

    @Test("Successful work returns a cleanup warning without becoming a failure", arguments: [false, true])
    func cleanupFailureReturnsWarning(signingEnabled: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeBackup()
        let events = Events()

        let warning = try await DataMigrationWorkflow.run(
            associatedAppURL: fixture.portal,
            classicModeActive: true,
            explicitSigningChoice: signingEnabled,
            inspectSigningTarget: { _ in fixture.target },
            backupSignature: { _ in await events.append("backup") },
            migrate: { await events.append("migrate") },
            resignApp: { _, _ in await events.append("sign") },
            cleanupUnusedBackup: { url in
                #expect(url == (signingEnabled ? fixture.target.url : fixture.portal))
                await events.append("cleanup")
                throw TestFailure.cleanup
            }
        )

        #expect(warning == TestFailure.cleanup.localizedDescription)
        #expect(await events.values == (signingEnabled ? ["backup", "migrate", "sign", "cleanup"] : ["migrate", "cleanup"]))
        #expect(fixture.hasBackup)
    }

    @Test("No associated application means no backup cleanup", arguments: [false, true])
    func doesNotCleanWithoutApplication(signingEnabled: Bool) async throws {
        let events = Events()
        let warning = try await DataMigrationWorkflow.run(
            associatedAppURL: nil,
            classicModeActive: true,
            explicitSigningChoice: signingEnabled,
            inspectSigningTarget: { _ in throw TestFailure.unexpectedCallback },
            backupSignature: { _ in throw TestFailure.unexpectedCallback },
            migrate: { await events.append("migrate") },
            resignApp: { _, _ in throw TestFailure.unexpectedCallback },
            cleanupUnusedBackup: { _ in
                Issue.record("There is no application backup target to clean")
                await events.append("cleanup")
            }
        )
        #expect(warning == nil)
        #expect(await events.values == ["migrate"])
    }

    enum PreBackupFailure: CaseIterable, Sendable { case inspection, changedApproval, sandboxApproval }

    @Test("Failures before backup starts preserve unrelated history", arguments: PreBackupFailure.allCases)
    func doesNotCleanBeforeBackupIsInvolved(point: PreBackupFailure) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeBackup()
        let events = Events()

        await #expect(throws: (any Error).self) {
            try await DataMigrationWorkflow.run(
                associatedAppURL: fixture.portal,
                classicModeActive: true,
                explicitSigningChoice: true,
                approvedSandboxedTarget: point == .changedApproval ? fixture.otherTarget : nil,
                inspectSigningTarget: { _ in
                    await events.append("inspect")
                    if point == .inspection { throw TestFailure.operation }
                    return .init(url: fixture.target.url, isSandboxed: point == .sandboxApproval)
                },
                backupSignature: { _ in await events.append("backup") },
                migrate: { await events.append("migrate") },
                resignApp: { _, _ in await events.append("sign") },
                cleanupUnusedBackup: { _ in
                    await events.append("cleanup")
                    try fixture.removeBackup()
                }
            )
        }

        #expect(await events.values == ["inspect"])
        #expect(fixture.hasBackup)
    }

    private enum TestFailure: LocalizedError, Equatable {
        case operation, cleanup, unexpectedCallback
        var errorDescription: String? {
            switch self {
            case .operation: return "Original workflow failure"
            case .cleanup: return "Unused backup cleanup failed"
            case .unexpectedCallback: return "Unexpected callback"
            }
        }
    }

    private struct Fixture: Sendable {
        let root: URL
        let portal: URL
        let target: DataMigrationWorkflow.SigningTarget
        let otherTarget: DataMigrationWorkflow.SigningTarget
        let backup: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("DataMigrationBackupCleanupTests-\(UUID())")
                .resolvingSymlinksInPath()
            portal = root.appendingPathComponent("Portal.app")
            target = .init(url: root.appendingPathComponent("Resolved.app"), isSandboxed: false)
            otherTarget = .init(url: root.appendingPathComponent("Other.app"), isSandboxed: false)
            backup = root.appendingPathComponent("unused-backup")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        var hasBackup: Bool { FileManager.default.fileExists(atPath: backup.path) }
        func writeBackup() throws { try Data("Original application backup".utf8).write(to: backup) }
        func removeBackup() throws { try FileManager.default.removeItem(at: backup) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private actor Events {
        private(set) var values: [String] = []
        func append(_ value: String) { values.append(value) }
    }

    private actor Counter {
        private var value = 0
        func next() -> Int { value += 1; return value }
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
