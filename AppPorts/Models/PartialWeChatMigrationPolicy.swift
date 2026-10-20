import Foundation

/// Split layout proposed by du-yuxuan in AppPorts issue #79.
/// Exact account boundaries; database/configuration trees never enter the split whitelist.
struct PartialWeChatMigrationPolicy: Sendable {
    static let bundleIdentifier = "com.tencent.xinWeChat"
    static let memberNames = ["msg", "business"]
    let homeDirectory: URL

    init(homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    var accountsRoot: URL {
        homeDirectory.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files")
    }

    func isAccount(_ url: URL) -> Bool {
        let normalized = url.standardizedFileURL
        let path = normalized.pathComponents
        let root = accountsRoot.pathComponents
        return path.starts(with: root) && path.count == root.count + 1
            && !["all_users", "config", "resource"].contains(normalized.lastPathComponent)
    }

    func account(forMember url: URL) -> URL? {
        let parent = url.standardizedFileURL.deletingLastPathComponent()
        return Self.memberNames.contains(url.lastPathComponent) && isAccount(parent) ? parent : nil
    }

    func members(of account: URL) -> [URL] {
        Self.memberNames.map { account.appendingPathComponent($0).standardizedFileURL }
    }
}
