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

    /// The contract is that the two limitations give *different* advice, because
    /// only HFS+ has an ownership switch in Finder and exFAT has none.
    ///
    /// The wording itself must not be asserted: `.localized` resolves against
    /// `Bundle.main`, and under `xctest` the main bundle is the test runner, not
    /// AppPorts.app — so which translation appears depends on how the suite is
    /// launched, not on `LanguageManager`. Assert the difference and the drive
    /// name instead, which hold in every locale.
    @Test("The two limitations do not share the same advice")
    func limitationsGiveDifferentAdvice() {
        let noOwners = OwnershipStorageAdvisory.Limitation.noFileOwners(filesystemType: "exfat")
            .advisoryMessage(driveName: "UD210")
        let ignored = OwnershipStorageAdvisory.Limitation.ignoredOwnership(filesystemType: "hfs")
            .advisoryMessage(driveName: "UD210")
        #expect(noOwners != ignored)
        // Both must still identify the drive and neither may promise chown works.
        for message in [noOwners, ignored] {
            #expect(message.contains("UD210"))
            #expect(message.contains("chown") == false)
            #expect(message.contains("%@") == false)
        }
        // The two limitations differ in their file-system type, so the messages
        // differ in more than the drive name alone.
        #expect(noOwners.replacingOccurrences(of: "UD210", with: "") !=
                ignored.replacingOccurrences(of: "UD210", with: ""))
    }

    /// The behaviour that matters — which volumes are flagged — is asserted above
    /// without any localization. The messages only need to identify the drive and
    /// stay free of the `chown` advice that cannot work, which every translation
    /// satisfies; that is checked here so no locale can weaken it.
    @Test("Every localized variant keeps the drive name and drops the chown advice",
          arguments: ["zh-Hans", "zh-Hant", "en", "ja", "de"])
    func messagesHoldAcrossLanguages(language: String) {
        let original = LanguageManager.shared.language
        LanguageManager.shared.language = language
        defer { LanguageManager.shared.language = original }

        for limitation in [OwnershipStorageAdvisory.Limitation.noFileOwners(filesystemType: "exfat"),
                           OwnershipStorageAdvisory.Limitation.ignoredOwnership(filesystemType: "hfs")] {
            let message = limitation.advisoryMessage(driveName: "UD210")
            #expect(message.contains("UD210"), "\(language): drive name must survive")
            #expect(message.contains("chown") == false, "\(language): chown cannot work here")
            #expect(message.contains("sudo") == false, "\(language): sudo advice must be absent")
        }
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
