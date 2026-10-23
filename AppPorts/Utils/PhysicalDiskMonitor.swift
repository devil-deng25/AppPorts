import DiskArbitration
import Foundation
import IOKit

enum PhysicalDiskState: Equatable, Sendable {
    case online, unmounted, offline, unknown

    static func observed(physical: Self, disk: ExternalDiskInventory.Disk?, mountedDevices: Set<String>?) -> Self {
        guard physical == .online else { return physical }
        guard let disk, disk.mountMappingComplete, !disk.deviceIdentifiers.isEmpty, let mountedDevices else { return .unknown }
        let mounted = mountedDevices.contains { source in
            // Some snapshot mount sources contain "snapshot-name@/dev/disk...".
            let device = source.split(separator: "@").last.map(String.init) ?? source
            return disk.deviceIdentifiers.contains { name in
                let root = "/dev/" + name
                return device == root || device.hasPrefix(root + "s")
            }
        }
        return mounted ? .online : .unmounted
    }

    /// Probe the original whole-media registry identity, independently of Finder,
    /// mount points, and the filtered list of volumes eligible for migration.
    static func query(_ connectionID: String) -> Self {
        guard let separator = connectionID.lastIndex(of: ":"),
              let entryID = UInt64(connectionID[connectionID.index(after: separator)...]),
              let boot = ExternalDiskInventory.currentBootSessionUUID() else { return .unknown }
        guard connectionID[..<separator] == boot else { return .offline }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IORegistryEntryIDMatching(entryID), &iterator) == KERN_SUCCESS else {
            return .unknown
        }
        defer { IOObjectRelease(iterator) }
        let media = IOIteratorNext(iterator)
        guard media != 0 else { return .offline }
        defer { IOObjectRelease(media) }
        guard IOObjectConformsTo(media, "IOMedia") != 0 else { return .unknown }
        return .online
    }

    var statusText: String {
        switch self {
        case .online: return "磁盘尚未弹出，自动挂载已暂停。".localized
        case .unmounted: return "所有卷已卸载，设备仍连接。请拔下设备后重新插入。".localized
        case .offline: return "磁盘已离线，请重新插入设备。".localized
        case .unknown: return "无法确认磁盘是否已离线，自动挂载仍已暂停。".localized
        }
    }
}

/// Passive notification only: never approves, refuses, mounts or ejects media.
/// Session setup, callbacks and teardown all run on the same serial queue.
final class PhysicalDiskMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.shimoko.AppPorts.physicalDiskMonitor")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var session: DASession?
    private var onChange: (@Sendable () -> Void)?

    init() { queue.setSpecific(key: queueKey, value: true) }

    func changes() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            queue.sync {
                guard session == nil, let created = DASessionCreate(kCFAllocatorDefault) else { return }
                onChange = { continuation.yield(()) }
                session = created
                let context = Unmanaged.passUnretained(self).toOpaque()
                let wholeMedia = kDADiskDescriptionMatchMediaWhole.takeUnretainedValue()
                DARegisterDiskAppearedCallback(created, wholeMedia, Self.changed, context)
                DARegisterDiskDisappearedCallback(created, wholeMedia, Self.changed, context)
                DASessionSetDispatchQueue(created, queue)
            }
            continuation.onTermination = { [weak self] _ in self?.stop() }
        }
    }

    private static let changed: DADiskAppearedCallback = { _, context in
        guard let context else { return }
        Unmanaged<PhysicalDiskMonitor>.fromOpaque(context).takeUnretainedValue().onChange?()
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) == true { tearDown() }
        else { queue.sync { tearDown() } }
    }

    private func tearDown() {
        guard let session else { return }
        self.session = nil
        DAUnregisterCallback(session, unsafeBitCast(Self.changed, to: UnsafeMutableRawPointer.self),
                             Unmanaged.passUnretained(self).toOpaque())
        DASessionSetDispatchQueue(session, nil)
        onChange = nil
    }

    deinit { stop() }
}
