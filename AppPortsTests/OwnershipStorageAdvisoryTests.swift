import Foundation
import Testing
@testable import AppPorts

@Suite("Ownership storage advisory")
struct OwnershipStorageAdvisoryTests {
    private let destination = URL(fileURLWithPath: "/Volumes/UD210/Software/AppData/Application Support/io.github.clash-verge-rev.clash-verge-rev")

    private func advisory(type: String, ignoresOwnership: Bool = false, available: Bool = true) -> OwnershipStorageAdvisory {
        OwnershipStorageAdvisory(probe: .init(volumeState: { _ in
            available ? .init(filesystemType: type, ignoresOwnership: ignoresOwnership) : nil
        }))
    }

    // MARK: 判定

    @Test("Filesystems without an owner field are reported regardless of mount flags", arguments: ["exfat", "msdos", "fat", "ExFAT "])
    func filesystemsWithoutOwners(type: String) {
        let limitation = advisory(type: type).limitation(for: destination)
        let normalized = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        #expect(limitation == .noFileOwners(filesystemType: normalized))
    }

    @Test("HFS+ on an ownership-ignoring mount is reported")
    func hfsIgnoringOwnership() {
        let limitation = advisory(type: "hfs", ignoresOwnership: true).limitation(for: destination)
        #expect(limitation == .ignoredOwnership(filesystemType: "hfs"))
    }

    @Test("HFS+ with real ownership needs no warning")
    func hfsWithOwnership() {
        #expect(advisory(type: "hfs").limitation(for: destination) == nil)
    }

    @Test("APFS keeps real owners even under a noowners mount, so it is never reported", arguments: [false, true])
    func apfsIsNeverReported(ignoresOwnership: Bool) {
        #expect(advisory(type: "apfs", ignoresOwnership: ignoresOwnership).limitation(for: destination) == nil)
    }

    @Test("Unknown or unreadable volumes stay silent instead of guessing")
    func unknownVolumesStaySilent() {
        #expect(advisory(type: "", ignoresOwnership: true).limitation(for: destination) == nil)
        #expect(advisory(type: "smbfs").limitation(for: destination) == nil)
        #expect(advisory(type: "exfat", available: false).limitation(for: destination) == nil)
    }

    // MARK: 提示文案

    @Test("Messages name the drive and never promise that chown would help", arguments: [
        OwnershipStorageAdvisory.Limitation.noFileOwners(filesystemType: "exfat"),
        OwnershipStorageAdvisory.Limitation.ignoredOwnership(filesystemType: "hfs")
    ])
    func messagesNameTheDrive(limitation: OwnershipStorageAdvisory.Limitation) {
        let message = limitation.advisoryMessage(driveName: "UD210")
        #expect(message.contains("UD210"))
        #expect(message.contains("%@") == false)
        #expect(message.contains("chown") == false)
        #expect(message.contains("sudo") == false)
    }

    @Test("The two limitations do not share the same advice")
    func limitationsGiveDifferentAdvice() {
        let noOwners = OwnershipStorageAdvisory.Limitation.noFileOwners(filesystemType: "exfat")
            .advisoryMessage(driveName: "UD210")
        let ignored = OwnershipStorageAdvisory.Limitation.ignoredOwnership(filesystemType: "hfs")
            .advisoryMessage(driveName: "UD210")
        #expect(noOwners != ignored)
        // 只有 HFS+ 能在访达里打开所有权；exFAT 没有这个开关。
        #expect(ignored.contains("忽略此宗卷上的所有权"))
        #expect(noOwners.contains("忽略此宗卷上的所有权") == false)
    }

    // MARK: 真机探针

    @Test("The live probe reads the filesystem of an existing ancestor and never throws")
    func liveProbeResolvesExistingAncestor() {
        // 目标目录通常还没创建；探针沿父目录向上找到盘本身。
        let futureDestination = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("AppPortsAdvisoryMissing/Application Support/x")
        let state = OwnershipStorageAdvisory.Probe.live.volumeState(futureDestination)
        #expect(state != nil)
        #expect(state?.filesystemType.isEmpty == false)
    }
}
