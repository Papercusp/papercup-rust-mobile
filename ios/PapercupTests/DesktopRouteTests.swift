// SPDX-License-Identifier: GPL-3.0-or-later
//
// P-015 / WI-10006857 (iphone-public-release D-014): a cloud (BYOC or
// hosted) workspace advertises its portal relay URL as baseUrls kind
// `relay`. The desktop-local voice transport must parse it like any other
// HTTPS route, keep advertised preference order, never drop a kind it does
// not know, and label the relay route for Settings/Diagnostics.

import XCTest
@testable import Papercup

final class DesktopRouteTests: XCTestCase {

    func testRelayKindIsParsedTrimmedAndKeptInAdvertisedOrder() {
        let p = DesktopVoiceSession.InitPayload.from(json: [
            "baseUrls": [
                ["kind": "relay", "url": "https://portal.example.com/w/acme/device/"],
                ["kind": "tunnel", "url": "https://desk.example.com"],
            ],
        ])
        XCTAssertEqual(p.routes.map { $0.kind }, ["relay", "tunnel"])
        XCTAssertEqual(p.routes.first?.url, "https://portal.example.com/w/acme/device",
                       "trailing slash is trimmed so path joins stay single-slash")
    }

    func testUnknownFutureKindIsKeptNotDropped() {
        let p = DesktopVoiceSession.InitPayload.from(json: [
            "baseUrls": [["kind": "satellite", "url": "https://s.example.com"]],
        ])
        XCTAssertEqual(p.routes.map { $0.kind }, ["satellite"])
    }

    func testMissingKindStillDefaultsToLan() {
        let p = DesktopVoiceSession.InitPayload.from(json: [
            "baseUrls": [["url": "http://192.168.1.20:3070"]],
        ])
        XCTAssertEqual(p.routes.map { $0.kind }, ["lan"])
    }

    func testRouteLabels() {
        XCTAssertEqual(DesktopVoiceSession.Route(kind: "relay", url: "https://r").label, "cloud relay")
        XCTAssertEqual(DesktopVoiceSession.Route(kind: "mesh", url: "http://10.10.0.2:3070").label, "mesh")
        XCTAssertEqual(DesktopVoiceSession.Route(kind: "tunnel", url: "https://t").label, "tunnel")
    }

    func testPairingNamesCloudWorkspaceWhenAnyAdvertisedRouteIsRelay() {
        let creds = DeviceCredentials(
            server: "https://portal.example.com/w/acme/device",
            deviceToken: "test-token",
            deviceId: "test-device",
            workspaceId: "acme",
            baseUrlsJson: """
                [{"kind":"lan","url":"http://192.168.1.20:3070"},
                 {"kind":"relay","url":"https://portal.example.com/w/acme/device"}]
                """
        )
        XCTAssertTrue(creds.isCloudRelay)
        XCTAssertEqual(creds.pairedOperatorLabel, "Cloud workspace")
    }

    func testPairingKeepsDesktopLabelWithoutAnAdvertisedRelay() {
        for routes in [nil, "", "not-json", "{}", "[]",
                       "[{\"kind\":\"tunnel\",\"url\":\"https://desk.example.com\"}]",
                       "[{\"kind\":\"satellite\",\"url\":\"https://future.example.com\"}]"] as [String?] {
            let creds = DeviceCredentials(
                server: "https://desk.example.com",
                deviceToken: "test-token",
                deviceId: "test-device",
                workspaceId: "acme",
                baseUrlsJson: routes
            )
            XCTAssertFalse(creds.isCloudRelay, "routes: \(String(describing: routes))")
            XCTAssertEqual(creds.pairedOperatorLabel, "Desktop",
                           "routes: \(String(describing: routes))")
        }
    }
}
