import Foundation

struct DataDirReadIssue: Equatable, Sendable {
    let url: URL
    let isPermissionDenied: Bool
    let errorDescription: String

    init(url: URL, error: Error) {
        self.url = url.standardizedFileURL
        let errors = Self.errorChain(error)
        errorDescription = errors.map { "\($0.localizedDescription) (\($0.domain):\($0.code))" }.joined(separator: "\n")
        isPermissionDenied = errors.contains {
            ($0.domain == NSCocoaErrorDomain && $0.code == CocoaError.fileReadNoPermission.rawValue)
                || ($0.domain == NSPOSIXErrorDomain
                    && [Int(POSIXErrorCode.EACCES.rawValue), Int(POSIXErrorCode.EPERM.rawValue)].contains($0.code))
        }
    }

    static func isMissingFile(_ error: Error) -> Bool {
        errorChain(error).contains {
            ($0.domain == NSCocoaErrorDomain
                && [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains($0.code))
                || ($0.domain == NSPOSIXErrorDomain && $0.code == Int(POSIXErrorCode.ENOENT.rawValue))
        }
    }

    private static func errorChain(_ error: Error) -> [NSError] {
        var chain = [error as NSError]
        while chain.count < 8, let underlying = chain.last?.userInfo[NSUnderlyingErrorKey] as? NSError {
            chain.append(underlying)
        }
        return chain
    }
}

struct DataDirScanResult: Sendable {
    let items: [DataDirItem]
    let readIssues: [DataDirReadIssue]
    var identityIssue: AppIdentityIssue? = nil
}

struct DirectorySizeResult: Sendable {
    var bytes: Int64 = 0
    var readIssues: [DataDirReadIssue] = []

    var isComplete: Bool { readIssues.isEmpty }

    var formattedSize: String {
        let formattedBytes = LocalizedByteCountFormatter.string(fromByteCount: bytes)
        if isComplete { return formattedBytes }
        return bytes > 0
            ? String(format: "至少 %@".localized, formattedBytes)
            : "无法读取".localized
    }
}
