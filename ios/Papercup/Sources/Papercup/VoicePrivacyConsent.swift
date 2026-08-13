// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Persists the user's explicit permission to send voice data to the
/// third-party cloud voice path. Desktop-local voice never consults this
/// setting because its audio stays between the phone and paired desktop.
enum VoicePrivacyConsentStore {
    private static let key = "papercup.cloudVoiceConsent.v1"

    static func isGranted(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func grant(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }

    static func revoke(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
