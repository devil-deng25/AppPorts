import XCTest
@testable import AppPorts

/// 信任判断的核心是「把两份签名压成同一个字符串再比」。这段逻辑决定了
/// 「重新编译一次」要不要让用户重装助手，因此单独测，不依赖真实签名。
final class CodeIdentityTests: XCTestCase {
    private func snapshot(identifier: String = "com.shimoko.AppPorts",
                          team: String? = nil,
                          certificate: String? = nil,
                          cdHash: String? = nil) -> CodeIdentity.Snapshot {
        CodeIdentity.Snapshot(
            identifier: identifier,
            teamIdentifier: team,
            leafCertificateDigest: certificate,
            cdHash: cdHash
        )
    }

    func testTeamIdentifierWinsOverEverythingElse() {
        let value = snapshot(team: "MQ7XG7WM3F", certificate: "abc123", cdHash: "xyz")
        XCTAssertEqual(CodeIdentity.fingerprint(value), "team|com.shimoko.AppPorts|MQ7XG7WM3F")
    }

    /// 同一张证书重新构建出来的镜像 cdhash 一定不同，但指纹必须一致，
    /// 否则「装一次长期有效」不成立。
    func testRebuildWithSameCertificateKeepsTheSameFingerprint() {
        let first = snapshot(team: "MQ7XG7WM3F", cdHash: "build-1")
        let second = snapshot(team: "MQ7XG7WM3F", cdHash: "build-2")
        XCTAssertEqual(CodeIdentity.fingerprint(first), CodeIdentity.fingerprint(second))
    }

    func testSelfSignedCertificateIsUsedWhenThereIsNoTeamIdentifier() {
        let value = snapshot(certificate: "0123456789abcdef", cdHash: "build-1")
        XCTAssertEqual(CodeIdentity.fingerprint(value), "cert|com.shimoko.AppPorts|0123456789abcdef")
    }

    func testAdHocSignatureFallsBackToCDHash() {
        let value = snapshot(cdHash: "STxJ9tbp8dPmPnOq7sDaF5gRLPo=")
        XCTAssertEqual(CodeIdentity.fingerprint(value), "adhoc|com.shimoko.AppPorts|STxJ9tbp8dPmPnOq7sDaF5gRLPo=")
    }

    /// adhoc 构建每次出包指纹都会变，这正是它必须重装助手的原因；
    /// 这条用例把「无法避免」写成断言，避免以后误以为改了比较逻辑就能绕开。
    func testAdHocRebuildChangesTheFingerprint() {
        let first = snapshot(cdHash: "build-1")
        let second = snapshot(cdHash: "build-2")
        XCTAssertNotEqual(CodeIdentity.fingerprint(first), CodeIdentity.fingerprint(second))
    }

    func testUnsignedCodeKeepsOnlyTheIdentifier() {
        XCTAssertEqual(CodeIdentity.fingerprint(snapshot()), "unsigned|com.shimoko.AppPorts")
    }

    func testDifferentTeamMeansDifferentIdentity() {
        let ours = snapshot(team: "MQ7XG7WM3F")
        let theirs = snapshot(team: "ABCDE12345")
        XCTAssertNotEqual(CodeIdentity.fingerprint(ours), CodeIdentity.fingerprint(theirs))
    }

    /// 指纹可以很长，提示里只放人看得懂的一段。
    func testShortKindKeepsTheReadablePart() {
        XCTAssertEqual(CodeIdentity.shortKind("team|com.shimoko.AppPorts|MQ7XG7WM3F"), "team:MQ7XG7WM3F")
        XCTAssertEqual(CodeIdentity.shortKind("cert|com.shimoko.AppPorts|0123456789abcdef"), "cert:0123456789ab")
        XCTAssertEqual(CodeIdentity.shortKind("adhoc|com.shimoko.AppPorts|STxJ9tbp8dPm"), "adhoc:STxJ9tbp")
        XCTAssertEqual(CodeIdentity.shortKind("unexpected"), "unexpected")
    }
}
