import Darwin
import DiskArbitration
import Foundation
import IOKit

struct ExternalDiskInventory: Sendable {
    struct Disk: Equatable, Sendable {
        let deviceIdentifier: String
        let connectionID: String
        var displayName: String
        var volumeUUIDs: Set<String>
        var containerUUIDs: Set<String>
        var mountPaths: Set<String>
        // All physical slices and mapped APFS nodes, including EFI. These are
        // observation-only names, never persistent disk identity or authority.
        var deviceIdentifiers: Set<String> = []
        var mountMappingComplete = true
    }
    let disks: [Disk]

    func disk(volumeUUID: String) throws -> Disk {
        let matches = disks.filter { $0.volumeUUIDs.contains(volumeUUID.uppercased()) }
        guard matches.count == 1 else { throw DiskEjectionError.unavailable }
        return matches[0]
    }

    static func parse(list: [String: Any], apfs: [String: Any],
                      connection: (String) -> String?) throws -> Self {
        guard let entries = list["AllDisksAndPartitions"] as? [[String: Any]],
              let containers = apfs["Containers"] as? [[String: Any]] else { throw DiskEjectionError.unavailable }
        var disks: [String: Disk] = [:]
        var parents: [String: String] = [:]
        var excludedMembers: Set<String> = []
        var expectedAPFSStores: [String: Set<String>] = [:]
        var mappedAPFSStores: Set<String> = []
        for entry in entries {
            guard let device = entry["DeviceIdentifier"] as? String,
                  entry["APFSPhysicalStores"] == nil,
                  let id = connection(device) else { continue }
            let partitions = entry["Partitions"] as? [[String: Any]] ?? []
            var disk = Disk(deviceIdentifier: device, connectionID: id,
                displayName: device, volumeUUIDs: [], containerUUIDs: [], mountPaths: [])
            for part in [entry] + partitions {
                if let identifier = part["DeviceIdentifier"] as? String {
                    parents[identifier] = device
                    disk.deviceIdentifiers.insert(identifier)
                    if (part["Content"] as? String)?.hasPrefix("Apple_APFS") == true {
                        expectedAPFSStores[device, default: []].insert(identifier)
                    }
                }
                // EFI FAT UUIDs are frequently identical on unrelated disks.
                // They must not identify a data disk or establish reconnection.
                if part["Content"] as? String == "EFI" { continue }
                if let uuid = part["VolumeUUID"] as? String { disk.volumeUUIDs.insert(uuid.uppercased()) }
                if let path = part["MountPoint"] as? String, !path.isEmpty { disk.mountPaths.insert(path) }
                if let name = part["VolumeName"] as? String, !name.isEmpty, name != "EFI" { disk.displayName = name }
            }
            disks[device] = disk
        }
        for container in containers {
            guard let stores = container["PhysicalStores"] as? [[String: Any]],
                  let uuid = container["APFSContainerUUID"] as? String,
                  let volumes = container["Volumes"] as? [[String: Any]] else { throw DiskEjectionError.unavailable }
            let owners = Set(stores.compactMap { ($0["DeviceIdentifier"] as? String).flatMap { parents[$0] } })
            // Do not eject a multi-device storage construct through one of its members.
            guard owners.count == 1, stores.allSatisfy({ ($0["DeviceIdentifier"] as? String).flatMap { parents[$0] } != nil }),
                  let owner = owners.first, var disk = disks[owner] else {
                excludedMembers.formUnion(owners)
                continue
            }
            disk.containerUUIDs.insert(uuid.uppercased())
            mappedAPFSStores.formUnion(stores.compactMap { $0["DeviceIdentifier"] as? String })
            if let identifier = container["ContainerReference"] as? String, !identifier.isEmpty {
                disk.deviceIdentifiers.insert(identifier)
            } else { disk.mountMappingComplete = false }
            for volume in volumes {
                guard let volumeUUID = volume["APFSVolumeUUID"] as? String else { throw DiskEjectionError.unavailable }
                disk.volumeUUIDs.insert(volumeUUID.uppercased())
                if let identifier = volume["DeviceIdentifier"] as? String, !identifier.isEmpty {
                    disk.deviceIdentifiers.insert(identifier)
                } else { disk.mountMappingComplete = false }
                if let path = volume["MountPoint"] as? String, !path.isEmpty { disk.mountPaths.insert(path) }
                if let name = volume["Name"] as? String, !name.isEmpty, !name.hasPrefix("AppPorts-") {
                    disk.displayName = name
                }
            }
            disks[owner] = disk
        }
        // `apfs list` omits mount points on some releases; `list` includes them.
        for entry in entries {
            for volume in entry["APFSVolumes"] as? [[String: Any]] ?? [] {
                guard let uuid = volume["VolumeUUID"] as? String,
                      let path = volume["MountPoint"] as? String, !path.isEmpty else { continue }
                for key in Array(disks.keys) where disks[key]!.volumeUUIDs.contains(uuid.uppercased()) {
                    disks[key]!.mountPaths.insert(path)
                }
            }
        }
        for key in Array(disks.keys) where !(expectedAPFSStores[key] ?? []).isSubset(of: mappedAPFSStores) {
            disks[key]!.mountMappingComplete = false
        }
        return Self(disks: disks.values.filter { !$0.volumeUUIDs.isEmpty && !excludedMembers.contains($0.deviceIdentifier) }
            .sorted { $0.deviceIdentifier < $1.deviceIdentifier })
    }

    static func connectionID(device: String) -> String? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, "/dev/" + device),
              let description = DADiskCopyDescription(disk) as? [String: Any],
              description[kDADiskDescriptionMediaWholeKey as String] as? Bool == true,
              description[kDADiskDescriptionDeviceInternalKey as String] as? Bool == false,
              description[kDADiskDescriptionDeviceProtocolKey as String] as? String != "Disk Image" else { return nil }
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }
        var entry: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(media, &entry) == KERN_SUCCESS else { return nil }
        guard let boot = currentBootSessionUUID() else { return nil }
        return boot + ":" + String(entry)
    }

    static func currentBootSessionUUID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }
}
