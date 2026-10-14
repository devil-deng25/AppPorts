import Darwin
import Foundation
import Testing
@testable import AppPorts

struct DiskUtilityOwnershipTests {
    private let mountPoint = URL(fileURLWithPath: "/synthetic/WeChat's data")
    private let originalFlags = UInt32(MNT_IGNORE_OWNERSHIP | MNT_NODEV | MNT_NOSUID | MNT_DONTBROWSE)

    @Test("A denied APFS ownership update retries the same command with administrator authorization", arguments: [false, true])
    func retriesPermissionDeniedOwnershipUpdate(enabled: Bool) async throws {
        let runner = OwnershipCommandRecorder(status: 77, output: "mount_apfs: volume could not be mounted: Operation not permitted")
        let administrator = OwnershipCommandRecorder()
        let disk = DiskUtility(runner: runner, administratorRunner: { try administrator.execute($0, $1) })

        try await disk.setOwnershipForRestore(mountPoint: mountPoint, originalFlags: originalFlags, enabled: enabled)

        let calls = runner.calls
        try #require(calls.count == 1)
        let invocation = try #require(calls.first)
        #expect(invocation.executable == DiskUtility.mountPath)
        #expect(invocation.arguments == ["-u", "-o", "nobrowse,nodev,nosuid," + (enabled ? "owners" : "noowners"), mountPoint.path])
        #expect(administrator.calls == [invocation])
    }

    @Test("A background ownership update reports that interactive authorization is required")
    func unavailableAdministratorIsReported() async throws {
        let runner = OwnershipCommandRecorder(status: 77, output: "Operation not permitted")
        let disk = DiskUtility(runner: runner, administratorRunner: nil)

        do {
            try await disk.setOwnershipForRestore(mountPoint: mountPoint, originalFlags: originalFlags, enabled: true)
            Issue.record("The ownership update must require authorization")
        } catch DiskUtility.Failure.privilegeRequired(let command) {
            #expect(command.contains(mountPoint.path))
        }
        #expect(runner.calls.count == 1)
    }

    @Test("Cancelling administrator authorization preserves the cancellation error")
    func administratorCancellationIsReported() async throws {
        let runner = OwnershipCommandRecorder(status: 77, output: "Operation not permitted")
        let administrator = OwnershipCommandRecorder(error: DiskUtility.Failure.administratorPromptCancelled(command: "mount"))
        let disk = DiskUtility(runner: runner, administratorRunner: { try administrator.execute($0, $1) })

        do {
            try await disk.setOwnershipForRestore(mountPoint: mountPoint, originalFlags: originalFlags, enabled: true)
            Issue.record("The ownership update must preserve cancelled authorization")
        } catch DiskUtility.Failure.administratorPromptCancelled { }
        #expect(runner.calls.count == 1)
        #expect(administrator.calls == runner.calls)
    }

    @Test("Successful, busy, and timed-out ownership commands never request administrator authorization",
          arguments: ["success", "busy", "timeout"])
    func doesNotElevateUnrelatedResults(_ scenario: String) async throws {
        let runner = OwnershipCommandRecorder(status: scenario == "success" ? 0 : scenario == "timeout" ? 77 : 1,
            output: scenario == "busy" ? "Resource busy" : "Operation not permitted", timedOut: scenario == "timeout")
        let administrator = OwnershipCommandRecorder()
        let disk = DiskUtility(runner: runner, administratorRunner: { try administrator.execute($0, $1) })

        do {
            try await disk.setOwnershipForRestore(mountPoint: mountPoint, originalFlags: originalFlags, enabled: true)
            #expect(scenario == "success")
        } catch DiskUtility.Failure.timedOut {
            #expect(scenario == "timeout")
        } catch DiskUtility.Failure.commandFailed(_, let output) {
            #expect(scenario == "busy")
            #expect(output == "Resource busy")
        }
        #expect(runner.calls.count == 1)
        #expect(administrator.calls.isEmpty)
    }

    @Test("A failed or timed-out administrator update is reported without another retry", arguments: [false, true])
    func administratorFailureIsReported(timedOut: Bool) async throws {
        let runner = OwnershipCommandRecorder(status: 77, output: "Operation not permitted")
        let administrator = OwnershipCommandRecorder(status: timedOut ? 0 : 77,
            output: "Administrator update failed", timedOut: timedOut)
        let disk = DiskUtility(runner: runner, administratorRunner: { try administrator.execute($0, $1) })

        do {
            try await disk.setOwnershipForRestore(mountPoint: mountPoint, originalFlags: originalFlags, enabled: true)
            Issue.record("A failed administrator command must not succeed")
        } catch DiskUtility.Failure.timedOut {
            #expect(timedOut)
        } catch DiskUtility.Failure.commandFailed(_, let output) {
            #expect(!timedOut)
            #expect(output == "Administrator update failed")
        }
        #expect(runner.calls.count == 1)
        #expect(administrator.calls == runner.calls)
    }
}

private final class OwnershipCommandRecorder: ShellCommandRunning, @unchecked Sendable {
    struct Invocation: Equatable, Sendable {
        let executable: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private var invocations: [Invocation] = []
    private let result: ShellCommandResult
    private let error: Error?

    init(status: Int32 = 0, output: String = "", timedOut: Bool = false, error: Error? = nil) {
        result = ShellCommandResult(status: status, standardOutput: Data(), standardError: Data(output.utf8), timedOut: timedOut)
        self.error = error
    }

    var calls: [Invocation] {
        lock.lock(); defer { lock.unlock() }
        return invocations
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
        try execute(executable, arguments)
    }

    func execute(_ executable: String, _ arguments: [String]) throws -> ShellCommandResult {
        lock.lock(); defer { lock.unlock() }
        invocations.append(.init(executable: executable, arguments: arguments))
        if let error { throw error }
        return result
    }
}
