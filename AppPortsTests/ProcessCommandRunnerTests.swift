import Darwin
import Foundation
import Testing
@testable import AppPorts

@Suite("Process command completion")
struct ProcessCommandRunnerTests {
    @Test("Deadline includes ignored termination and inherited pipes", arguments: [
        "trap '' TERM; /bin/sleep 2", "(/bin/sleep 2; printf tail) & exit 7"
    ])
    func boundedDeadline(command: String) async throws {
        let start = Date()
        let result = try await ProcessCommandRunner().run(executable: "/bin/sh", arguments: ["-c", command], timeout: 0.1)
        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(start) < 1.5)
    }

    @Test("Concurrent deadlines remain bounded while children retain pipe writers")
    func concurrentDeadlines() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<16 {
                group.addTask {
                    let command = index.isMultiple(of: 2)
                        ? "trap '' TERM; /bin/sleep 2"
                        : "(/bin/sleep 2; printf tail) & exit 7"
                    let start = ProcessInfo.processInfo.systemUptime
                    let result = try await ProcessCommandRunner().run(
                        executable: "/bin/sh", arguments: ["-c", command], timeout: 0.1)
                    #expect(result.timedOut)
                    #expect(ProcessInfo.processInfo.systemUptime - start < 1.5)
                }
            }
            try await group.waitForAll()
        }
    }

    @Test("An expired deadline does not launch the command")
    func expiredDeadlineSkipsLaunch() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("process-deadline-\(UUID())")
        defer { try? FileManager.default.removeItem(at: marker) }
        let result = try await ProcessCommandRunner().run(executable: "/bin/sh",
            arguments: ["-c", "printf launched > \"$1\"", "runner-test", marker.path], timeout: 0)
        #expect(result.timedOut)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("Cancellation interrupts a child that ignores termination")
    func cancellationIsBounded() async throws {
        let task = Task {
            try await ProcessCommandRunner().run(executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; /bin/sleep 2"], timeout: 10)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let start = ProcessInfo.processInfo.systemUptime
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ProcessInfo.processInfo.systemUptime - start < 1.5)
    }

    @Test("Keeps stdout, stderr and the original exit status", arguments: [0, 23])
    func preservesOutputAndStatus(status: Int) async throws {
        let result = try await ProcessCommandRunner().run(
            executable: "/bin/sh",
            arguments: ["-c", "printf 'output\\n'; printf 'error\\n' >&2; exit \"$1\"", "runner-test", String(status)],
            timeout: 10
        )

        #expect(result.status == Int32(status))
        #expect(result.stdoutText == "output\n")
        #expect(result.stderrText == "error\n")
        #expect(!result.timedOut)
    }

    @Test("An empty command result still completes")
    func emptyOutput() async throws {
        let result = try await ProcessCommandRunner().run(executable: "/usr/bin/true", arguments: [], timeout: 10)

        #expect(result.status == 0)
        #expect(result.standardOutput.isEmpty)
        #expect(result.standardError.isEmpty)
        #expect(!result.timedOut)
    }

    @Test("Drains both streams beyond pipe capacity without truncation or deadlock")
    func largeConcurrentOutput() async throws {
        let result = try await ProcessCommandRunner().run(
            executable: "/bin/sh",
            arguments: ["-c", "/usr/bin/head -c 1048576 /dev/zero & /usr/bin/head -c 786432 /dev/zero >&2 & wait"],
            timeout: 15
        )

        #expect(result.status == 0)
        #expect(result.standardOutput == Data(repeating: 0, count: 1_048_576))
        #expect(result.standardError == Data(repeating: 0, count: 786_432))
        #expect(!result.timedOut)
        #expect(!result.outputWasTruncated)
    }

    @Test("Bounded capture drains both full streams and retains each diagnostic tail")
    func boundedOutputCapture() async throws {
        let command = """
        printf -v chunk '%0256d' 0
        for ((i=0; i<4096; i++)); do
          printf '%s' "$chunk"
          printf '%s' "$chunk" >&2
        done
        printf 'stdout-tail'
        printf 'stderr-tail' >&2
        """
        let result = try await ProcessCommandRunner(captureLimit: 4096).run(
            executable: "/bin/bash", arguments: ["-c", command], timeout: 15)
        #expect(result.status == 0)
        #expect(!result.timedOut)
        #expect(result.runningProcess == nil)
        #expect(result.outputWasTruncated)
        #expect(result.standardOutput.count == 4096)
        #expect(result.standardError.count == 4096)
        #expect(result.stdoutText.hasSuffix("stdout-tail"))
        #expect(result.stderrText.hasSuffix("stderr-tail"))
    }

    @Test("Timeout escalates an owned TERM-ignoring shell to confirmed exit")
    func timeoutConfirmsStoppedChild() async throws {
        let fixture = try ChildFixture()
        defer { fixture.remove() }
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await ProcessCommandRunner(captureLimit: 4096).run(
            executable: "/bin/bash", arguments: [fixture.script.path, fixture.pid.path], timeout: 0.5)
        let pidText = try String(contentsOf: fixture.pid, encoding: .utf8)
        let pid = try #require(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(result.timedOut)
        #expect(result.status == SIGKILL)
        #expect(result.runningProcess == nil)
        #expect(try !ProcessCommandRunner.isRunning(.init(processIdentifier: pid, startSeconds: nil, startMicroseconds: nil)))
        #expect(ProcessInfo.processInfo.systemUptime - started < 2)
    }

    @Test("Cancellation waits until its owned TERM-ignoring shell has exited")
    func cancellationConfirmsStoppedChild() async throws {
        let fixture = try ChildFixture()
        defer { fixture.remove() }
        let task = Task {
            try await ProcessCommandRunner(captureLimit: 4096).run(
                executable: "/bin/bash", arguments: [fixture.script.path, fixture.pid.path], timeout: 10)
        }
        defer { task.cancel() }
        let reference = try await fixture.waitForProcess()
        let cancelled = ProcessInfo.processInfo.systemUptime
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try !ProcessCommandRunner.isRunning(reference))
        #expect(ProcessInfo.processInfo.systemUptime - cancelled < 1.5)
    }

    @Test("Waits for trailing output after the immediate child exits")
    func trailingOutputAfterExit() async throws {
        // A descendant keeps the pipes open briefly after the shell exits. Completion
        // must wait for EOF on both streams, rather than return on process exit alone.
        let result = try await ProcessCommandRunner().run(
            executable: "/bin/sh",
            arguments: ["-c", "(sleep 0.1; printf 'tail-out'; printf 'tail-err' >&2) & exit 7"],
            timeout: 10
        )

        #expect(result.status == 7)
        #expect(result.stdoutText == "tail-out")
        #expect(result.stderrText == "tail-err")
        #expect(!result.timedOut)
    }

    @Test("A launch failure throws and does not prevent a later command")
    func launchFailure() async throws {
        let runner = ProcessCommandRunner()
        let nonexistent = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppPorts-missing-executable-\(UUID().uuidString)")

        await #expect(throws: (any Error).self) {
            try await runner.run(executable: nonexistent.path, arguments: [], timeout: 10)
        }

        let result = try await runner.run(executable: "/usr/bin/printf", arguments: ["recovered"], timeout: 10)
        #expect(result.status == 0)
        #expect(result.stdoutText == "recovered")
        #expect(result.standardError.isEmpty)
        #expect(!result.timedOut)
    }

    @Test("Timeout terminates a running process and completes the result")
    func timeout() async throws {
        let result = try await ProcessCommandRunner().run(
            executable: "/bin/sleep", arguments: ["30"], timeout: 0.2
        )

        #expect(result.timedOut)
        #expect(result.status != 0)
        #expect(result.standardOutput.isEmpty)
        #expect(result.standardError.isEmpty)
    }

    @Test("Concurrent commands keep their outputs and exit statuses separate")
    func concurrentCommands() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<16 {
                group.addTask {
                    let result = try await ProcessCommandRunner().run(
                        executable: "/bin/sh",
                        arguments: ["-c", "printf 'out:%s' \"$1\"; printf 'err:%s' \"$1\" >&2; exit \"$1\"",
                                    "runner-test", String(index)],
                        timeout: 10
                    )
                    #expect(result.status == Int32(index))
                    #expect(result.stdoutText == "out:\(index)")
                    #expect(result.stderrText == "err:\(index)")
                    #expect(!result.timedOut)
                }
            }
            try await group.waitForAll()
        }
    }

    private struct ChildFixture {
        let root: URL
        let script: URL
        let pid: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPorts-owned-command-\(UUID().uuidString)")
            script = root.appendingPathComponent("ignore-term.sh")
            pid = root.appendingPathComponent("child.pid")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // Bash builtins only: no descendant survives if the shell is killed.
            try "trap '' TERM\nprintf '%s\\n' \"$$\" > \"$1\"\nwhile :; do :; done\n".write(
                to: script, atomically: true, encoding: .utf8)
        }

        func waitForProcess() async throws -> ShellCommandProcessReference {
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while ProcessInfo.processInfo.systemUptime < deadline {
                if let text = try? String(contentsOf: pid, encoding: .utf8),
                   let identifier = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    var info = proc_bsdinfo()
                    let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
                    if proc_pidinfo(identifier, PROC_PIDTBSDINFO, 0, &info, size) == size {
                        return .init(processIdentifier: identifier, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
                    }
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw CocoaError(.fileReadUnknown)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
