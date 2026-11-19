import Foundation
import Security

/// iOS Keychain only. Custody private keys and signer seeds live here and
/// nowhere else: never in UserDefaults, never in a file, never in a log,
/// never in the repo. Deleting the identity wipes these items.
enum KeychainStore {
    static let service = "app.final-whistle"
    static let custodyAccount = "hypersnap-custody-private-key"
    static let signerAccount = "hypersnap-signer-seed"

    enum KeychainError: Error, LocalizedError {
        case saveFailed(OSStatus)
        case loadFailed(OSStatus)
        case notFound
        case badData

        var errorDescription: String? {
            switch self {
            case .saveFailed(let status): return "Keychain save failed (status \(status))."
            case .loadFailed(let status): return "Keychain load failed (status \(status))."
            case .notFound: return "No key stored in the Keychain."
            case .badData: return "Keychain data is not valid."
            }
        }
    }

    @discardableResult
    static func save(_ data: Data, account: String) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        // Available after first unlock: the app works after the phone is
        // unlocked once, and the key is not in a backup without the device.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.saveFailed(status) }
        return true
    }

    static func load(account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound { throw KeychainError.notFound }
            throw KeychainError.loadFailed(status)
        }
        guard let data = result as? Data else { throw KeychainError.badData }
        return data
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func deleteAllIdentityKeys() {
        delete(account: custodyAccount)
        delete(account: signerAccount)
    }
}
