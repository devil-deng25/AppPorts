import CryptoKit
import Darwin
import XCTest
@testable import AppPorts

/// Opt-in compatibility check against the unmodified pre-v3 executable built
/// from the frozen Git baseline. The old process has no access to user data,
/// cannot launch helpers, and cannot write outside its disposable directory.
final class LegacyBinaryAdmissionTests: XCTestCase {
    func testRealLegacyExecutableBlocksNewWriterUntilItExits() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["APPPORTS_LEGACY_EXECUTABLE"],
              let expectedHash = environment["APPPORTS_LEGACY_EXECUTABLE_SHA256"],
              let expectedLibraryHash = environment["APPPORTS_LEGACY_LIBRARY_SHA256"],
              let outputPath = environment["APPPORTS_LEGACY_VALIDATION_OUTPUT"] else {
            throw XCTSkip("Requires a separately built, hashed pre-v3 AppPorts executable")
        }
        let executable = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let digest = SHA256.hash(data: try Data(contentsOf: executable)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, expectedHash)
        guard digest == expectedHash else { return }
        // Xcode Debug builds put the implementation in this library; hashing
        // only the small executable would attest just the loader stub.
        let library = executable.deletingLastPathComponent().appendingPathComponent("AppPorts.debug.dylib")
        let libraryHandle = try FileHandle(forReadingFrom: library)
        defer { try? libraryHandle.close() }
        var libraryHasher = SHA256()
        while let bytes = try libraryHandle.read(upToCount: 1_048_576), !bytes.isEmpty { libraryHasher.update(data: bytes) }
        let libraryDigest = libraryHasher.finalize().map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(libraryDigest, expectedLibraryHash)
        guard libraryDigest == expectedLibraryHash else { return }
        XCTAssertEqual(executable.lastPathComponent, "AppPorts")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsLegacyAdmission-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        let home = root.appendingPathComponent("Home")
        let temporary = root.appendingPathComponent("tmp")
        let output = URL(fileURLWithPath: outputPath)
        for directory in [home, temporary, output] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        func literal(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        func posixPath(_ url: URL) throws -> String {
            guard let resolved = realpath(url.path, nil) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        // Foundation intentionally presents /private/tmp as /tmp in some
        // file URLs. The sandbox checks the kernel spelling, so an allowlist
        // containing only that display path rejects the initial exec itself.
        // Accept aliases only after proving they are this same executable.
        let kernelExecutablePath = try posixPath(executable)
        let executableInfo = try SignatureSnapshot.info(at: executable)
        let executablePaths = Array(Set([path, executable.path, kernelExecutablePath,
            "/System/Volumes/Data" + kernelExecutablePath])).filter { candidate in
                guard let info = try? SignatureSnapshot.info(at: URL(fileURLWithPath: candidate)) else { return false }
                return info.st_dev == executableInfo.st_dev && info.st_ino == executableInfo.st_ino
            }.sorted()
        let allowedExecutablePaths = executablePaths.map { "(literal \(literal($0)))" }.joined(separator: " ")
        let kernelRootPath = try posixPath(root)
        let allowedWritePaths = Set([root.path, kernelRootPath]).sorted()
            .map { "(subpath \(literal($0)))" }.joined(separator: " ")
        let policy = """
        (version 1)
        (allow default)
        (deny network*)
        (deny appleevent-send)
        (deny process-fork)
        (deny process-exec (require-not (require-any \(allowedExecutablePaths))))
        (deny file-read* file-write* (subpath \(literal(NSHomeDirectory()))))
        (deny file-write* (require-not (require-any \(allowedWritePaths))))
        (deny mach-lookup (global-name "com.apple.cfprefsd.xpc.agent") (global-name "com.apple.cfprefsd.xpc.daemon"))
        """
        let policyURL = root.appendingPathComponent("legacy.sb")
        try policy.write(to: policyURL, atomically: true, encoding: .utf8)
        try policy.write(to: output.appendingPathComponent("legacy-isolation.sb"), atomically: true, encoding: .utf8)
        let logURL = output.appendingPathComponent("legacy-process.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: logURL.path, contents: nil))
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-f", policyURL.path, kernelExecutablePath]
        process.environment = ["CFFIXED_USER_HOME": home.path, "TMPDIR": temporary.path,
            "XCTestConfigurationFilePath": root.appendingPathComponent("isolation-only.xctestconfiguration").path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        try process.run()
        defer {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        let current = try WriterAdmission.currentProcessIdentity()
        var observed: WriterProcessIdentity?
        for _ in 0..<100 {
            observed = try WriterAdmission.runningAppPortsProcesses().first {
                $0.processID == process.processIdentifier && executablePaths.contains($0.executablePath)
            }
            if observed != nil || !process.isRunning { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let legacy = try XCTUnwrap(observed, "The real legacy process must be observed through libproc; see legacy-process.log")
        // Give startup guards a chance to run; do not count a loader that
        // exits immediately as a live incompatible instance.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(process.isRunning)
        let dataDirectory = root.appendingPathComponent("isolated-data")
        let admission = WriterAdmission(dataDirectory: dataDirectory, processSnapshot: {
            try WriterAdmission.runningAppPortsProcesses().filter {
                [current.processID, legacy.processID].contains($0.processID)
            }
        })
        try admission.registerCurrentProcess()
        let sentinel = dataDirectory.appendingPathComponent("records.plist")
        let original = Data("isolated data must remain unchanged".utf8)
        try original.write(to: sentinel)
        let lock = OperationLock(fileURL: dataDirectory.appendingPathComponent("operation.lock"),
            writerAdmissionCheck: { try admission.checkCurrentWriters() })
        let rejectedLegacy = !lock.tryAcquire()
        XCTAssertTrue(rejectedLegacy)
        XCTAssertTrue(lock.admissionFailureReason?.contains(String(legacy.processID)) == true)
        XCTAssertEqual(try Data(contentsOf: sentinel), original)

        process.terminate()
        for _ in 0..<100 {
            if !process.isRunning { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(process.isRunning)
        guard !process.isRunning else { return }
        process.waitUntilExit()
        let admittedAfterExit = lock.tryAcquire()
        XCTAssertTrue(admittedAfterExit)
        lock.release()
        XCTAssertEqual(try Data(contentsOf: sentinel), original)
        let evidence: [String: Any] = ["legacyExecutable": executable.path, "legacySHA256": digest,
            "legacyImplementationLibrary": library.path, "legacyImplementationSHA256": libraryDigest,
            "legacyPID": legacy.processID, "sourceRevision": "80a99ff78749af08d348d1d9e88edb64d519b4ed",
            "liveLegacyRejected": rejectedLegacy, "admittedAfterExit": admittedAfterExit,
            "legacyExited": !process.isRunning, "recordUnchanged": try Data(contentsOf: sentinel) == original,
            "scope": "Real pre-v3 binary presence blocks a new writer; no old migration or older-OS execution was tested"]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("legacy-admission-result.json"), options: .atomic)
    }
}
