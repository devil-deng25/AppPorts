import Foundation
import Testing
@testable import AppPorts

struct DataTransferProgressTests {
    @Test func groupedTaskDoesNotUseOverallFractionAsTheDirectoryStage() {
        let progress = DataTransferProgress()
        let msg = URL(fileURLWithPath: "/example/msg")
        let business = URL(fileURLWithPath: "/example/business")
        progress.configureUnits([msg, business])
        progress.setDirectory(msg)
        progress.observeDirectoryWorkflow()
        progress.begin(.switching) // Mounting the new preparation volume.
        #expect(progress.snapshot().presentationStage == .preparing)
        #expect(progress.snapshot().overallFraction < 0.1)
        #expect(progress.snapshot().directoryStep == 0)
        progress.begin(.scanning)
        #expect(progress.snapshot().overallFraction < 0.1)
        #expect(progress.snapshot().directoryStep == 1)
        progress.observeNewCopy(tracksEntrySwitchBoundaries: true)
        progress.update(.init(copiedBytes: 100, totalBytes: 100, currentFile: "payload"))
        progress.begin(.switching)
        #expect(progress.snapshot().directoryStep == 3)
        #expect(progress.snapshot().overallFraction < 0.44)
        progress.observeEntrySwitch()
        #expect(progress.snapshot().overallFraction == 0.44)
        #expect(progress.snapshot().directoryStep == 4)
        progress.begin(.cleaning)
        progress.verify(.activeData)
        #expect(progress.snapshot().directoryStep == 5)
        progress.setDirectory(business)
        progress.begin(.scanning)
        #expect(progress.snapshot().unitIndex == 1)
        #expect(progress.snapshot().directoryStep == 1)
        #expect(!progress.snapshot().hasStartedCopy)
        #expect(!progress.snapshot().hasEnteredCleanup)
        #expect(!progress.snapshot().hasEnteredEntrySwitch)
        #expect(progress.snapshot().overallFraction > 0.5)
    }

    @Test func privateMountsAndNestedChecksStayWithinTheEntryWorkflowStep() {
        let progress = DataTransferProgress()
        progress.observeNewCopy(tracksEntrySwitchBoundaries: true)
        progress.update(.init(copiedBytes: 100, totalBytes: 100, currentFile: "payload"))
        // The existing protective notification and private-volume unmount can
        // precede final source/target proof; neither changes the effective entry.
        progress.update(.init(copiedBytes: 100, totalBytes: 100, currentFile: "",
                              showsByteProgress: false, stage: .switching))
        #expect(progress.snapshot().stage == .switching)
        #expect(progress.snapshot().presentationStage == .verifying)
        #expect(progress.snapshot().directoryStep == 3)
        #expect(progress.snapshot().unitFraction < 0.88)
        progress.verify(.beforeSwitch)
        progress.begin(.switching)
        progress.verify(.sourceUnchanged)
        #expect(progress.snapshot().directoryStep == 3)
        #expect(progress.snapshot().unitFraction < 0.88)
        progress.observeEntrySwitch()
        progress.begin(.switching)
        #expect(progress.snapshot().directoryStep == 4)
        // Once an actual entry operation begins, an internal proof is part of
        // completing that switch, rather than another directory workflow step.
        progress.verify(.sourceUnchanged)
        #expect(progress.snapshot().stage == .verifying)
        #expect(progress.snapshot().directoryStep == 4)
        progress.begin(.cleaning)
        progress.begin(.switching)
        progress.verify(.retainedCopy)
        #expect(progress.snapshot().directoryStep == 5)
        #expect(progress.snapshot().presentationStage == .cleaning)
    }

    @Test func preparationPresentationKeepsTheExistingCriticalSectionProtection() throws {
        let progress = DataTransferProgress()
        let control = MigrationTaskControl()
        progress.observeDirectoryWorkflow()
        try MigrationExecution.$control.withValue(control) {
            control.pause()
            progress.begin(.switching)
            try control.checkpoint()
            #expect(control.snapshot().pauseRequested)
            #expect(!control.snapshot().paused)
            #expect(progress.snapshot().unitFraction < 0.1)
            #expect(progress.snapshot().presentationStage == .preparing)
            control.resume()
        }
    }

    @Test func appBundleSwitchingKeepsItsExistingPresentationBoundary() {
        let progress = DataTransferProgress()
        progress.observeNewCopy(tracksEntrySwitchBoundaries: false)
        progress.update(.init(copiedBytes: 100, totalBytes: 100, currentFile: "application"))
        progress.begin(.switching)
        #expect(!progress.snapshot().tracksEntrySwitchBoundaries)
        #expect(progress.snapshot().presentationStage == .switching)
        #expect(progress.snapshot().directoryStep == 4)
        #expect(progress.snapshot().unitFraction == 0.88)
    }

    @Test func sameDirectoryNewCopyResetsPredecessorCleanupWithoutChangingControl() throws {
        let progress = DataTransferProgress()
        let path = URL(fileURLWithPath: "/example/msg")
        progress.setDirectory(path)
        progress.observeResumedCopy(cleanup: true)
        progress.begin(.cleaning)
        progress.begin(.preparing)
        #expect(progress.snapshot().directoryStep == 5, "Internal preparation keeps cleanup scope")
        progress.setDirectory(path)
        let control = MigrationTaskControl()
        try MigrationExecution.$control.withValue(control) {
            progress.begin(.switching)
            control.pause()
            progress.observeNewCopy(tracksEntrySwitchBoundaries: true)
            try control.checkpoint()
            #expect(!control.snapshot().paused, "Presentation reset must not release the critical section")
            control.resume()
        }
        progress.begin(.scanning)
        #expect(!progress.snapshot().hasEnteredCleanup)
        #expect(!progress.snapshot().hasEnteredEntrySwitch)
        #expect(!progress.snapshot().hasStartedCopy)
        #expect(progress.snapshot().directoryStep == 1)
        #expect(progress.snapshot().unitFraction < 0.1)
        progress.update(.init(copiedBytes: 10, totalBytes: 100, currentFile: "new"))
        #expect(progress.snapshot().directoryStep == 2)
        #expect(progress.snapshot().unitFraction < 0.55)
    }

    @Test func resumedVerifiedTransactionsPresentSwitchAndCleanupWithoutRecopy() {
        let switching = DataTransferProgress()
        switching.observeResumedCopy(cleanup: false)
        switching.begin(.switching)
        #expect(switching.snapshot().directoryStep == 3)
        switching.observeEntrySwitch()
        #expect(switching.snapshot().directoryStep == 4)
        #expect(switching.snapshot().unitFraction == 0.88)
        let cleanup = DataTransferProgress()
        cleanup.observeResumedCopy(cleanup: true)
        cleanup.verify(.activeData)
        #expect(cleanup.snapshot().directoryStep == 5)
        #expect(cleanup.snapshot().unitFraction >= 0.94)
        cleanup.begin(.cleaning)
        #expect(cleanup.snapshot().directoryStep == 5)
        #expect(cleanup.snapshot().copiedBytes == 0)
    }

    @Test(arguments: [DataTransferStage.waiting, .preparing, .scanning, .synchronizing, .verifying, .switching, .cleaning, .recovering])
    func completedCopyDoesNotShowOverallCompletion(in stage: DataTransferStage) {
        let progress = DataTransferProgress()
        progress.update(.init(copiedBytes: 100, totalBytes: 100, currentFile: ""))
        #expect(progress.snapshot().fraction == 1)
        progress.begin(stage)
        #expect(progress.snapshot().fraction == nil)
        #expect(progress.snapshot().visibleCopyRate == nil)
        #expect(progress.snapshot().copiedBytes == 100)
    }

    @Test(arguments: [Int64(0), -1])
    func unknownCopySizeHasNoPercentage(total: Int64) {
        let progress = DataTransferProgress()
        progress.update(.init(copiedBytes: 4096, totalBytes: total, currentFile: "payload"))
        #expect(progress.snapshot().fraction == nil)
        #expect(progress.snapshot().copiedBytes == 4096)
    }

    @Test func elapsedTimeDoesNotPretendThatWorkAdvanced() {
        let clock = ProgressClock()
        let progress = DataTransferProgress(clock: { clock.now })
        progress.begin(.verifying)
        progress.activity(file: "payload", bytesRead: 1_048_576, completedItem: true)
        clock.advance(20)
        let waiting = progress.snapshot()
        #expect(waiting.elapsed == 20)
        #expect(waiting.stageElapsed == 20)
        #expect(waiting.activityAge == 20)
        #expect(waiting.isWaitingForActivity)
        #expect(waiting.completedItems == 1)
        #expect(waiting.readBytes == 1_048_576)
        #expect(progress.snapshot().activityAge == 20)

        progress.begin(.verifying)
        #expect(progress.snapshot().activityAge == 20, "Repeating a stage is not filesystem activity")
        progress.activity(bytesRead: 10)
        #expect(!progress.snapshot().isWaitingForActivity)
        #expect(progress.snapshot().stageElapsed == 20)
    }

    @Test func copyRateExpiresAndDoesNotLeakIntoTheNextStage() {
        let clock = ProgressClock()
        let progress = DataTransferProgress(clock: { clock.now })
        progress.update(.init(copiedBytes: 0, totalBytes: 1000, currentFile: "payload"))
        clock.advance(1)
        progress.update(.init(copiedBytes: 100, totalBytes: 1000, currentFile: "payload"))
        #expect(progress.snapshot().visibleCopyRate == 100)
        clock.advance(3)
        #expect(progress.snapshot().visibleCopyRate == nil)
        progress.update(.working(.verifying))
        #expect(progress.snapshot().fraction == nil)
        #expect(progress.snapshot().currentFile.isEmpty)
        #expect(progress.snapshot().visibleCopyRate == nil)
    }

    @Test func aNewDirectoryStartsWithIndependentProgress() {
        let previous = DataTransferProgress()
        previous.update(.init(copiedBytes: 100, totalBytes: 100, currentFile: "previous"))
        previous.begin(.cleaning)
        previous.activity(file: "old-copy", completedItem: true)
        let next = DataTransferProgress().snapshot()
        #expect(next.stage == .waiting)
        #expect(next.copiedBytes == 0)
        #expect(next.totalBytes == 0)
        #expect(next.completedItems == 0)
        #expect(next.currentFile.isEmpty)
        #expect(next.fraction == nil)
    }

    @Test func actualTraversalReportsReadBytesAndRestartsItsCounts() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let progress = DataTransferProgress()
        try DataTransferSession.$progress.withValue(progress) {
            let baseline = try TreeCopySession.snapshot(at: root)
            let scanned = progress.snapshot()
            #expect(scanned.stage == .scanning)
            #expect(scanned.completedItems == baseline.entries.count)
            #expect(scanned.readBytes == baseline.logicalBytes)
            try TreeCopySession.verifyUnchanged(at: root, against: baseline)
            let verified = progress.snapshot()
            #expect(verified.stage == .verifying)
            #expect(verified.fraction == nil)
            #expect(verified.completedItems == baseline.entries.count)
            #expect(verified.readBytes == baseline.logicalBytes)
            try DurableFileIO.syncTree(at: root)
            #expect(progress.snapshot().stage == .synchronizing)
            #expect(progress.snapshot().completedItems == baseline.entries.count)
            #expect(progress.snapshot().fraction == nil)
        }
        #expect(DataTransferSession.progress == nil)
    }

    @Test func realCopyAndCleanupReportTheirOwnStages() async throws {
        let root = try fixture()
        let destination = root.deletingLastPathComponent().appendingPathComponent("ProgressCopy-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: destination)
        }
        let progress = DataTransferProgress()
        let events = ProgressEvents()
        let baseline = try await progress.track { handler in
            try await TreeCopySession().copy(from: root, to: destination, progressHandler: { update in
                await handler(update)
                await events.append(update)
                if update.stage != .copying { #expect(progress.snapshot().fraction == nil) }
            })
        }
        let stages = await events.stages
        #expect(!stages.isEmpty)
        #expect(stages.allSatisfy { $0 == .copying }, "Traversal reporting must preserve the existing copy callbacks")
        #expect(await events.copyCompletionCount == 1, "Only the original final byte callback uses an empty filename")
        #expect(progress.snapshot().stage == .verifying)
        #expect(progress.snapshot().fraction == nil)
        try DataTransferSession.$progress.withValue(progress) {
            try TreeCopySession.removeVerifiedCopy(at: root, against: baseline, requireSourceIdentity: true)
        }
        #expect(progress.snapshot().stage == .cleaning)
        #expect(progress.snapshot().completedItems == baseline.entries.count)
        #expect(progress.snapshot().fraction == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        try TreeCopySession.verifyCopy(at: destination, against: baseline)
    }

    @Test func failedTrackingDoesNotLeaveAnObserverInTheNextOperation() async {
        let progress = DataTransferProgress()
        do {
            try await progress.track { _ in
                #expect(DataTransferSession.progress === progress)
                throw CancellationError()
            }
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(DataTransferSession.progress == nil)
        let next = DataTransferProgress()
        await next.track { _ in
            #expect(DataTransferSession.progress === next)
            #expect(next.snapshot().copiedBytes == 0)
        }
        #expect(DataTransferSession.progress == nil)
    }

    @Test func nestedAsyncMeasurementsRestoreTheirParentPhase() async throws {
        let value = try await DataTransferSession.run {
            let session = try #require(DataTransferSession.current)
            #expect(DataTransferSession.isMeasuring(.preparation))
            let result = await DataTransferSession.measure(.copy) {
                await Task.yield()
                #expect(DataTransferSession.isMeasuring(.copy))
                await DataTransferSession.measure(.verification) {
                    await Task.yield()
                    #expect(DataTransferSession.isMeasuring(.verification))
                    #expect(DataTransferSession.current === session)
                }
                #expect(DataTransferSession.isMeasuring(.copy))
                return 42
            }
            #expect(DataTransferSession.isMeasuring(.preparation))
            return result
        }
        #expect(value == 42)
        #expect(DataTransferSession.current == nil)
        #expect(!DataTransferSession.Phase.allCases.contains { DataTransferSession.isMeasuring($0) })
    }

    @Test func cancelledAsyncMeasurementRestoresPhaseAndReleasesSession() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await DataTransferSession.run {
                    do {
                        try await DataTransferSession.measure(.copy) {
                            await Task.yield()
                            #expect(DataTransferSession.isMeasuring(.copy))
                            try Task.checkCancellation()
                        }
                    } catch {
                        #expect(DataTransferSession.isMeasuring(.preparation))
                        throw error
                    }
                }
                Issue.record("Expected cancellation")
            } catch {
                #expect(error is CancellationError)
            }
            #expect(DataTransferSession.current == nil)
            #expect(!DataTransferSession.Phase.allCases.contains { DataTransferSession.isMeasuring($0) })
        }
        await task.value
        #expect(DataTransferSession.current == nil)
    }

    @Test func maintenanceCopyReportsBytesWithoutACallerCallback() async throws {
        let root = try fixture()
        let destination = root.deletingLastPathComponent().appendingPathComponent("ProgressCopy-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: destination)
        }
        let progress = DataTransferProgress()
        let baseline = try await progress.track { _ in
            try await TreeCopySession().copy(from: root, to: destination)
        }
        #expect(progress.snapshot().copiedBytes == baseline.logicalBytes)
        #expect(progress.snapshot().totalBytes == baseline.logicalBytes)
        #expect(progress.snapshot().stage == .verifying)
        #expect(progress.snapshot().fraction == nil)
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DataTransferProgress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: 2_097_152).write(to: root.appendingPathComponent("payload"))
        try Data().write(to: root.appendingPathComponent("empty"))
        return root
    }
}

private final class ProgressClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func advance(_ duration: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        value += duration
    }
}

private actor ProgressEvents {
    private(set) var stages: [DataTransferStage] = []
    private(set) var copyCompletionCount = 0
    func append(_ progress: FileCopier.Progress) {
        stages.append(progress.stage)
        if progress.currentFile.isEmpty { copyCompletionCount += 1 }
    }
}
