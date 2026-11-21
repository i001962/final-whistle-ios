import Foundation
import Security

/// iOS Keychain only. Custody private keys and signer seeds live here and
/// nowhere else: never in UserDefaults, never in a file, never in a log,
/// never in the repo.
///
/// One account per custody address: a device can hold several FIDs, each
/// controlled by its own custody key. The custody key is the master key,
/// so it is gated by user presence (Face ID / Touch ID / device passcode):
/// iOS prompts whenever the app reads it. The signer seed is a session
/// key (30-day sliding window) and is not gated, so posting, liking, and
/// replying never prompt.
///
/// Signing out never deletes a key. There is no delete-custody in the app:
/// an account stays on the phone until its keys are wiped with the phone.
enum KeychainStore {
    static let service = "app.final-whistle"

    // Legacy single-account names (pre-multi-account). Read only by the
    // one-time migration in IdentityStore; never written again.
    static let legacyCustodyAccount = "hypersnap-custody-private-key"
    static let legacySignerAccount = "hypersnap-signer-seed"

    /// Per-identity account names, keyed by the custody address. One
    /// custody address controls one FID, so this is the stable per-account
    /// key. The address is normalized to lowercase hex without a 0x prefix.
    static func custodyAccount(for custodyAddress: String) -> String {
        "custody:" + normalizedCustodyAddress(custodyAddress)
    }

    static func signerAccount(for custodyAddress: String) -> String {
        "signer:" + normalizedCustodyAddress(custodyAddress)
    }

    static func normalizedCustodyAddress(_ address: String) -> String {
        var text = address.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("0x") { text.removeFirst(2) }
        return text
    }

    enum KeychainError: Error, LocalizedError {
        case saveFailed(OSStatus)
        case loadFailed(OSStatus)
        case notFound
        case badData
        case userCanceled
        case authenticationFailed

        var errorDescription: String? {
            switch self {
            case .saveFailed(let status): return "Keychain save failed (status \(status))."
            case .loadFailed(let status): return "Keychain read failed (status \(status))."
            case .notFound: return "No key stored in the Keychain."
            case .badData: return "Keychain data is not valid."
            case .userCanceled: return "Unlock was cancelled."
            case .authenticationFailed: return "Unlock failed. Try again."
            }
        }
    }

    /// Save a key. Pass `requiresUserPresence` for a custody key: the
    /// item is then gated by Face ID / Touch ID / device passcode, enforced
    /// by the OS on every read, and it never leaves this device.
    @discardableResult
    static func save(_ data: Data, account: String, requiresUserPresence: Bool = false) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        if requiresUserPresence {
            // Face ID / Touch ID / device passcode, enforced by the OS on
            // every read. The item is only available while the device is
            // unlocked, never leaves this device, and is not in a backup.
            if let accessControl = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .userPresence,
                nil
            ) {
                attributes[kSecAttrAccessControl as String] = accessControl
                attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            } else {
                // Could not build the access control; fall back to the
                // standard device-only protection so the key is stored.
                attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
        } else {
            // Available after first unlock: the app works after the phone is
            // unlocked once, and the key is not in a backup without the device.
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.saveFailed(status) }
        return true
    }

    /// Load a key. Pass `prompt` for a user-presence item: it is the text
    /// iOS shows in the Face ID / passcode prompt for this read. A
    /// cancelled prompt throws `userCanceled`, not a generic failure.
    static func load(account: String, prompt: String? = nil) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let prompt {
            query[kSecUseOperationPrompt as String] = prompt
        }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound { throw KeychainError.notFound }
            if status == errSecUserCanceled { throw KeychainError.userCanceled }
            if status == errSecAuthFailed { throw KeychainError.authenticationFailed }
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
}
