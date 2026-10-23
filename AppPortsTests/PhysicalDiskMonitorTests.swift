import Foundation
import Testing
@testable import AppPorts

struct PhysicalDiskMonitorTests {
    @Test("Every live filesystem matters, including hidden siblings, EFI and APFS snapshots", arguments: [
        "/dev/disk7s1", "/dev/disk7s2", "/dev/disk6s1", "snapshot@/dev/disk7s1s1"
    ])
    func liveMountPreventsUnmountedState(_ source: String) {
        var disk = DiskEjectionTests.media()
        disk.mountPaths = []
        #expect(PhysicalDiskState.observed(physical: .online, disk: disk, mountedDevices: [source]) == .online)
        #expect(PhysicalDiskState.observed(physical: .online, disk: disk, mountedDevices: ["/dev/disk70s1"]) == .unmounted)
        #expect(PhysicalDiskState.observed(physical: .online, disk: disk, mountedDevices: nil) == .unknown)
        #expect(PhysicalDiskState.observed(physical: .online, disk: nil, mountedDevices: []) == .unknown)
    }

    @Test("Read-only validation of an already unmounted real bridge", .enabled(if:
        ProcessInfo.processInfo.environment["APPPORTS_UNMOUNTED_VOLUME_UUID"] != nil))
    func realUnmountedBridge() async throws {
        let uuid = try #require(ProcessInfo.processInfo.environment["APPPORTS_UNMOUNTED_VOLUME_UUID"])
        let utility = DiskUtility(administratorRunner: nil)
        let disk = try await utility.ejectionInventory().disk(volumeUUID: uuid)
        #expect(PhysicalDiskState.query(disk.connectionID) == .online)
        for member in disk.volumeUUIDs {
            let info = try await utility.volumeInfo(for: member)
            #expect(info.mountPoint?.isEmpty != false)
        }
        let mounts = Set(try DiskUtility.kernelMountTable().keys)
        #expect(PhysicalDiskState.observed(physical: .online, disk: disk, mountedDevices: mounts) == .unmounted)
    }

    @Test("Invalid identities remain unknown, while a missing registry entry proves the old connection is offline")
    func kernelProbe() throws {
        #expect(PhysicalDiskState.query("invalid") == .unknown)
        let boot = try #require(ExternalDiskInventory.currentBootSessionUUID())
        #expect(PhysicalDiskState.query(boot + ":18446744073709551614") == .offline)
    }

    @Test("Passive Disk Arbitration observation delivers existing media and can be stopped repeatedly")
    func passiveNotifications() async {
        for _ in 0..<3 {
            let monitor = PhysicalDiskMonitor()
            let changes = monitor.changes()
            let received = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for await _ in changes { return true }
                    return false
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    return false
                }
                let result = await group.next() ?? false
                group.cancelAll()
                return result
            }
            monitor.stop()
            monitor.stop()
            #expect(received)
        }
    }
}
