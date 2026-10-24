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

    /// 真实镜像上跑一遍，专门钉住 `snapshot(of:)` 的标志位。
    ///
    /// `SecCodeCopySigningInformation` 默认标志位返回的字典里**没有** `certificates`，
    /// 只有加了 `kSecCSSigningInformation` 才有。少了它，证书那一层永远不命中，
    /// 所有构建都会静默退化成 adhoc —— 而这种故障不会报错，只会表现成「换不换签名
    /// 都要重装助手」，没法从现象倒推。系统二进制一定带证书，拿它当基准最稳。
    func testReadingARealBinaryExposesItsCertificate() throws {
        var staticCode: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(URL(fileURLWithPath: "/bin/cp") as CFURL,
                                                SecCSFlags(rawValue: 0), &staticCode)
        let code = try XCTUnwrap(staticCode, "无法读取 /bin/cp 的静态代码（status \(status)）")
        let snapshot = try XCTUnwrap(CodeIdentity.snapshot(of: code), "读不到 /bin/cp 的签名信息")
        XCTAssertFalse(snapshot.identifier.isEmpty)
        XCTAssertNotNil(snapshot.leafCertificateDigest, "系统二进制带证书，读不到说明取签名信息时漏了 kSecCSSigningInformation")
        XCTAssertNotNil(snapshot.cdHash)
        let fingerprint = CodeIdentity.fingerprint(snapshot)
        XCTAssertTrue(fingerprint.hasPrefix("cert|") || fingerprint.hasPrefix("team|"),
                      "有证书却落到别的层级：\(fingerprint)")
    }
}
