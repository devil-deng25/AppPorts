import Darwin
import Foundation
import Testing
@testable import AppPorts

@Suite("Signature snapshot fingerprints")
struct SignatureSnapshotTests {
    struct Fixture: Sendable {
        let size: Int
        let fingerprint: String
    }

    // These persisted-format values were captured before adding chunk-scoped
    // autorelease pools. Empty files, exact boundaries and partial final chunks
    // must remain compatible with existing signature backup records.
    static let fixtures = [
        Fixture(size: 0, fingerprint: "d6480a1f99a13ea6072d2f63581f8a46618f1afebe66f5400959732ddf74267e"),
        Fixture(size: 1_048_575, fingerprint: "a6c1e4253d8cedb57d3437fd65be430d5a44273aa7d5b770a68a2bcd79a0ce91"),
        Fixture(size: 1_048_576, fingerprint: "9dda23c6540de65290210461e04fc4cf304c99e64e78fade10cb3c15c124b01b"),
        Fixture(size: 1_048_577, fingerprint: "4afd3b05ac65e29969804c881549f60aff99385010fb18b8c71931a00b4541e3"),
        Fixture(size: 2_097_169, fingerprint: "aa82522a77de7a96ed69e77a663ec0f3f81c7fcb631222ecf6c206d37b1b58c8")
    ]

    @Test("Chunked reads preserve historical backup fingerprints", arguments: fixtures)
    func preservesHistoricalFingerprints(fixture: Fixture) throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppPortsSignatureFingerprint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        var data = Data(repeating: 0xa5, count: fixture.size)
        if !data.isEmpty { data[data.count - 1] = 0x5a }
        try data.write(to: file)
        try #require(chmod(file.path, 0o600) == 0)

        #expect(try SignatureSnapshot.fingerprint(of: file) == fixture.fingerprint)
    }
}
