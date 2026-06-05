// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security

struct DeviceCredentials: Equatable {
    let server: String
    var deviceToken: String
    let deviceId: String
    var workspaceId: String
    /// Mesh = Defguard self-enrollment (mobile-apps-revival D-005). The
    /// pair response carries an enrollment URL the user opens to join the
    /// mesh via Defguard; the app no longer brings up a WireGuard tunnel
    /// itself. Reachability falls back to the public `server` URL (and
    /// LAN) transparently, so there's no mesh URL to prefer at the client.
    var defguardEnrollmentUrl: String? = nil

    /// Build an OperatorClient against the desktop. Mesh routing (when the
    /// device is Defguard-enrolled) is transparent at the network layer;
    /// otherwise the public tunnel / LAN `server` URL reaches the desktop.
    func client() -> OperatorClient {
        OperatorClient(baseUrl: server, deviceToken: deviceToken)
    }
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
            defguardEnrollmentUrl: dict["defguardEnrollmentUrl"]
        )
    }

    static func save(_ creds: DeviceCredentials) {
        var dict: [String: String] = [
            "server": creds.server,
            "deviceToken": creds.deviceToken,
            "deviceId": creds.deviceId,
            "workspaceId": creds.workspaceId,
        ]
        if let u = creds.defguardEnrollmentUrl { dict["defguardEnrollmentUrl"] = u }
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
