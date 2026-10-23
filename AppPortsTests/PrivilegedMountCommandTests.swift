import XCTest
@testable import AppPorts

/// 特权助手的命令白名单是这套「一次授权」方案的安全边界：它决定 root 会执行什么。
/// 这些用例把允许的形状和必然会拒绝的形状都钉住，避免以后为了省事把口子开大。
final class PrivilegedMountCommandTests: XCTestCase {
    func testAllowsMountAndUnmountOfContainerVolumes() {
        XCTAssertNotNil(PrivilegedMountCommand.validate(
            executable: "/usr/sbin/diskutil", arguments: ["mount", "/dev/disk4s1"]))
        XCTAssertNotNil(PrivilegedMountCommand.validate(
            executable: "/usr/sbin/diskutil", arguments: ["unmount", "/Volumes/AppPorts-X"]))
        XCTAssertNotNil(PrivilegedMountCommand.validate(
            executable: "/usr/sbin/diskutil", arguments: ["info", "-plist", "/dev/disk4s1"]))
        XCTAssertNotNil(PrivilegedMountCommand.validate(
            executable: "/sbin/mount", arguments: ["-u", "-o", "nobrowse,noowners", "/Volumes/AppPorts-X"]))
        XCTAssertNotNil(PrivilegedMountCommand.validate(
            executable: "/sbin/umount", arguments: ["/Volumes/AppPorts-X"]))
    }

    func testRejectsDestructiveDiskutilVerbs() {
        // 创建/删除/抹掉卷都是一次性操作，必须继续走会弹密码的一次性授权。
        for verb in ["deleteVolume", "eraseVolume", "rename", "resizeVolume", "addVolume"] {
            XCTAssertNil(PrivilegedMountCommand.validate(
                executable: "/usr/sbin/diskutil", arguments: [verb, "/dev/disk4s1"]), verb)
        }
        XCTAssertNil(PrivilegedMountCommand.validate(
            executable: "/usr/sbin/diskutil", arguments: ["apfs", "deleteVolume", "disk4"]))
    }

    func testRejectsArbitraryExecutablesAndShells() {
        XCTAssertNil(PrivilegedMountCommand.validate(executable: "/bin/sh", arguments: ["-c", "id"]))
        XCTAssertNil(PrivilegedMountCommand.validate(executable: "/usr/bin/curl", arguments: ["http://x"]))
        // 完全绕开 shell 也是设计的一部分：`do shell script` 的字符串通路不接助手。
        XCTAssertFalse(PrivilegedMountCommand.isSupported(executable: "/bin/sh", arguments: ["-c", "mount -u /"]))
    }

    func testRejectsRelativeOrTraversingPaths() {
        XCTAssertNil(PrivilegedMountCommand.validate(executable: "/sbin/umount", arguments: ["Volumes/X"]))
        XCTAssertNil(PrivilegedMountCommand.validate(executable: "/sbin/umount", arguments: ["/Volumes/../etc"]))
        XCTAssertNil(PrivilegedMountCommand.validate(executable: "/sbin/umount", arguments: ["/Volumes//X"]))
        XCTAssertNil(PrivilegedMountCommand.validate(executable: "/sbin/umount", arguments: ["/"]))
    }

    func testRejectsMountWithoutUpdateFlag() {
        // 不带 -u 的 mount 会挂新文件系统，超出「容器卷维护」的范围。
        XCTAssertNil(PrivilegedMountCommand.validate(
            executable: "/sbin/mount", arguments: ["/dev/disk4s1", "/Volumes/AppPorts-X"]))
        XCTAssertNil(PrivilegedMountCommand.validate(
            executable: "/sbin/mount", arguments: ["-u"]))
    }

    func testRejectsInjectedArguments() {
        XCTAssertNil(PrivilegedMountCommand.validate(
            executable: "/usr/sbin/diskutil", arguments: ["mount", "/dev/disk4s1\nrm -rf /"]))
        XCTAssertNil(PrivilegedMountCommand.validate(
            executable: "/sbin/umount", arguments: ["/Volumes/X\0"]))
        XCTAssertNil(PrivilegedMountCommand.validate(
            executable: "/usr/sbin/diskutil", arguments: ["mount", String(repeating: "a", count: 2048)]))
        XCTAssertNil(PrivilegedMountCommand.validate(
            executable: "/usr/sbin/diskutil", arguments: Array(repeating: "/dev/disk4s1", count: 20)))
    }

    func testRejectsUnexpectedFlagValues() {
        XCTAssertNil(PrivilegedMountCommand.validate(
            executable: "/sbin/mount", arguments: ["-u", "-o", "nobrowse /tmp", "/Volumes/X"]))
        XCTAssertNil(PrivilegedMountCommand.validate(
            executable: "/sbin/mount", arguments: ["-u", "-o"]))
    }
}
