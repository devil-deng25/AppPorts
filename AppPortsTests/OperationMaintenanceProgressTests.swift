import Foundation
import Testing
@testable import AppPorts

struct OperationMaintenanceProgressTests {
    @Test(.timeLimit(.minutes(1)))
    @available(macOS 13.0, *)
    func joiningBackgroundWorkSharesItsActualProgress() async {
        let started = ProgressLatch()
        let finish = ProgressLatch()
        let observed = MaintenanceProgressObservations()
        let maintenance = OperationMaintenance {
            await observed.didStart()
            let progress = DataTransferSession.progress
            #expect(progress != nil, "The detached worker must bind its own reporter")
            progress?.begin(.verifying)
            progress?.activity(file: "payload", bytesRead: 4096, completedItem: true)
            await started.open()
            await finish.wait()
            return ["synthetic result"]
        }
        let background = Task { await maintenance.run() }
        await started.wait()
        let joined = await maintenance.run { progress in
            await observed.append(progress)
            let snapshot = progress.snapshot()
            #expect(snapshot.stage == .verifying)
            #expect(snapshot.currentFile == "payload")
            #expect(snapshot.readBytes == 4096)
            #expect(snapshot.completedItems == 1)
            #expect(snapshot.fraction == nil)
            await finish.open()
        }
        #expect(joined == ["synthetic result"])
        #expect(await background.value == joined)
        #expect(await observed.starts == 1, "Joining a task must not rerun maintenance")
        #expect(DataTransferSession.progress == nil)

        _ = await maintenance.run { progress in await observed.append(progress) }
        let reporters = await observed.reporters
        #expect(reporters.count == 2)
        #expect(reporters[0] !== reporters[1], "A later maintenance run needs a fresh reporter")
        #expect(await observed.starts == 2)
    }
}

private actor ProgressLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor MaintenanceProgressObservations {
    private(set) var starts = 0
    private(set) var reporters: [DataTransferProgress] = []
    func didStart() { starts += 1 }
    func append(_ progress: DataTransferProgress) { reporters.append(progress) }
}
