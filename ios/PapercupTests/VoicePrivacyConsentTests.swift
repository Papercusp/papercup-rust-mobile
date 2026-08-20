// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import PapercupCore
@testable import Papercup

final class VoicePrivacyConsentTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "VoicePrivacyConsentTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testCloudVoiceIsNotGrantedByDefault() {
        XCTAssertFalse(VoicePrivacyConsentStore.isGranted(defaults: defaults))
    }

    func testGrantPersistsExplicitConsent() {
        VoicePrivacyConsentStore.grant(defaults: defaults)
        XCTAssertTrue(VoicePrivacyConsentStore.isGranted(defaults: defaults))
    }

    func testRevokeRequiresConsentAgain() {
        VoicePrivacyConsentStore.grant(defaults: defaults)
        VoicePrivacyConsentStore.revoke(defaults: defaults)
        XCTAssertFalse(VoicePrivacyConsentStore.isGranted(defaults: defaults))
    }
}
