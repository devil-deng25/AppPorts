import Darwin
import Foundation
import Testing
@testable import AppPorts

struct ApplicationLaunchGateTests {
    @Test("Data work blocks forwarding for its application, without blocking another app")
    func applicationScope() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let migration = try ApplicationLaunchGate.acquire(bundleIdentifier: "org.example.one", migrating: true, directory: root)
        defer { withExtendedLifetime(migration) {} }
        #expect(throws: ApplicationLaunchGate.Failure.busy) {
            try ApplicationLaunchGate.acquire(bundleIdentifier: "org.example.one", migrating: false, directory: root)
        }
        let other = try ApplicationLaunchGate.acquire(bundleIdentifier: "org.example.two", migrating: false, directory: root)
        withExtendedLifetime(other) {}
    }

    @Test("All in-flight forwarding requests finish before a migration can claim the app")
    func launchWinsRace() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        var first: ApplicationLaunchGate.Lease? = try ApplicationLaunchGate.acquire(bundleIdentifier: "org.example.app", migrating: false, directory: root)
        var second: ApplicationLaunchGate.Lease? = try ApplicationLaunchGate.acquire(bundleIdentifier: "org.example.app", migrating: false, directory: root)
        withExtendedLifetime(first) {}
        first = nil
        #expect(throws: ApplicationLaunchGate.Failure.busy) {
            try ApplicationLaunchGate.acquire(bundleIdentifier: "org.example.app", migrating: true, directory: root)
        }
        withExtendedLifetime(second) {}
        second = nil
        let migration = try ApplicationLaunchGate.acquire(bundleIdentifier: "org.example.app", migrating: true, directory: root)
        withExtendedLifetime(migration) {}
    }

    @Test("Nested recovery keeps the gate through cancellation unwinding, then releases it")
    func nestedRecovery() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: CancellationError.self) {
            try await ApplicationLaunchProtection.run(identifier: "org.example.app", directory: root) {
                try await ApplicationLaunchProtection.detached(priority: .utility) {
                  try await ApplicationLaunchProtection.run(identifier: "org.example.app", directory: root) {
                    #expect(throws: ApplicationLaunchGate.Failure.busy) {
                        try ApplicationLaunchGate.acquire(bundleIdentifier: "org.example.app", migrating: false, directory: root)
                    }
                    throw CancellationError()
                  }
                }
            }
        }
        let launch = try ApplicationLaunchGate.acquire(bundleIdentifier: "org.example.app", migrating: false, directory: root)
        withExtendedLifetime(launch) {}
    }

    @Test("Cancelling the caller keeps forwarding blocked until independent recovery finishes")
    func cancelledCallerWaitsForRecovery() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let entered = Barrier()
        let finishRecovery = Barrier()
        let task = Task {
            try await ApplicationLaunchProtection.run(identifier: "org.example.app", directory: root) {
                try await ApplicationLaunchProtection.detached(priority: .utility) {
                    await entered.signal()
                    await finishRecovery.wait()
                    #expect(!Task.isCancelled)
                }
                try Task.checkCancellation()
            }
        }
        await entered.wait()
        task.cancel()
        #expect(throws: ApplicationLaunchGate.Failure.busy) {
            try ApplicationLaunchGate.acquire(bundleIdentifier: "org.example.app", migrating: false, directory: root)
        }
        await finishRecovery.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
        let launch = try ApplicationLaunchGate.acquire(bundleIdentifier: "org.example.app", migrating: false, directory: root)
        withExtendedLifetime(launch) {}
    }

    @Test("Direct data service calls reject in-flight forwarding before copying or restoring", arguments: [false, true])
    func directDataServiceGate(restoring: Bool) async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ContainerMountStore(fileURL: root.appendingPathComponent("container-mounts.plist"))
        let directory = root.appendingPathComponent("launch-locks", isDirectory: true)
        let launch = try ApplicationLaunchGate.acquire(bundleIdentifier: "org.example.app", migrating: false, directory: directory)
        defer { withExtendedLifetime(launch) {} }
        var item = DataDirItem(name: "Fixture", path: root.appendingPathComponent("data"),
                               type: .custom, priority: .optional, description: "")
        item.associatedBundleIdentifier = "org.example.app"
        let mover = DataDirMover(homeDir: root, store: store)
        await #expect(throws: DataOperationSafety.Failure.self) {
            if restoring {
                _ = try await mover.restoreAndComplete(item: item, progressHandler: nil)
            } else {
                _ = try await mover.migrateAndComplete(item: item, to: root.appendingPathComponent("external"), progressHandler: nil)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: store.fileURLForDeletionAuthorization.path))
        #expect(!FileManager.default.fileExists(atPath: item.path.path))
    }

    @Test("Data recovery uses the persisted application identity without changing its journal",
          arguments: ["restore", "resume", "cleanup"])
    func persistedDataServiceGate(_ operation: String) async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ContainerMountStore(fileURL: root.appendingPathComponent("container-mounts.plist"))
        let directory = root.appendingPathComponent("launch-locks", isDirectory: true)
        let launch = try ApplicationLaunchGate.acquire(bundleIdentifier: "org.example.app", migrating: false, directory: directory)
        defer { withExtendedLifetime(launch) {} }
        let source = root.appendingPathComponent("data")
        let transfer = DataTransferRecord(mode: .symlink, direction: .migrate, appName: "Fixture",
            bundleIdentifier: "org.example.app", dataDirType: DataDirType.custom.rawValue,
            originalPath: source.path, activePath: source.path,
            destinationPath: root.appendingPathComponent("external").path,
            sourceIdentity: DataPathIdentity(device: 1, inode: 1))
        try store.beginTransfer(transfer)
        let before = try Data(contentsOf: store.fileURLForDeletionAuthorization)
        let mover = DataDirMover(homeDir: root, store: store)
        let item = DataDirItem(name: "Fixture", path: source, type: .custom, priority: .optional, description: "")
        await #expect(throws: DataOperationSafety.Failure.self) {
            switch operation {
            case "restore": _ = try await mover.restoreAndComplete(item: item, progressHandler: nil)
            case "resume": _ = try await mover.resumeVerifiedTransfer(operationID: transfer.operationID, progressHandler: nil)
            default: try await mover.cleanupRetainedTransfer(operationID: transfer.operationID)
            }
        }
        #expect(try Data(contentsOf: store.fileURLForDeletionAuthorization) == before)
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test("Independent APFS recovery checks the launch gate before touching its transaction")
    func independentRecoveryGate() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ContainerMountStore(fileURL: root.appendingPathComponent("container-mounts.plist"))
        let directory = root.appendingPathComponent("launch-locks", isDirectory: true)
        let launch = try ApplicationLaunchGate.acquire(bundleIdentifier: "org.example.app", migrating: false, directory: directory)
        defer { withExtendedLifetime(launch) {} }
        let transfer = DataTransferRecord(mode: .mount, direction: .migrate,
            appName: "Fixture", bundleIdentifier: "org.example.app", dataDirType: "Containers",
            originalPath: root.appendingPathComponent("data").path, activePath: root.appendingPathComponent("data").path,
            destinationPath: root.appendingPathComponent("data").path, sourceIdentity: DataPathIdentity(volumeUUID: "FIXTURE"))
        await #expect(throws: DataOperationSafety.Failure.self) {
            _ = try await ContainerVolumeMigrator(store: store).recoverWithIndependentBudget(transfer)
        }
        #expect(!FileManager.default.fileExists(atPath: store.fileURLForDeletionAuthorization.path))
    }

    @Test("A separate process holds the same gate and a crash releases it")
    func processDeath() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        do {
            let initial = try ApplicationLaunchGate.acquire(bundleIdentifier: "org.example.app", migrating: false, directory: root)
            withExtendedLifetime(initial) {}
        }
        let file = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import fcntl,sys,time; f=open(sys.argv[1],'r+'); fcntl.flock(f,fcntl.LOCK_EX); print('ready',flush=True); time.sleep(30)", file.path]
        let output = Pipe(); child.standardOutput = output
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() } }
        #expect(String(data: output.fileHandleForReading.readData(ofLength: 6), encoding: .utf8) == "ready\n")
        #expect(throws: ApplicationLaunchGate.Failure.busy) {
            try ApplicationLaunchGate.acquire(bundleIdentifier: "org.example.app", migrating: false, directory: root)
        }
        kill(child.processIdentifier, SIGKILL); child.waitUntilExit()
        let recovered = try ApplicationLaunchGate.acquire(bundleIdentifier: "org.example.app", migrating: false, directory: root)
        withExtendedLifetime(recovered) {}
    }

    @Test("An unsafe gate path fails closed and cannot modify its symlink target")
    func symlinkRejected() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("gates")
        do {
            let initial = try ApplicationLaunchGate.acquire(bundleIdentifier: "org.example.app", migrating: false, directory: directory)
            withExtendedLifetime(initial) {}
        }
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try FileManager.default.removeItem(at: file)
        let target = root.appendingPathComponent("sentinel")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        #expect(throws: ApplicationLaunchGate.Failure.inspection) {
            try ApplicationLaunchGate.acquire(bundleIdentifier: "org.example.app", migrating: false, directory: directory)
        }
        #expect(try String(contentsOf: target) == "untouched")
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("AppPortsLaunchGate-" + UUID().uuidString)
    }

    private actor Barrier {
        private var signaled = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !signaled else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func signal() {
            signaled = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }
}
