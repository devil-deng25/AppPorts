import Foundation
import Security
import LocalAuthentication

/// Credentials are transient. Only an explicit user choice writes them to the login keychain.
enum APFSVolumeEncryption {
    struct Credentials: Sendable {
        let passphrase: String
        let saveToKeychain: Bool
    }

    /// Thread-safe, process-local storage. Operation caches live until their operation is released.
    final class PassphraseCache: @unchecked Sendable {
        private struct Entry {
            let value: String
            let expiresAt: TimeInterval
        }
        private let lock = NSLock()
        private let lifetime: TimeInterval
        private var entries: [String: Entry] = [:]

        init(lifetime: TimeInterval) { self.lifetime = lifetime }

        func values() -> [String: String] {
            lock.lock(); defer { lock.unlock() }
            let now = ProcessInfo.processInfo.systemUptime
            entries = entries.filter { $0.value.expiresAt > now }
            return entries.mapValues(\.value)
        }

        func value(for uuid: String) -> String? { values()[uuid.uppercased()] }

        func remember(_ value: String, for uuid: String) {
            lock.lock(); defer { lock.unlock() }
            let now = ProcessInfo.processInfo.systemUptime
            entries = entries.filter { $0.value.expiresAt > now }
            entries[uuid.uppercased()] = Entry(value: value, expiresAt: now + lifetime)
        }

        func remove(_ uuid: String) {
            lock.lock(); defer { lock.unlock() }
            entries.removeValue(forKey: uuid.uppercased())
        }
    }

    private static let recentPassphrases = PassphraseCache(lifetime: 30 * 60)

    static func makeOperationCache() -> PassphraseCache {
        let cache = PassphraseCache(lifetime: .infinity)
        for (uuid, value) in recentPassphrases.values() { cache.remember(value, for: uuid) }
        return cache
    }

    /// Only call after diskutil has verified the password for this exact volume.
    static func rememberVerifiedPassphrase(_ value: String, for uuid: String) {
        recentPassphrases.remember(value, for: uuid)
        DataTransferSession.current?.volumePassphrases.remember(value, for: uuid)
    }

    static func reusablePassphrase(for uuid: String) throws -> String? {
        let value = DataTransferSession.current?.volumePassphrases.value(for: uuid)
            ?? recentPassphrases.value(for: uuid)
        if let value {
            rememberVerifiedPassphrase(value, for: uuid)
            return value
        }
        if let value = try savedPassphrase(for: uuid) {
            rememberVerifiedPassphrase(value, for: uuid)
            return value
        }
        return nil
    }

    static func forgetTransientPassphrase(for uuid: String) {
        recentPassphrases.remove(uuid)
        DataTransferSession.current?.volumePassphrases.remove(uuid)
    }

    enum Failure: LocalizedError {
        case invalidPassphrase, commandFailed, encryptionNotVerified, keychain(OSStatus)
        case waitingForUnlock(String)

        var errorDescription: String? {
            switch self {
            case .invalidPassphrase:
                return "密码不能为空，且不能包含换行或空字符，长度不能超过 1024 字节。".localized
            case .commandFailed:
                return "加密卷操作失败，请检查密码和磁盘访问权限后重试。".localized
            case .encryptionNotVerified:
                return "无法确认新数据卷已加密，已停止复制，原数据仍保留。".localized
            case .keychain:
                return "密码未能保存到本机钥匙串，已停止操作。请重试或取消保存密码。".localized
            case .waitingForUnlock:
                return "等待解锁：请解锁数据卷后重试。".localized
            }
        }
    }

    static func validate(_ passphrase: String) throws {
        guard !passphrase.isEmpty, passphrase.utf8.count <= 1024,
              !passphrase.contains("\n"), !passphrase.contains("\r"), !passphrase.contains("\0") else {
            throw Failure.invalidPassphrase
        }
    }

    private static func query(_ uuid: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.appports.encrypted-apfs-volume",
         kSecAttrAccount as String: uuid.uppercased(),
         kSecAttrSynchronizable as String: false]
    }

    static func savedPassphrase(for uuid: String) throws -> String? {
        var request = query(uuid)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        // Background remounting must never display keychain authentication dialogs.
        let context = LAContext()
        context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound || status == errSecInteractionNotAllowed || status == errSecAuthFailed { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw Failure.keychain(status) }
        return value
    }

    static func removeSavedPassphrase(for uuid: String) {
        forgetTransientPassphrase(for: uuid)
        var request = query(uuid)
        let context = LAContext()
        context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        _ = SecItemDelete(request as CFDictionary)
    }

    static func save(_ credentials: Credentials, for uuid: String) throws {
        try validate(credentials.passphrase)
        rememberVerifiedPassphrase(credentials.passphrase, for: uuid)
        guard credentials.saveToKeychain else { return }
        let request = query(uuid)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(credentials.passphrase.utf8),
            kSecAttrLabel as String: "AppPorts 加密数据卷".localized,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var item = request
        item.merge(attributes) { _, new in new }
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updated = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
            guard updated == errSecSuccess else { throw Failure.keychain(updated) }
        } else if status != errSecSuccess { throw Failure.keychain(status) }
    }
}
