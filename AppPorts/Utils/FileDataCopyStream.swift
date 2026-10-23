import Darwin
import Foundation

/// One bounded data-fork write at a time. Callers retain their descriptors and
/// decide whether progress reporting is synchronous or requires an actor hop.
/// This is shared by verified data copies and older-libcopyfile bundle copies.
struct FileDataCopyStream {
    typealias ExtentSeek = @Sendable (Int32, off_t, Int32) -> off_t
    static let bufferByteCount = 1_048_576

    private let source: Int32
    private let destination: Int32
    private let size: Int64
    private let path: String
    private let extentSeek: ExtentSeek
    private var offset: off_t = 0
    private var extentEnd: off_t = 0
    private var holes: [(off_t, off_t)] = []
    private var buffer: [UInt8]
    private var finished = false
    private(set) var usesExtentFallback = false

    /// A transparently compressed file (UF_COMPRESSED) stores a compressed
    /// data stream, and SEEK_DATA/SEEK_HOLE describe those physical extents.
    /// Reading them positionally hands back compressed bytes, so the logical
    /// content never arrives and verification fails. Such files take the plain
    /// sequential path, which decodes on read like any ordinary read(2).
    init(from source: Int32, to destination: Int32, size: Int64, path: String,
         extentSeek: @escaping ExtentSeek = { lseek($0, $1, $2) },
         isCompressed: Bool = false) {
        self.source = source
        self.destination = destination
        self.size = size
        self.path = path
        self.extentSeek = extentSeek
        usesExtentFallback = isCompressed
        buffer = [UInt8](repeating: 0, count: max(1, min(Self.bufferByteCount, Int(clamping: size))))
    }

    /// Returns the logical end of the chunk just written. A nil result means
    /// logical size and sparse holes have also been applied successfully.
    mutating func copyNextChunk() throws -> Int64? {
        guard !finished else { return nil }
        try Task.checkCancellation()
        while offset < size {
            if usesExtentFallback || offset < extentEnd {
                let end = usesExtentFallback ? off_t(size) : extentEnd
                let count = try copyChunk(until: end)
                offset += off_t(count)
                return Int64(offset)
            }
            let data = extentSeek(source, offset, SEEK_DATA)
            if data < 0 {
                if errno == ENXIO { holes.append((offset, size)); offset = size; break }
                if errno == ENOTSUP || errno == EINVAL {
                    // Restart from zero exactly as the data copier did before
                    // sharing this primitive; a failed seek never implies EOF.
                    offset = 0
                    usesExtentFallback = true
                    continue
                }
                throw failure()
            }
            if data > offset { holes.append((offset, min(data, size))) }
            let hole = extentSeek(source, data, SEEK_HOLE)
            guard hole > data else { throw TreeCopyError.sourceChanged(path) }
            offset = data
            extentEnd = min(hole, size)
        }
        try finish()
        finished = true
        return nil
    }

    private mutating func copyChunk(until end: off_t) throws -> Int {
        let count: Int
        while true {
            try Task.checkCancellation()
            let wanted = min(buffer.count, Int(end - offset))
            let read = pread(source, &buffer, wanted, offset)
            if read < 0, errno == EINTR { continue }
            guard read > 0 else { throw TreeCopyError.sourceChanged(path) }
            count = read
            break
        }
        try buffer.withUnsafeBytes { bytes in
            var written = 0
            while written < count {
                try Task.checkCancellation()
                let result = pwrite(destination, bytes.baseAddress!.advanced(by: written), count - written, offset + off_t(written))
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw failure() }
                written += result
            }
        }
        return count
    }

    private func finish() throws {
        try Task.checkCancellation()
        guard ftruncate(destination, size) == 0 else { throw failure() }
        guard !usesExtentFallback else { return }
        // APFS may eagerly allocate holes during extension. Re-punch only the
        // source's observed gaps, with the same alignment as the data copier.
        var filesystem = statfs()
        guard fstatfs(destination, &filesystem) == 0 else { throw failure() }
        let block = off_t(filesystem.f_bsize)
        guard block > 0 else {
            throw TreeCopyError.unsupportedMetadata(path, details: String(format: "检查目标端存储块大小失败：fstatfs 返回 f_bsize=%@，无法处理稀疏文件。".localized, String(filesystem.f_bsize)))
        }
        for (start, end) in holes {
            let alignedStart = ((start + block - 1) / block) * block
            let alignedEnd = (end / block) * block
            guard alignedEnd > alignedStart else { continue }
            var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: alignedStart, fp_length: alignedEnd - alignedStart)
            if fcntl(destination, F_PUNCHHOLE, &hole) != 0, errno != ENOTSUP, errno != EINVAL { throw failure() }
        }
    }

    private func failure() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
    }
}
