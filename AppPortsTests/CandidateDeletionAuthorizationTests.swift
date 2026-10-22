import Darwin
import Foundation
import Testing
@testable import AppPorts

struct CandidateDeletionAuthorizationTests {
    @Test("Authorization rechecks the volume, ledger and source after the prompt", arguments: [
        "unchanged", "source-write", "mounted", "mount-missing", "mount-type", "volume-replaced", "device-replaced", "ledger-changed", "source-replaced", "parent-replaced", "candidate-replaced"
    ], [false, true])
    func postAuthorizationValidation(_ change: String, unmount: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPorts-auth-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source ' $(should-not-run)")
        let parent = root.appendingPathComponent("Mounts")
        for url in [source, parent] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        let candidate = parent.appendingPathComponent("Candidate")
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
        let ledger = root.appendingPathComponent("records.plist")
        try Data("original journal".utf8).write(to: ledger)
        let evidence = try DiskUtility.DeletionAuthorizationEvidence(ledger: ledger, directories: unmount ? [source, parent, candidate] : [source, parent])
        let uuid = "01234567-89AB-CDEF-0123-456789ABCDEF"
        let diskInfo = root.appendingPathComponent("disk-info.plist")
        let deleted = root.appendingPathComponent("deleted")
        let fakeDisk = root.appendingPathComponent("fake-diskutil")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let replacementCommand = quote(fakeDisk.path)
        try """
        #!/bin/sh
        set -eu
        if [ "$1" = info ]; then
            /bin/cat \(quote(diskInfo.path))
        elif [ "$1" = apfs ] && [ "$2" = deleteVolume ]; then
            /usr/bin/printf '%s' "$3" > \(quote(deleted.path))
        elif [ "$1" = unmount ]; then
            /usr/bin/printf '%s' "$2" > \(quote(deleted.path))
        else
            exit 79
        fi
        """.write(to: fakeDisk, atomically: true, encoding: .utf8)
        try #require(chmod(fakeDisk.path, 0o700) == 0)
        let runner = PrivilegeFailureRunner(uuid: uuid, mountedAt: unmount ? candidate.path : "", unmount: unmount)
        let disk = DiskUtility(runner: runner, administratorRunner: { executable, arguments in
            // This callback simulates the authorization wait. No actual admin
            // request or native disk command is permitted by this test runner.
            #expect(executable == "/bin/sh")
            #expect(arguments.first == "-c")
            var info: [String: Any] = ["DeviceIdentifier": "disk7s9", "VolumeUUID": uuid,
                                       "FilesystemType": "apfs", "MountPoint": unmount ? candidate.path : ""]
            if change == "mounted" { info["MountPoint"] = parent.appendingPathComponent("Elsewhere").path }
            if change == "mount-missing" { info.removeValue(forKey: "MountPoint") }
            if change == "mount-type" { info["MountPoint"] = false }
            if change == "volume-replaced" { info["VolumeUUID"] = "OTHER-VOLUME" }
            if change == "device-replaced" { info["DeviceIdentifier"] = "disk7s10" }
            if change == "ledger-changed" { try Data("new reference or user decision".utf8).write(to: ledger) }
            if change == "source-write" { try Data("latest source bytes".utf8).write(to: source.appendingPathComponent("new.txt")) }
            if change == "source-replaced" || change == "parent-replaced" {
                let path = change == "source-replaced" ? source : parent
                try FileManager.default.moveItem(at: path, to: root.appendingPathComponent("saved"))
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
            }
            if change == "candidate-replaced" {
                try FileManager.default.moveItem(at: candidate, to: root.appendingPathComponent("saved-candidate"))
                try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
            }
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: diskInfo)
            let actual = try #require(arguments.last)
            #expect(actual.contains("'/usr/sbin/diskutil'"))
            let safeScript = actual.replacingOccurrences(of: "'/usr/sbin/diskutil'", with: replacementCommand)
            try #require(!safeScript.contains("/usr/sbin/diskutil"))
            return try ProcessCommandRunner.runSynchronously(executable: "/bin/sh", arguments: ["-c", safeScript], timeout: 5)
        })
        func performMutation() async throws {
            if unmount { try await disk.unmountCandidate(uuid, at: candidate, authorizationEvidence: evidence, beforeUnmount: {}) }
            else { try await disk.deleteAPFSVolume(uuid, requireUnmounted: true, authorizationEvidence: evidence) }
        }
        if change == "unchanged" || change == "source-write" || change == "candidate-replaced" && !unmount {
            try await performMutation()
            #expect(try String(contentsOf: deleted, encoding: .utf8) == "disk7s9")
        } else {
            await #expect(throws: (any Error).self) {
                try await performMutation()
            }
            #expect(!FileManager.default.fileExists(atPath: deleted.path))
        }
        #expect(runner.deleteAttempts == 1)
    }

    private final class PrivilegeFailureRunner: ShellCommandRunning, @unchecked Sendable {
        let uuid: String
        let mountedAt: String
        let unmount: Bool
        private let lock = NSLock()
        private var deletes = 0
        var deleteAttempts: Int { lock.lock(); defer { lock.unlock() }; return deletes }
        init(uuid: String, mountedAt: String, unmount: Bool) { self.uuid = uuid; self.mountedAt = mountedAt; self.unmount = unmount }
        private func recordDelete() { lock.lock(); deletes += 1; lock.unlock() }
        func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
            if arguments == (unmount ? ["unmount", "disk7s9"] : ["apfs", "deleteVolume", "disk7s9"]) {
                recordDelete()
                return .init(status: 1, standardOutput: Data(), standardError: Data("kDAReturnNotPrivileged".utf8), timedOut: false)
            }
            guard arguments == ["info", "-plist", uuid] || arguments == ["info", "-plist", "disk7s9"] else {
                throw POSIXError(.EINVAL)
            }
            let data = try PropertyListSerialization.data(fromPropertyList: ["DeviceIdentifier": "disk7s9",
                "VolumeUUID": uuid, "FilesystemType": "apfs", "MountPoint": mountedAt], format: .xml, options: 0)
            return .init(status: 0, standardOutput: data, standardError: Data(), timedOut: false)
        }
    }
}
