import CryptoKit
import Darwin
import Foundation

/// 签名包含 Mach-O 内嵌数据、嵌套代码和扩展属性，必须保存完整应用，不能只保存证书名称。
enum SignatureSnapshot {
    static func copy(from source: URL, to destination: URL) throws {
        // CLONE 在支持的文件系统上使用写时复制，不支持时 copyfile 正常复制；不跟随链接。
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW_SRC)
        if copyfile(source.path, destination.path, nil, flags | copyfile_flags_t(COPYFILE_CLONE)) != 0 {
            // 某些锁定文件被 clone 后立即带 uchg，后续元数据复制会失败；用常规复制重试。
            try remove(destination)
            guard copyfile(source.path, destination.path, nil, flags) == 0 else {
                throw posixError(at: destination)
            }
        }
    }

    static func items(in root: URL) throws -> [URL] {
        // 按相对文件名构造 URL，避免 DirectoryEnumerator 把 /var 转成 /private/var，
        // 造成源路径和副本的相对路径摘要不一致。
        var result: [URL] = []
        var pending = [root]
        while let item = pending.popLast() {
            result.append(item)
            if try info(at: item).st_mode & S_IFMT == S_IFDIR {
                let names = try FileManager.default.contentsOfDirectory(atPath: item.path)
                pending.append(contentsOf: names.map { item.appendingPathComponent($0) })
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    static func info(at url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw posixError(at: url) }
        return value
    }

    /// 路径无关的内容摘要：移动应用不会失效；更新、丢失文件或签名属性变化会失效。
    /// 不包含时间戳、quarantine 等系统会自行修改的元数据；所有读取失败均中止操作。
    static func fingerprint(of root: URL) throws -> String {
        var hash = SHA256()
        func field(_ data: Data) {
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
            hash.update(data: data)
        }
        for url in try items(in: root) {
            let stat = try info(at: url)
            let kind = stat.st_mode & S_IFMT
            field(Data(url.path.dropFirst(root.path.count).utf8))
            field(Data(String(kind).utf8))
            field(Data(String(stat.st_mode & 0o7777).utf8))
            switch kind {
            case S_IFREG:
                let input = try FileHandle(forReadingFrom: url)
                defer { try? input.close() }
                var contents = SHA256()
                while true {
                    // FileHandle 的 NSData 桥接会延迟释放；逐块排空，避免多次应用校验
                    // 把累计读取的 GB 级数据留在同一个同步 actor 任务的自动释放池中。
                    let hasData = try autoreleasepool {
                        guard let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty else {
                            return false
                        }
                        contents.update(data: data)
                        return true
                    }
                    if !hasData { break }
                }
                field(Data(contents.finalize()))
            case S_IFLNK:
                field(Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8))
            case S_IFDIR:
                break
            default:
                throw CodeSigner.SigningError.backupFailed("应用包含无法备份的特殊文件".localized)
            }
            // 脚本等非 Mach-O 代码的签名保存在 com.apple.cs.* 属性中。
            let count = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
            if count < 0 {
                if errno == ENOTSUP { field(Data("0".utf8)); continue }
                throw posixError(at: url)
            }
            var names = [CChar](repeating: 0, count: count)
            let read = names.withUnsafeMutableBufferPointer {
                listxattr(url.path, $0.baseAddress, count, XATTR_NOFOLLOW)
            }
            guard read >= 0 else { throw posixError(at: url) }
            let attributes = names.prefix(read).split(separator: 0).map {
                String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }.filter {
                $0.hasPrefix("com.apple.cs.") || $0 == "com.apple.ResourceFork" || $0 == "com.apple.FinderInfo"
            }.sorted()
            field(Data(String(attributes.count).utf8))
            for name in attributes {
                field(Data(name.utf8))
                let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
                guard size >= 0 else { throw posixError(at: url) }
                var data = Data(count: size)
                let readSize = data.withUnsafeMutableBytes {
                    getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW)
                }
                guard readSize == size else { throw posixError(at: url) }
                field(data)
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// codesign --deep 不能通过工作副本里的链接修改包外代码（包括原应用）。
    static func validateLinksForSigning(in root: URL) throws {
        let prefix = root.resolvingSymlinksInPath().path + "/"
        for url in try items(in: root) where try info(at: url).st_mode & S_IFMT == S_IFLNK {
            guard url.resolvingSymlinksInPath().path.hasPrefix(prefix) else {
                throw CodeSigner.SigningError.codesignFailed("应用包含指向包外的符号链接，已停止重签名以保护原始文件。".localized)
            }
        }
    }

    /// 同卷交换，失败时两边都保持原样。明确拒绝不支持该能力的存储，不降级为先删后复制。
    static func exchange(_ current: URL, _ replacement: URL) throws {
        guard renameatx_np(AT_FDCWD, current.path, AT_FDCWD, replacement.path, UInt32(RENAME_SWAP)) == 0 else {
            if errno == ENOTSUP || errno == EXDEV {
                throw CodeSigner.SigningError.atomicReplacementUnavailable
            }
            throw posixError(at: current)
        }
    }

    /// 仅用于我们自己创建的快照和工作副本；不跟随链接解除 uchg。
    static func remove(_ root: URL) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        for url in try items(in: root) {
            let stat = try info(at: url)
            if stat.st_flags & UInt32(UF_IMMUTABLE) != 0,
               lchflags(url.path, stat.st_flags & ~UInt32(UF_IMMUTABLE)) != 0 {
                throw posixError(at: url)
            }
        }
        try FileManager.default.removeItem(at: root)
    }

    private static func posixError(at url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }
}
