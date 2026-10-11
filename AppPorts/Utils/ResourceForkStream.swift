import CryptoKit
import Darwin
import Foundation

/// Resource forks are file contents, despite appearing in the xattr list.
/// Keep their bytes out of manifests and never allocate their logical size.
enum ResourceForkStream {
    static let attributeName = "com.apple.ResourceFork"
    static let bufferByteCount = 1_048_576

    /// The caller owns both descriptors for this handle's lifetime. Ordinary
    /// offsets use the fd xattr API, including filesystems with AppleDouble.
    /// Darwin's xattr offset is only UInt32; larger offsets use an inode-bound
    /// named fork and 64-bit pread/pwrite, without creating through a pathname.
    final class Handle {
        let fileDescriptor: Int32
        let parentDescriptor: Int32
        let name: String
        let path: String
        private let writable: Bool
        private var namedDescriptor: Int32?

        init(fileDescriptor: Int32, parentDescriptor: Int32, name: String, path: String,
             writable: Bool = false) {
            self.fileDescriptor = fileDescriptor
            self.parentDescriptor = parentDescriptor
            self.name = name
            self.path = path
            self.writable = writable
        }

        deinit { if let namedDescriptor { close(namedDescriptor) } }

        func size() throws -> Int64? {
            let count = fgetxattr(fileDescriptor, attributeName, nil, 0, 0, 0)
            if count < 0 {
                if errno == ENOATTR { return nil }
                throw failure()
            }
            return Int64(count)
        }

        func read(into buffer: UnsafeMutableRawBufferPointer, at offset: Int64) throws -> Int {
            guard offset >= 0 else { throw failure(EINVAL) }
            while true {
                try Task.checkCancellation()
                let count: Int
                if let position = UInt32(exactly: offset) {
                    count = fgetxattr(fileDescriptor, attributeName, buffer.baseAddress, buffer.count, position, 0)
                } else {
                    count = pread(try largeOffsetDescriptor(), buffer.baseAddress, buffer.count, off_t(offset))
                }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw failure() }
                return count
            }
        }

        func write(_ buffer: UnsafeRawBufferPointer, at offset: Int64) throws {
            guard writable, offset >= 0 else { throw failure(EINVAL) }
            if let position = UInt32(exactly: offset) {
                while true {
                    try Task.checkCancellation()
                    if fsetxattr(fileDescriptor, attributeName, buffer.baseAddress, buffer.count, position, 0) == 0 { return }
                    if errno != EINTR { throw failure() }
                }
            }
            let descriptor = try largeOffsetDescriptor()
            var written = 0
            while written < buffer.count {
                try Task.checkCancellation()
                let count = pwrite(descriptor, buffer.baseAddress?.advanced(by: written), buffer.count - written,
                                   off_t(offset + Int64(written)))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw failure(count == 0 ? EIO : errno) }
                written += count
            }
        }

        /// Remove an inherited fork before a fresh copy. This always acts on
        /// the already claimed destination inode, never a replacement path.
        func clear() throws {
            guard writable else { throw failure(EBADF) }
            if fremovexattr(fileDescriptor, attributeName, 0) != 0, errno != ENOATTR { throw failure() }
        }

        func synchronize() throws {
            if let namedDescriptor, fsync(namedDescriptor) != 0 { throw failure() }
            guard fsync(fileDescriptor) == 0 else { throw failure() }
        }

        private func largeOffsetDescriptor() throws -> Int32 {
            if let namedDescriptor { return namedDescriptor }
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { throw failure(EINVAL) }
            var original = stat()
            guard fstat(fileDescriptor, &original) == 0 else { throw failure() }
            guard original.st_mode & S_IFMT == S_IFREG else { throw failure(EINVAL) }
            // No O_CREAT/O_TRUNC: writable forks already exist from the first
            // fd-based chunk. Opening a raced name cannot modify another file.
            let descriptor = openat(parentDescriptor, name + "/..namedfork/rsrc",
                                    (writable ? O_RDWR : O_RDONLY) | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw failure() }
            var accepted = false
            defer { if !accepted { close(descriptor) } }
            var fork = stat()
            var named = stat()
            guard fstat(descriptor, &fork) == 0,
                  fstatat(parentDescriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure() }
            guard fork.st_mode & S_IFMT == S_IFREG, named.st_mode & S_IFMT == S_IFREG,
                  fork.st_dev == original.st_dev, fork.st_ino == original.st_ino,
                  named.st_dev == original.st_dev, named.st_ino == original.st_ino else { throw failure(ESTALE) }
            namedDescriptor = descriptor
            accepted = true
            return descriptor
        }

        private func failure(_ code: Int32 = errno) -> NSError {
            NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
        }
    }

    static func forEachChunk(in handle: Handle, byteCount: Int64,
                             _ body: (UnsafeRawBufferPointer) throws -> Void) throws {
        guard byteCount >= 0 else { throw TreeCopyError.verificationFailed(handle.path) }
        var buffer = [UInt8](repeating: 0, count: bufferByteCount)
        var offset: Int64 = 0
        while offset < byteCount {
            try Task.checkCancellation()
            let wanted = min(buffer.count, Int(byteCount - offset))
            let count = try buffer.withUnsafeMutableBytes {
                try handle.read(into: UnsafeMutableRawBufferPointer(rebasing: $0.prefix(wanted)), at: offset)
            }
            guard count > 0, count <= wanted else { throw TreeCopyError.sourceChanged(handle.path) }
            try buffer.withUnsafeBytes { try body(UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
            offset += Int64(count)
        }
        try Task.checkCancellation()
    }

    static func digest(in handle: Handle, byteCount: Int64) throws -> Data {
        var hash = SHA256()
        try forEachChunk(in: handle, byteCount: byteCount) { hash.update(bufferPointer: $0) }
        return Data(hash.finalize())
    }

    /// Compatibility reads may already contain a historical raw fork value.
    /// Hash that storage in place; do not create another fork-sized Data value.
    static func digest(of data: Data) throws -> Data {
        var hash = SHA256()
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let end = min(bytes.count, offset + bufferByteCount)
                hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[offset..<end]))
                offset = end
            }
        }
        return Data(hash.finalize())
    }
}
