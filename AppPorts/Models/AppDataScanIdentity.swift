import Foundation

/// Running state and size updates do not change data-directory discovery.
struct AppDataScanIdentity: Equatable {
    let path: URL
    let displayURL: URL
    let version: String?
    let isResigned: Bool
    let signatureReplaced: Bool

    init(_ app: AppItem) {
        path = app.path.standardizedFileURL
        displayURL = app.displayURL.standardizedFileURL
        version = app.version
        isResigned = app.isResigned
        signatureReplaced = app.signatureReplaced
    }
}
