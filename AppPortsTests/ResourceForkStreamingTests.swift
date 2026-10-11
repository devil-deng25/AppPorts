import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import AppPorts

/// These fixtures are private temporary files. The large test also samples
/// process RSS; run this suite alone for attributable resource measurements.
final class ResourceForkStreamingTests: XCTestCase {
    private let forkName = "com.apple.ResourceFork"
    private let chunkBytes = 1_048_576

    func testFingerprintKeepsHistoricalRawAttributeFieldFormat() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Synthetic.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let payload = contents.appendingPathComponent("payload")
        try Data("Synthetic payload".utf8).write(to: payload)
        try setAttribute(forkName, data: Data((0..<65_539).map { UInt8(truncatingIfNeeded: $0 &* 31) }), at: payload)
        try setAttribute("com.apple.cs.CodeDirectory", data: Data("Synthetic signature attribute".utf8), at: payload)
        var finder = Data(repeating: 0, count: 32)
        finder.replaceSubrange(0..<4, with: Data("TEXT".utf8))
        try setAttribute("com.apple.FinderInfo", data: finder, at: payload)
        // Fix the fixture's mode fields independently of the runner's umask.
        XCTAssertEqual(chmod(app.path, 0o755), 0)
        XCTAssertEqual(chmod(contents.path, 0o755), 0)
        XCTAssertEqual(chmod(payload.path, 0o644), 0)
        let expectedPaths = ["", "/Contents", "/Contents/payload"]
        XCTAssertEqual(try legacyItems(in: app).map { String($0.path.dropFirst(app.path.count)) }, expectedPaths)
        XCTAssertEqual(try SignatureSnapshot.items(in: app).map { String($0.path.dropFirst(app.path.count)) }, expectedPaths)
        let legacy = try legacyFingerprint(of: app)
        // Independent byte-field calculation of this fixed fixture. The old
        // helper's DirectoryEnumerator changed /var to /private/var, corrupting
        // both the relative-path fields and node order before hashing xattrs.
        XCTAssertEqual(legacy, "2a81dbd16ec5323ad1ac232980cf5a22a69ef845339eb4b9fa742ea93bdc23e3")
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: app), legacy)
    }

    func testLegacyRawForkManifestDecodesToCompactSummaryAndStillVerifies() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try Data("data".utf8).write(to: source)
        let bytes = Data((0..<32_769).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ 3) })
        try setAttribute(forkName, data: bytes, at: source)
        let current = try await TreeCopySession().copy(from: source, to: destination)
        var object = try XCTUnwrap(try PropertyListSerialization.propertyList(from: PropertyListEncoder().encode(current), format: nil) as? [String: Any])
        var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        var attributes = try XCTUnwrap(entries[0]["extendedAttributes"] as? [String: Data])
        attributes[forkName] = bytes
        entries[0]["extendedAttributes"] = attributes
        let compactFork = entries[0].removeValue(forKey: "resourceFork")
        object["entries"] = entries
        let oldBytes = try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
        let decoded = try PropertyListDecoder().decode(TreeCopySnapshot.self, from: oldBytes)
        XCTAssertEqual(decoded, current)
        XCTAssertNil(decoded.entries[0].extendedAttributes[forkName])
        XCTAssertLessThan(try PropertyListEncoder().encode(decoded).count, 16_384)
        try TreeCopySession.verifyUnchanged(at: source, against: decoded)
        try TreeCopySession.verifyCopy(at: destination, against: decoded)
        try TreeCopySession.applyRootMetadata(at: destination, from: decoded)
        XCTAssertEqual(try independentForkDigest(at: destination), Data(SHA256.hash(data: bytes)))

        // A mixed old/new record may not use conflicting raw bytes to bypass
        // the compact summary used by cleanup verification.
        entries[0]["resourceFork"] = compactFork
        attributes[forkName] = Data(repeating: 0xFF, count: bytes.count)
        entries[0]["extendedAttributes"] = attributes
        object["entries"] = entries
        let conflicting = try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
        XCTAssertThrowsError(try PropertyListDecoder().decode(TreeCopySnapshot.self, from: conflicting))
    }

    func testForkCorruptionAndUnknownPartialForkCannotPassVerification() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try Data("data".utf8).write(to: source)
        try setAttribute(forkName, data: Data(repeating: 0x5A, count: 65_536), at: source)
        let baseline = try await TreeCopySession().copy(from: source, to: destination)
        let before = try SignatureSnapshot.info(at: destination)
        let descriptor = open(destination.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure(destination) }
        defer { close(descriptor) }
        var changed: UInt8 = 0xA5
        XCTAssertEqual(fsetxattr(descriptor, forkName, &changed, 1, 32_768, 0), 0)
        var timestamps = [before.st_atimespec, before.st_mtimespec]
        XCTAssertEqual(futimens(descriptor, &timestamps), 0)
        XCTAssertThrowsError(try TreeCopySession.verifyCopy(at: destination, against: baseline))
        XCTAssertThrowsError(try TreeCopySession.partialCopySnapshot(at: destination, source: source, against: baseline))
        try TreeCopySession.verifyUnchanged(at: source, against: baseline)

        let plain = root.appendingPathComponent("plain")
        let unknown = root.appendingPathComponent("unknown")
        try Data("plain data".utf8).write(to: plain)
        try Data("plain data".utf8).write(to: unknown)
        let plainBaseline = try TreeCopySession.snapshot(at: plain)
        try setAttribute(forkName, data: Data("independent user bytes".utf8), at: unknown)
        XCTAssertThrowsError(try TreeCopySession.partialCopySnapshot(at: unknown, source: plain, against: plainBaseline))
        XCTAssertEqual(try independentForkDigest(at: unknown), Data(SHA256.hash(data: Data("independent user bytes".utf8))))
    }

    func test256MiBForkCopyFingerprintCancellationAndRetryUseBoundedMemory() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var filesystem = statfs()
        guard statfs(root.path, &filesystem) == 0 else { throw failure(root) }
        let filesystemName = withUnsafeBytes(of: filesystem.f_fstypename) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        XCTAssertEqual(filesystemName, "apfs", "This measured fixture must establish actual APFS resource-fork support")
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        let retry = root.appendingPathComponent("retry")
        let dataBytes = Data("small data fork".utf8)
        try dataBytes.write(to: source)
        let forkBytes = 256 * chunkBytes
        let expectedForkDigest = try writeSyntheticFork(at: source, byteCount: forkBytes)
        XCTAssertEqual(getxattr(source.path, forkName, nil, 0, 0, XATTR_NOFOLLOW), forkBytes)

        let sampler = try ResidentMemorySampler()
        defer { _ = sampler.finish() }
        let sourceStatus = try SignatureSnapshot.info(at: source)
        let expectedFingerprint = syntheticFileFingerprint(data: dataBytes, mode: sourceStatus.st_mode & 0o7777,
                                                           forkByteCount: forkBytes)
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: source), expectedFingerprint)
        let baseline = try TreeCopySession.snapshot(at: source)
        let fork = try XCTUnwrap(baseline.entries.first?.resourceFork)
        XCTAssertEqual(fork.size, Int64(forkBytes))
        XCTAssertEqual(fork.digest, expectedForkDigest)
        XCTAssertNil(baseline.entries.first?.extendedAttributes[forkName])
        XCTAssertEqual(baseline.logicalBytes, Int64(dataBytes.count + forkBytes))
        XCTAssertLessThan(try PropertyListEncoder().encode(baseline).count, 16_384)

        let completed = try await TreeCopySession().copy(from: source, to: destination)
        try TreeCopySession.verifyCopy(at: destination, against: completed)
        XCTAssertEqual(try independentForkDigest(at: destination), expectedForkDigest)
        XCTAssertEqual(try SignatureSnapshot.fingerprint(of: destination), expectedFingerprint)

        let task = Task {
            try await TreeCopySession().copy(from: source, to: retry, progressHandler: { progress in
                if progress.copiedBytes > Int64(dataBytes.count), progress.copiedBytes < progress.totalBytes {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            })
        }
        do { _ = try await task.value; XCTFail("Copy ignored cancellation during a resource-fork chunk") }
        catch is CancellationError {}
        catch { XCTFail("Unexpected cancellation error: \(error)") }
        let partialForkBytes = getxattr(retry.path, forkName, nil, 0, 0, XATTR_NOFOLLOW)
        XCTAssertGreaterThan(partialForkBytes, 0)
        XCTAssertLessThan(partialForkBytes, forkBytes)
        try TreeCopySession.verifyUnchanged(at: source, against: baseline)
        let partial = try TreeCopySession.partialCopySnapshot(at: retry, source: source, against: baseline)
        XCTAssertEqual(partial.entries.first?.resourceFork?.size, Int64(partialForkBytes))
        try TreeCopySession.removeVerifiedCopy(at: retry, against: partial)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retry.path))
        let retried = try await TreeCopySession().copy(from: source, to: retry)
        try TreeCopySession.verifyCopy(at: retry, against: retried)
        try TreeCopySession.verifyUnchanged(at: source, against: baseline)
        XCTAssertEqual(try independentForkDigest(at: retry), expectedForkDigest)

        let memory = sampler.finish()
        let evidence: [String: Any] = ["case": "resource-fork-256MiB", "pid": Int(getpid()),
            "filesystem": filesystemName, "forkBytes": forkBytes, "manifestBytes": try PropertyListEncoder().encode(baseline).count,
            "residentBaselineBytes": memory.baseline, "sampledPeakResidentBytes": memory.peak,
            "sampledResidentIncreaseBytes": memory.peak - memory.baseline, "residentSamples": memory.samples,
            "sampleFailures": memory.failures, "samplingIntervalMilliseconds": 10,
            "scope": "process RSS while fingerprinting, copying, cancelling, verifying and retrying; fixture creation excluded"]
        let json = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
        print("RESOURCE_FORK_VALIDATION \(String(decoding: json, as: UTF8.self))")
        XCTAssertEqual(memory.failures, 0)
        // RSS is broader than the explicit streaming buffer, and sampling can
        // miss brief peaks. A fork-sized allocation would exceed this budget.
        XCTAssertLessThan(memory.peak - memory.baseline, 128 * 1_048_576)
    }

    func testSparseResourceForkCanReadAndWriteBeyondFourGiBWithoutOffsetWrapping() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try Data("data".utf8).write(to: source)
        try setAttribute(forkName, data: Data([0x11]), at: source)
        let parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw failure(root) }
        defer { close(parent) }
        let descriptor = openat(parent, source.lastPathComponent, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure(source) }
        defer { close(descriptor) }
        let named = openat(parent, source.lastPathComponent + "/..namedfork/rsrc", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard named >= 0 else { throw failure(source) }
        defer { close(named) }
        let offset = Int64(UInt32.max) + 4_097
        XCTAssertEqual(ftruncate(named, off_t(offset + 64)), 0)
        let original = Data("bytes above four GiB".utf8)
        XCTAssertEqual(original.withUnsafeBytes { pwrite(named, $0.baseAddress, $0.count, off_t(offset)) }, original.count)
        let handle = ResourceForkStream.Handle(fileDescriptor: descriptor, parentDescriptor: parent,
            name: source.lastPathComponent, path: source.path, writable: true)
        var read = Data(count: original.count)
        XCTAssertEqual(try read.withUnsafeMutableBytes { try handle.read(into: $0, at: offset) }, original.count)
        XCTAssertEqual(read, original)
        let replacement = Data(repeating: 0xBC, count: original.count)
        try replacement.withUnsafeBytes { try handle.write($0, at: offset) }
        try handle.synchronize()
        XCTAssertEqual(read.withUnsafeMutableBytes { pread(named, $0.baseAddress, $0.count, off_t(offset)) }, replacement.count)
        XCTAssertEqual(read, replacement)
        var first: UInt8 = 0
        XCTAssertEqual(fgetxattr(descriptor, forkName, &first, 1, 0, 0), 1)
        XCTAssertEqual(first, 0x11, "A large offset must never wrap around and overwrite the first fork chunk")
    }

    func testLargeOffsetFallbackRejectsAReplacedFilenameBeforeWriting() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let retained = root.appendingPathComponent("retained")
        try Data("data".utf8).write(to: source)
        try setAttribute(forkName, data: Data("original fork".utf8), at: source)
        let parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw failure(root) }
        defer { close(parent) }
        let descriptor = openat(parent, source.lastPathComponent, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure(source) }
        defer { close(descriptor) }
        let handle = ResourceForkStream.Handle(fileDescriptor: descriptor, parentDescriptor: parent,
            name: source.lastPathComponent, path: source.path, writable: true)
        try FileManager.default.moveItem(at: source, to: retained)
        try Data("replacement data".utf8).write(to: source)
        let untouched = Data("independent fork".utf8)
        try setAttribute(forkName, data: untouched, at: source)
        XCTAssertThrowsError(try Data([0xFF]).withUnsafeBytes { try handle.write($0, at: Int64(UInt32.max) + 1) })
        XCTAssertEqual(getxattr(source.path, forkName, nil, 0, 0, XATTR_NOFOLLOW), untouched.count)
        XCTAssertEqual(try independentForkDigest(at: source), Data(SHA256.hash(data: untouched)))
        XCTAssertEqual(try independentForkDigest(at: retained), Data(SHA256.hash(data: Data("original fork".utf8))))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("AppPortsResourceFork-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func setAttribute(_ name: String, data: Data, at url: URL) throws {
        guard data.withUnsafeBytes({ setxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }) == 0 else {
            throw failure(url)
        }
    }

    private func writeSyntheticFork(at url: URL, byteCount: Int) throws -> Data {
        let descriptor = open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure(url) }
        defer { close(descriptor) }
        var hash = SHA256()
        try syntheticChunks(byteCount: byteCount) { bytes, offset in
            guard fsetxattr(descriptor, forkName, bytes.baseAddress, bytes.count, UInt32(offset), 0) == 0 else { throw failure(url) }
            hash.update(bufferPointer: bytes)
        }
        guard fsync(descriptor) == 0 else { throw failure(url) }
        return Data(hash.finalize())
    }

    private func syntheticChunks(byteCount: Int, _ body: (UnsafeRawBufferPointer, Int) throws -> Void) rethrows {
        var bytes = [UInt8](repeating: 0x5A, count: chunkBytes)
        var offset = 0
        while offset < byteCount {
            var chunkIndex = UInt64(offset / chunkBytes).bigEndian
            withUnsafeBytes(of: &chunkIndex) { indexBytes in
                bytes.withUnsafeMutableBytes { $0.copyBytes(from: indexBytes) }
            }
            let count = min(bytes.count, byteCount - offset)
            try bytes.withUnsafeBytes { try body(UnsafeRawBufferPointer(rebasing: $0.prefix(count)), offset) }
            offset += count
        }
    }

    /// Independent expected bytes for the large single-file fixture. It never
    /// reads the implementation's manifest or allocates the entire fork.
    private func syntheticFileFingerprint(data: Data, mode: mode_t, forkByteCount: Int) -> String {
        var hash = SHA256()
        func field(_ bytes: Data) {
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(bufferPointer: $0) }
            hash.update(data: bytes)
        }
        field(Data())
        field(Data(String(S_IFREG).utf8))
        field(Data(String(mode).utf8))
        field(Data(SHA256.hash(data: data)))
        field(Data("1".utf8))
        field(Data(forkName.utf8))
        var length = UInt64(forkByteCount).bigEndian
        withUnsafeBytes(of: &length) { hash.update(bufferPointer: $0) }
        syntheticChunks(byteCount: forkByteCount) { bytes, _ in hash.update(bufferPointer: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Uses the named fork and pread, independently of the copy's xattr path.
    private func independentForkDigest(at url: URL) throws -> Data {
        let descriptor = open(url.path + "/..namedfork/rsrc", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure(url) }
        defer { close(descriptor) }
        var hash = SHA256()
        var bytes = [UInt8](repeating: 0, count: chunkBytes)
        var offset: off_t = 0
        while true {
            let count = pread(descriptor, &bytes, bytes.count, offset)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw failure(url) }
            if count == 0 { break }
            bytes.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
            offset += off_t(count)
        }
        return Data(hash.finalize())
    }

    /// The old whole-value algorithm is limited to the small fixture above.
    private func legacyFingerprint(of root: URL) throws -> String {
        var hash = SHA256()
        func field(_ data: Data) {
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
            hash.update(data: data)
        }
        for url in try legacyItems(in: root) {
            let status = try SignatureSnapshot.info(at: url)
            let kind = status.st_mode & S_IFMT
            field(Data(url.path.dropFirst(root.path.count).utf8))
            field(Data(String(kind).utf8))
            field(Data(String(status.st_mode & 0o7777).utf8))
            if kind == S_IFREG { field(Data(SHA256.hash(data: try Data(contentsOf: url)))) }
            if kind == S_IFLNK { field(Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8)) }
            let count = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
            guard count >= 0 else { throw failure(url) }
            var bytes = [CChar](repeating: 0, count: count)
            let read = listxattr(url.path, &bytes, bytes.count, XATTR_NOFOLLOW)
            guard read == count else { throw failure(url) }
            let names = bytes.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
                .filter { $0.hasPrefix("com.apple.cs.") || $0 == forkName || $0 == "com.apple.FinderInfo" }.sorted()
            field(Data(String(names.count).utf8))
            for name in names {
                field(Data(name.utf8))
                let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
                guard size >= 0 else { throw failure(url) }
                var data = Data(count: size)
                guard data.withUnsafeMutableBytes({ getxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }) == size else {
                    throw failure(url)
                }
                field(data)
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Frozen HEAD's lexical traversal, independent of the production helper.
    /// Reconstruct child URLs from their names so all paths retain root's
    /// spelling through macOS's /var and /private/var aliases.
    private func legacyItems(in root: URL) throws -> [URL] {
        var items: [URL] = []
        var pending = [root]
        while let url = pending.popLast() {
            items.append(url)
            var status = stat()
            guard lstat(url.path, &status) == 0 else { throw failure(url) }
            if status.st_mode & S_IFMT == S_IFDIR {
                let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
                pending.append(contentsOf: names.map { url.appendingPathComponent($0) })
            }
        }
        return items.sorted { $0.path < $1.path }
    }

    private func failure(_ url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }
}

// Shared by the data and signature copy workloads so both report the same
// actual process RSS measurement and sampling limitations.
final class ResidentMemorySampler: @unchecked Sendable {
    struct Result { let baseline: UInt64; let peak: UInt64; let samples: Int; let failures: Int }
    private let baseline: UInt64
    private let lock = NSLock()
    private var peak: UInt64
    private var samples = 0
    private var failures = 0
    private let timer: DispatchSourceTimer

    init() throws {
        guard let initial = Self.residentBytes() else { throw CocoaError(.fileReadUnknown) }
        baseline = initial
        peak = initial
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "org.appports.tests.resource-fork-memory"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }

    deinit { timer.cancel() }

    func finish() -> Result {
        timer.cancel()
        sample()
        lock.lock()
        defer { lock.unlock() }
        return Result(baseline: baseline, peak: peak, samples: samples, failures: failures)
    }

    private func sample() {
        let resident = Self.residentBytes()
        lock.lock()
        defer { lock.unlock() }
        if let resident { peak = max(peak, resident); samples += 1 }
        else { failures += 1 }
    }

    private static func residentBytes() -> UInt64? {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : nil
    }
}
