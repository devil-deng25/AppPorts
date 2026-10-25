import Darwin
import XCTest
@testable import AppPorts

final class WriterAdmissionTests: XCTestCase {
    func testUnreadableUnrelatedProcessDoesNotAbortAValidWriter() throws {
        let current = try WriterAdmission.currentProcessIdentity()
        let other = getppid()
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        XCTAssertEqual(proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, size), size)
        let snapshot = try WriterAdmission.runningAppPortsProcesses(processIDs: [getpid(), other]) { pid in
            pid == getpid() ? (info, current.executablePath) : (nil, nil)
        }
        XCTAssertEqual(snapshot, [current])
        XCTAssertThrowsError(try WriterAdmission.runningAppPortsProcesses(processIDs: [getpid(), other]) { pid in
            pid == getpid() ? (info, current.executablePath) : (nil, "/synthetic/AppPorts.app/Contents/MacOS/AppPorts")
        }, "An identified AppPorts writer still requires a readable identity")
    }

    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WriterAdmissionTests-" + UUID().uuidString)
        let current = WriterProcessIdentity(processID: 101, userID: getuid(), startSeconds: 1,
                                            startMicroseconds: 10, executablePath: "/synthetic/current/AppPorts")
        let other = WriterProcessIdentity(processID: 202, userID: getuid(), startSeconds: 2,
                                          startMicroseconds: 20, executablePath: "/synthetic/agent/AppPorts")
        var processes: [WriterProcessIdentity] = []

        init() { processes = [current] }
        deinit { try? FileManager.default.removeItem(at: directory) }

        func admission(as process: WriterProcessIdentity? = nil) -> WriterAdmission {
            WriterAdmission(dataDirectory: directory, currentProcess: { process ?? self.current },
                            processSnapshot: { self.processes })
        }

        func write(_ presence: WriterPresence, using admission: WriterAdmission) throws {
            try DurableFileIO.write(try PropertyListEncoder().encode(presence),
                                    to: admission.presenceURL(processID: presence.process.processID))
        }
    }

    func testCompatibleMainAndDirectAgentInstancesCanShareTheDataset() throws {
        let fixture = Fixture()
        fixture.processes = [fixture.current, fixture.other]
        let main = fixture.admission()
        try main.registerCurrentProcess()
        XCTAssertThrowsError(try main.checkCurrentWriters())
        try fixture.admission(as: fixture.other).registerCurrentProcess()
        XCTAssertNoThrow(try main.checkCurrentWriters())
    }

    func testStartingAgentCanPublishItsPresenceBeforeAdmission() throws {
        let fixture = Fixture()
        fixture.processes.append(fixture.other)
        var now = 2.020020
        var waits = 0
        let admission = WriterAdmission(dataDirectory: fixture.directory,
            currentProcess: { fixture.current }, processSnapshot: { fixture.processes },
            clock: { now }, waitForRegistration: { interval in
                now += interval
                waits += 1
                if waits == 2 {
                    do { try fixture.admission(as: fixture.other).registerCurrentProcess() }
                    catch { XCTFail("Agent registration failed: \(error)") }
                }
            })
        try admission.registerCurrentProcess()
        XCTAssertNoThrow(try admission.checkCurrentWriters())
        XCTAssertEqual(waits, 2)
    }

    func testAgentExitingBetweenSnapshotAndPresenceReadDoesNotBlock() throws {
        let fixture = Fixture()
        var snapshots = 0
        let admission = WriterAdmission(dataDirectory: fixture.directory,
            currentProcess: { fixture.current }, processSnapshot: {
                snapshots += 1
                return snapshots == 1 ? [fixture.current, fixture.other] : [fixture.current]
            }, waitForRegistration: { _ in XCTFail("An exited agent needs no startup wait") })
        try admission.registerCurrentProcess()
        XCTAssertNoThrow(try admission.checkCurrentWriters())
        XCTAssertGreaterThanOrEqual(snapshots, 3)
    }

    func testStartingUnregisteredWriterRemainsRejectedAfterBoundedWait() throws {
        let fixture = Fixture()
        fixture.processes.append(fixture.other)
        var now = 2.020020
        var waits = 0
        let admission = WriterAdmission(dataDirectory: fixture.directory,
            currentProcess: { fixture.current }, processSnapshot: { fixture.processes },
            clock: { now }, waitForRegistration: { interval in now += interval; waits += 1 })
        try admission.registerCurrentProcess()
        XCTAssertThrowsError(try admission.checkCurrentWriters())
        XCTAssertGreaterThan(waits, 0)
        XCTAssertLessThanOrEqual(waits, 40)
        XCTAssertLessThanOrEqual(now, 3.020020)
    }

    func testReusedPIDMustPublishTheNewIdentityBeforeAdmission() throws {
        let fixture = Fixture()
        let stale = WriterProcessIdentity(processID: fixture.other.processID, userID: getuid(),
            startSeconds: 1, startMicroseconds: 10, executablePath: fixture.other.executablePath)
        try fixture.admission(as: stale).registerCurrentProcess()
        fixture.processes.append(fixture.other)
        var now = 2.020020
        var waits = 0
        let admission = WriterAdmission(dataDirectory: fixture.directory,
            currentProcess: { fixture.current }, processSnapshot: { fixture.processes },
            clock: { now }, waitForRegistration: { interval in
                now += interval
                waits += 1
                do { try fixture.admission(as: fixture.other).registerCurrentProcess() }
                catch { XCTFail("New process registration failed: \(error)") }
            })
        try admission.registerCurrentProcess()
        XCTAssertNoThrow(try admission.checkCurrentWriters())
        XCTAssertEqual(waits, 1)
    }

    func testInstalledNewVersionDoesNotAuthorizeAnAlreadyRunningOldInstance() throws {
        let fixture = Fixture()
        let installed = fixture.directory.appendingPathComponent("Replaced.app")
        try FileManager.default.createDirectory(at: installed.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.shimoko.AppPorts", "CFBundleVersion": "999"],
                                           format: .xml, options: 0).write(to: installed.appendingPathComponent("Contents/Info.plist"))
        let old = WriterProcessIdentity(processID: 202, userID: getuid(), startSeconds: 2, startMicroseconds: 20,
                                        executablePath: installed.appendingPathComponent("Contents/MacOS/AppPorts").path)
        fixture.processes = [fixture.current, old]
        let admission = fixture.admission()
        try admission.registerCurrentProcess()
        XCTAssertThrowsError(try admission.checkCurrentWriters()) { error in
            XCTAssertTrue(error.localizedDescription.contains("202"))
            XCTAssertTrue(error.localizedDescription.contains(old.executablePath))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appendingPathComponent("Contents/Info.plist").path))
    }

    func testStalePresenceCannotAuthorizePIDReuseOrAnExecutableAtAnotherPath() throws {
        let fixture = Fixture()
        let admission = fixture.admission()
        try admission.registerCurrentProcess()
        try fixture.admission(as: fixture.other).registerCurrentProcess()
        let reused = WriterProcessIdentity(processID: fixture.other.processID, userID: getuid(), startSeconds: 3,
                                           startMicroseconds: 20, executablePath: fixture.other.executablePath)
        let differentExecutable = WriterProcessIdentity(processID: fixture.other.processID, userID: getuid(), startSeconds: 2,
                                                        startMicroseconds: 20, executablePath: "/synthetic/old/AppPorts")
        for process in [reused, differentExecutable] {
            fixture.processes = [fixture.current, process]
            XCTAssertThrowsError(try admission.checkCurrentWriters())
        }
        fixture.processes = [fixture.current]
        XCTAssertNoThrow(try admission.checkCurrentWriters(), "A dead instance's stale record is not a live writer")
    }

    func testRegistrationForAnotherDatasetCannotAuthorizeThisDataset() throws {
        let fixture = Fixture()
        let admission = fixture.admission()
        try admission.registerCurrentProcess()
        let presence = WriterPresence(process: fixture.current, dataDirectoryPath: fixture.directory.appendingPathComponent("other").path,
                                      capabilities: [WriterAdmission.requiredCapability])
        try fixture.write(presence, using: admission)
        XCTAssertThrowsError(try admission.checkCurrentWriters())
    }

    func testMatchingProcessWithoutRequiredRuntimeCapabilityIsRejected() throws {
        let fixture = Fixture()
        let admission = fixture.admission()
        try admission.registerCurrentProcess()
        let presence = WriterPresence(process: fixture.current,
                                      dataDirectoryPath: fixture.directory.resolvingSymlinksInPath().path,
                                      capabilities: ["old-writer"])
        try fixture.write(presence, using: admission)
        XCTAssertThrowsError(try admission.checkCurrentWriters())
    }

    func testMalformedOrLinkedPresenceDoesNotPermitWriting() throws {
        let fixture = Fixture()
        let admission = fixture.admission()
        try admission.registerCurrentProcess()
        let record = admission.presenceURL(processID: fixture.current.processID)
        let saved = fixture.directory.appendingPathComponent("saved-presence.plist")
        try FileManager.default.copyItem(at: record, to: saved)
        try Data("not a property list".utf8).write(to: record)
        XCTAssertThrowsError(try admission.checkCurrentWriters())
        try FileManager.default.removeItem(at: record)
        try FileManager.default.createSymbolicLink(at: record, withDestinationURL: saved)
        XCTAssertThrowsError(try admission.checkCurrentWriters())
        XCTAssertEqual(try Data(contentsOf: saved), try Data(contentsOf: record), "The rejected link target is preserved")
    }

    func testFailedOrIncompleteProcessInspectionFailsClosed() throws {
        let fixture = Fixture()
        let failed = WriterAdmission(dataDirectory: fixture.directory, currentProcess: { fixture.current },
                                     processSnapshot: { throw WriterAdmissionError.inspectionFailed(202, "unreadable") })
        try failed.registerCurrentProcess()
        XCTAssertThrowsError(try failed.checkCurrentWriters())
        fixture.processes = []
        XCTAssertThrowsError(try fixture.admission().checkCurrentWriters())
    }

    func testLateWriterIsRejectedAtTheNextOperationBoundaryWithoutReleasingTheOwnersLock() throws {
        let fixture = Fixture()
        let admission = fixture.admission()
        try admission.registerCurrentProcess()
        let url = fixture.directory.appendingPathComponent("operation.lock")
        let owner = OperationLock(fileURL: url, writerAdmissionCheck: { try admission.checkCurrentWriters() })
        let observer = OperationLock(fileURL: url)
        defer { owner.release(); observer.release() }
        XCTAssertTrue(owner.tryAcquire())
        fixture.processes.append(fixture.other)
        XCTAssertThrowsError(try owner.recheckWriterAdmission())
        XCTAssertNotNil(owner.admissionFailureReason)
        XCTAssertFalse(observer.tryAcquire())
        fixture.processes.removeAll { $0 == fixture.other }
        XCTAssertNoThrow(try owner.recheckWriterAdmission())
        XCTAssertNil(owner.admissionFailureReason)
        owner.release()
        XCTAssertTrue(observer.tryAcquire())
    }

    func testWriterAppearingAfterFlockRejectsAndReleasesOnlyTheCandidateDescriptor() throws {
        let fixture = Fixture()
        let admission = fixture.admission()
        try admission.registerCurrentProcess()
        var checks = 0
        let url = fixture.directory.appendingPathComponent("operation.lock")
        let interrupted = OperationLock(fileURL: url, writerAdmissionCheck: {
            checks += 1
            if checks == 2 { fixture.processes.append(fixture.other) }
            try admission.checkCurrentWriters()
        })
        XCTAssertFalse(interrupted.tryAcquire())
        XCTAssertEqual(checks, 2)
        XCTAssertNotNil(interrupted.admissionFailureReason)
        let next = OperationLock(fileURL: url)
        defer { next.release() }
        XCTAssertTrue(next.tryAcquire(), "A failed post-lock admission check must release its candidate descriptor")
        interrupted.release()
        let observer = OperationLock(fileURL: url)
        XCTAssertFalse(observer.tryAcquire(), "A later rejected release cannot affect the successor")
    }

    func testRejectedAdmissionDoesNotWaitOrReleaseAnotherOperationsLock() async throws {
        let fixture = Fixture()
        let admission = fixture.admission()
        try admission.registerCurrentProcess()
        fixture.processes.append(fixture.other)
        let url = fixture.directory.appendingPathComponent("operation.lock")
        let owner = OperationLock(fileURL: url)
        defer { owner.release() }
        XCTAssertTrue(owner.tryAcquire())
        let denied = OperationLock(fileURL: url, writerAdmissionCheck: { try admission.checkCurrentWriters() })
        let started = Date()
        let acquired = await denied.acquire(timeout: 30)
        XCTAssertFalse(acquired)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertNotNil(denied.admissionFailureReason)
        denied.release()
        let observer = OperationLock(fileURL: url)
        XCTAssertFalse(observer.tryAcquire())
    }

    func testKernelProbeReadsCurrentProcessIdentityWithoutTouchingTheDefaultDataset() throws {
        let identity = try WriterAdmission.currentProcessIdentity()
        XCTAssertEqual(identity.processID, getpid())
        XCTAssertEqual(identity.userID, getuid())
        XCTAssertGreaterThan(identity.startSeconds, 0)
        XCTAssertTrue(identity.executablePath.hasPrefix("/"))
        XCTAssertTrue(try WriterAdmission.runningAppPortsProcesses().contains(identity))
    }

    func testKernelProbeDetectsADirectlyLaunchedUnregisteredExecutable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WriterAdmissionProcess-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("AppPorts")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
        // A copied platform binary can be killed by macOS before admission is
        // checked. Sign only this temporary fixture so it remains a live writer.
        let signature = try await ProcessCommandRunner().run(executable: "/usr/bin/codesign",
            arguments: ["--force", "--sign", "-", executable.path], timeout: 15)
        XCTAssertEqual(signature.status, 0, signature.combinedText)
        guard signature.status == 0 else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["30"]
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let current = try WriterAdmission.currentProcessIdentity()
        var observed: WriterProcessIdentity?
        for _ in 0..<100 {
            observed = try WriterAdmission.runningAppPortsProcesses().first { $0.processID == process.processIdentifier }
            if observed != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let running = try XCTUnwrap(observed)
        XCTAssertEqual(running.executablePath, executable.resolvingSymlinksInPath().path)
        let admission = WriterAdmission(dataDirectory: directory.appendingPathComponent("isolated-data"),
            processSnapshot: { try WriterAdmission.runningAppPortsProcesses().filter { [current.processID, running.processID].contains($0.processID) } })
        try admission.registerCurrentProcess()
        XCTAssertTrue(process.isRunning, "The unregistered fixture must still be running when admission is checked")
        XCTAssertThrowsError(try admission.checkCurrentWriters()) { error in
            XCTAssertTrue(error.localizedDescription.contains(String(running.processID)))
        }
    }

    // MARK: - 失效登记回收

    /// macOS 的 PID 上限是 99998，这个号不可能有进程占用。
    private let impossibleProcessID: Int32 = 99_999

    private func presenceDirectory(_ admission: WriterAdmission) -> URL {
        admission.presenceURL(processID: 1).deletingLastPathComponent()
    }

    private func setModification(_ url: URL, secondsAgo: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-secondsAgo)],
                                              ofItemAtPath: url.path)
    }

    func testStaleRegistrationSurvivesUntilTheGracePeriodElapses() throws {
        let fixture = Fixture()
        let admission = fixture.admission()
        try admission.registerCurrentProcess()
        let stale = admission.presenceURL(processID: impossibleProcessID)
        try Data("stale".utf8).write(to: stale)

        try admission.registerCurrentProcess()
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path),
                      "记录刚写下时可能落在其他实例的启动窗口内，静默期未到不得删除")

        try setModification(stale, secondsAgo: WriterAdmission.presenceGracePeriod + 60)
        try admission.registerCurrentProcess()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path),
                       "进程已不存在且超过静默期的登记应被回收")
    }

    func testAbandonedWriteTemporariesArePrunedAfterTheGracePeriod() throws {
        let fixture = Fixture()
        let admission = fixture.admission()
        try admission.registerCurrentProcess()
        let temporary = presenceDirectory(admission)
            .appendingPathComponent(DurableFileIO.temporaryNamePrefix + UUID().uuidString)
        try Data(repeating: 0, count: 16).write(to: temporary)

        try admission.registerCurrentProcess()
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporary.path),
                      "正在进行中的原子写入不能被当成残留删掉")

        try setModification(temporary, secondsAgo: WriterAdmission.presenceGracePeriod + 60)
        try admission.registerCurrentProcess()
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path),
                       "写入中断遗留的临时文件应被回收")
    }

    func testPruneLeavesUnrelatedEntriesAndTheCurrentRegistrationAlone() throws {
        let fixture = Fixture()
        let admission = fixture.admission()
        try admission.registerCurrentProcess()
        let directory = presenceDirectory(admission)
        let unrelated = directory.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: unrelated)
        try setModification(unrelated, secondsAgo: 3_600)
        let current = admission.presenceURL(processID: fixture.current.processID)
        try setModification(current, secondsAgo: 3_600)

        try admission.registerCurrentProcess()
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path),
                      "只回收本机制产生的两种文件，其他内容一律不碰")
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path),
                      "当前实例自己的登记不参与清理")
    }

    func testPruneRemovesAtMostThePerRunLimitAndLeavesTheRestForLater() throws {
        let fixture = Fixture()
        // 积压场景要的是「条数封顶」本身，时间预算在这里放大到足够，
        // 否则慢盘上可能先撞预算、让断言变成看磁盘脸色。
        let admission = WriterAdmission(dataDirectory: fixture.directory,
            policy: PresencePolicy(timeBudget: 30),
            currentProcess: { fixture.current }, processSnapshot: { fixture.processes })
        try admission.registerCurrentProcess()
        let directory = presenceDirectory(admission)
        let total = WriterAdmission.presencePruneLimit + 20
        // 用临时文件构造积压：它们的失效只由年龄决定，不依赖某个 PID 恰好不存在。
        for _ in 0..<total {
            let url = directory.appendingPathComponent(DurableFileIO.temporaryNamePrefix + UUID().uuidString)
            try Data(repeating: 0, count: 8).write(to: url)
            try setModification(url, secondsAgo: 600)
        }

        try admission.registerCurrentProcess()
        let survivors = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(DurableFileIO.temporaryNamePrefix) }
        XCTAssertEqual(survivors.count, total - WriterAdmission.presencePruneLimit,
                       "单轮删除数量必须封顶，其余留给后续轮次")
    }

    func testPruneGateCanSkipAPassEntirely() throws {
        let fixture = Fixture()
        var gates = 0
        let admission = WriterAdmission(dataDirectory: fixture.directory,
            currentProcess: { fixture.current }, processSnapshot: { fixture.processes },
            pruneGate: { _, _ in gates += 1; return false })
        try admission.registerCurrentProcess()
        let stale = admission.presenceURL(processID: impossibleProcessID)
        try Data("stale".utf8).write(to: stale)
        try setModification(stale, secondsAgo: 3_600)

        try admission.registerCurrentProcess()
        XCTAssertGreaterThan(gates, 0, "节流闸门必须被咨询")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path),
                      "闸门拒绝的轮次不得删除任何东西")
    }

    func testPruneReclaimsNonCanonicalPresenceNames() throws {
        // `007.plist` 读不成任何有效登记。如果只是跳过不处理，它就会永远留在
        // 目录里 —— 这正是原实现在「非规范命名」上的泄漏点。
        let fixture = Fixture()
        let admission = fixture.admission()
        try admission.registerCurrentProcess()
        let nonCanonical = presenceDirectory(admission).appendingPathComponent("007.plist")
        try Data("junk".utf8).write(to: nonCanonical)
        try setModification(nonCanonical, secondsAgo: 3_600)

        try admission.registerCurrentProcess()
        XCTAssertFalse(FileManager.default.fileExists(atPath: nonCanonical.path),
                       "非规范命名的 .plist 不会成为有效登记，超龄后应按残留回收")
    }

    func testPruneReportCountsWhatThePassActuallyDid() throws {
        let fixture = Fixture()
        var reports: [PruneReport] = []
        let admission = WriterAdmission(dataDirectory: fixture.directory,
            currentProcess: { fixture.current }, processSnapshot: { fixture.processes },
            pruneReport: { report, _ in reports.append(report) })
        try admission.registerCurrentProcess()
        let directory = presenceDirectory(admission)
        for _ in 0..<3 {
            let url = directory.appendingPathComponent(DurableFileIO.temporaryNamePrefix + UUID().uuidString)
            try Data(repeating: 0, count: 8).write(to: url)
            try setModification(url, secondsAgo: 600)
        }
        let unrelated = directory.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: unrelated)
        try setModification(unrelated, secondsAgo: 600)

        reports.removeAll()
        try admission.registerCurrentProcess()
        let report = try XCTUnwrap(reports.last, "执行过的轮次必须回报结果")
        XCTAssertEqual(report.removed, 3, "三条超龄临时文件应被回收")
        XCTAssertGreaterThanOrEqual(report.elapsed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path),
                      "报告不能把无关文件算进删除数")
    }

    func testTimeBudgetStopsAPassEvenWhenNothingElseWould() throws {
        let fixture = Fixture()
        let admission = WriterAdmission(dataDirectory: fixture.directory,
            policy: PresencePolicy(timeBudget: 0),
            currentProcess: { fixture.current }, processSnapshot: { fixture.processes })
        try admission.registerCurrentProcess()
        let stale = admission.presenceURL(processID: impossibleProcessID)
        try Data("stale".utf8).write(to: stale)
        try setModification(stale, secondsAgo: 3_600)

        try admission.registerCurrentProcess()
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path),
                      "时间预算耗尽时必须停止，不得继续删除")
    }

    func testDurableFileIOReclaimsAbandonedTemporariesInAnyDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DurableFileIOTemporaries-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let abandoned = directory.appendingPathComponent(DurableFileIO.temporaryNamePrefix + UUID().uuidString)
        try Data(repeating: 0, count: 8).write(to: abandoned)
        try setModification(abandoned, secondsAgo: 600)
        let inFlight = directory.appendingPathComponent(DurableFileIO.temporaryNamePrefix + UUID().uuidString)
        try Data(repeating: 0, count: 8).write(to: inFlight)
        let record = directory.appendingPathComponent("record.plist")
        try Data("keep".utf8).write(to: record)

        let removed = DurableFileIO.pruneAbandonedTemporaries(in: directory)
        XCTAssertEqual(removed, 1, "只回收超过静默期的临时文件")
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inFlight.path),
                      "静默期内的临时文件属于正在进行的写入")
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path),
                      "同目录的正常记录不受影响")
    }

    func testPruneIfNeededIsThrottledPerDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DurableFileIOThrottle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let abandoned = directory.appendingPathComponent(DurableFileIO.temporaryNamePrefix + UUID().uuidString)
        try Data(repeating: 0, count: 8).write(to: abandoned)
        try setModification(abandoned, secondsAgo: 600)

        XCTAssertEqual(DurableFileIO.pruneAbandonedTemporariesIfNeeded(in: directory, now: 1_000), 1)
        let second = directory.appendingPathComponent(DurableFileIO.temporaryNamePrefix + UUID().uuidString)
        try Data(repeating: 0, count: 8).write(to: second)
        try setModification(second, secondsAgo: 600)
        XCTAssertEqual(DurableFileIO.pruneAbandonedTemporariesIfNeeded(in: directory, now: 1_001), 0,
                       "同一目录在节流间隔内不得重复扫描")
        XCTAssertEqual(DurableFileIO.pruneAbandonedTemporariesIfNeeded(
            in: directory, now: 1_000 + DurableFileIO.temporaryPruneInterval + 1), 1,
                       "超过间隔后应恢复扫描")
    }
}
