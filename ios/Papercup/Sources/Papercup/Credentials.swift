// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security

struct DeviceCredentials: Equatable {
    let server: String
    let deviceToken: String
    let deviceId: String
    let workspaceId: String
    /// Phase 6a: present when the desktop's pair response carried a Defguard
    /// mesh config. Display only for now.
    var meshAssignedIp: String? = nil
    /// Phase 6b: full wg-quick INI ready for WireGuardKit's tunnelConfiguration.
    var wgQuickConfig: String? = nil
    /// Phase 6b: device's WireGuard private key, base64.
    var wgPrivateKey: String? = nil
}

/// Keychain-backed credential store. Mirrors Android's EncryptedSharedPreferences
/// usage: a single record holds all four fields as a JSON blob under the
/// `papercup.credentials` account in `kSecClassGenericPassword`.
enum CredentialStore {
    private static let service = "com.papercuspai.operator.mobile"
    private static let account = "papercup.credentials"

    static func load() -> DeviceCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        guard
            let server = dict["server"],
            let token = dict["deviceToken"],
            let deviceId = dict["deviceId"],
            let workspaceId = dict["workspaceId"]
        else { return nil }
        return DeviceCredentials(
            server: server,
            deviceToken: token,
            deviceId: deviceId,
            workspaceId: workspaceId,
            meshAssignedIp: dict["meshAssignedIp"],
            wgQuickConfig: dict["wgQuickConfig"],
            wgPrivateKey: dict["wgPrivateKey"]
        )
    }

    static func save(_ creds: DeviceCredentials) {
        var dict: [String: String] = [
            "server": creds.server,
            "deviceToken": creds.deviceToken,
            "deviceId": creds.deviceId,
            "workspaceId": creds.workspaceId,
        ]
        if let ip = creds.meshAssignedIp { dict["meshAssignedIp"] = ip }
        if let q = creds.wgQuickConfig { dict["wgQuickConfig"] = q }
        if let p = creds.wgPrivateKey { dict["wgPrivateKey"] = p }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        clear()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
