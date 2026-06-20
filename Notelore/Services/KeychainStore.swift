import Foundation
import Security

/// Stores API keys in the iOS keychain. Keys never touch UserDefaults,
/// never appear in logs, and are removed on "delete all data".
struct KeychainStore: Sendable {
    private let service = "com.owaiskhan.notelore.keys"

    func apiKey(for provider: LLMProviderID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    func setAPIKey(_ key: String, for provider: LLMProviderID) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        // Clear any existing entr(ies) first, then add exactly one. This
        // reliable upsert avoids stale or duplicate keychain items, which can
        // otherwise read back empty and make a saved key look absent until a
        // validate rewrites it.
        deleteAPIKey(for: provider)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func deleteAPIKey(for provider: LLMProviderID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }

    func deleteAll() {
        for provider in LLMProviderID.allCases {
            deleteAPIKey(for: provider)
        }
    }
}
