//
//  KeychainStore.swift
//  RTSPClient
//
//  历史记录只存地址和用户名，密码放钥匙串。
//

import Foundation
import Security

nonisolated enum KeychainStore {
    private static let service = "com.iosdevlog.RTSPClient.stream"

    /// 一条流对应一个账号项：地址 + 用户名。
    private static func account(identity: String, username: String) -> String {
        "\(identity)|\(username)"
    }

    static func savePassword(_ password: String, identity: String, username: String) {
        let account = account(identity: identity, username: username)
        guard !password.isEmpty else {
            deletePassword(identity: identity, username: username)
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(password.utf8),
            // 只在本机、解锁后可读，不参与 iCloud 同步。
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    static func password(identity: String, username: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(identity: identity, username: username),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deletePassword(identity: String, username: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(identity: identity, username: username),
        ]
        SecItemDelete(query as CFDictionary)
    }
}
