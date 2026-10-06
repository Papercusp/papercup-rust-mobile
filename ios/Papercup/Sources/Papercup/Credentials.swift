// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import PapercupCore
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
    /// The pair response's `baseUrls` route list as raw JSON (D-018). A kind
    /// `relay` entry means a cloud (BYOC) workspace reached through the
    /// hosted relay rather than a desktop tunnel or LAN.
    var baseUrlsJson: String? = nil

    /// True when the stored route list advertises a hosted relay route.
    var isCloudRelay: Bool { DeviceCredentials.routesIncludeRelay(baseUrlsJson) }

    static func routesIncludeRelay(_ json: String?) -> Bool {
        guard let json, let data = json.data(using: .utf8),
              let routes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return false }
        return routes.contains { ($0["kind"] as? String) == "relay" }
    }

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
            defguardEnrollmentUrl: dict["defguardEnrollmentUrl"],
            baseUrlsJson: dict["baseUrlsJson"]
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
        if let b = creds.baseUrlsJson, !b.isEmpty { dict["baseUrlsJson"] = b }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        clear()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            // The pairing still works for this launch (creds live in memory)
            // but will not survive a relaunch — make that diagnosable.
            NSLog("CredentialStore.save failed: OSStatus %d", status)
        }
    }

    static let installMarkerKey = "papercup.installMarker.v1"

    /// iOS keeps Keychain items after the app is DELETED, but wipes the
    /// app's UserDefaults. Without this, a "clean install" silently resumed
    /// the previous install's pairing — possibly a revoked device or another
    /// workspace — and skipped onboarding (P-008 / WI-10004735). The first
    /// launch of each install (no marker yet) clears stored credentials.
    /// Returns true when it cleared. Note: an upgrade from a build that
    /// predates the marker is also treated as fresh once (pre-1.0 only).
    @discardableResult
    static func resetIfFreshInstall(
        defaults: UserDefaults = .standard,
        clearStored: () -> Void = { CredentialStore.clear() }
    ) -> Bool {
        guard !defaults.bool(forKey: installMarkerKey) else { return false }
        clearStored()
        defaults.set(true, forKey: installMarkerKey)
        return true
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
