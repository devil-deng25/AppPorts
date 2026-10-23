import CryptoKit
import Darwin
import Foundation

/// Shared by AppPorts and its native portal launcher. Never unlink lock files:
/// all participants must keep referring to the same inode.
enum ApplicationLaunchGate {
    enum Failure: Error, Equatable { case busy, inspection }

    final class Lease: @unchecked Sendable {
        private let descriptor: Int32
        fileprivate init(_ descriptor: Int32) { self.descriptor = descriptor }
        deinit { close(descriptor) }
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppPorts/launch-locks", isDirectory: true)
    }

    static func acquire(bundleIdentifier: String, migrating: Bool,
                        directory: URL = defaultDirectory) throws -> Lease {
        guard !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.inspection }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw Failure.inspection }
        defer { close(parent) }
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw Failure.inspection }
        let name = SHA256.hash(data: Data(bundleIdentifier.utf8)).map { String(format: "%02x", $0) }.joined() + ".lock"
        let fd = openat(parent, name, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw Failure.inspection }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
            close(fd)
            throw Failure.inspection
        }
        guard flock(fd, (migrating ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            throw code == EWOULDBLOCK ? Failure.busy : .inspection
        }
        return Lease(fd)
    }

    static let busyMessage = "正在迁移或迁回应用数据，请等待完成后再打开。"
    static let unavailableMessage = "无法确认应用数据迁移状态，请打开 AppPorts 检查后重试。"
    static func message(busy: Bool, languages: [String] = Locale.preferredLanguages) -> String {
        PortalLocalizedStrings.text(busy ? busyMessage : unavailableMessage, languages: languages)
    }
}
