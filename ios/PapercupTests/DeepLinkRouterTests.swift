// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import Papercup

@MainActor
final class DeepLinkRouterTests: XCTestCase {
    func testHarnessUrlSetsPendingSlug() {
        let router = DeepLinkRouter.shared
        router.pendingSlug = nil
        let ok = router.handle(url: URL(string: "papercup://harness/alpha-1")!)
        XCTAssertTrue(ok)
        XCTAssertEqual(router.pendingSlug, "alpha-1")
    }

    func testForeignSchemeIgnored() {
        let router = DeepLinkRouter.shared
        router.pendingSlug = nil
        let ok = router.handle(url: URL(string: "https://example.com/harness/beta")!)
        XCTAssertFalse(ok)
        XCTAssertNil(router.pendingSlug)
    }

    func testRecognisedSchemeWithoutHarnessHostIgnored() {
        let router = DeepLinkRouter.shared
        router.pendingSlug = nil
        let ok = router.handle(url: URL(string: "papercup://other/x")!)
        XCTAssertFalse(ok)
        XCTAssertNil(router.pendingSlug)
    }

    func testNotificationUserInfoHarnessSlugRouted() {
        let router = DeepLinkRouter.shared
        router.pendingSlug = nil
        router.handle(notificationUserInfo: ["harnessSlug": "from-push"])
        XCTAssertEqual(router.pendingSlug, "from-push")
    }

    func testNotificationUserInfoFallsBackToSlugKey() {
        let router = DeepLinkRouter.shared
        router.pendingSlug = nil
        router.handle(notificationUserInfo: ["slug": "fallback"])
        XCTAssertEqual(router.pendingSlug, "fallback")
    }

    func testNotificationUserInfoIgnoresNonStringValues() {
        let router = DeepLinkRouter.shared
        router.pendingSlug = nil
        router.handle(notificationUserInfo: ["harnessSlug": 42])
        XCTAssertNil(router.pendingSlug)
    }

    func testPairUrlSetsPendingPair() {
        let router = DeepLinkRouter.shared
        router.pendingPair = nil
        let url = URL(string: "papercup://pair?server=http://10.0.2.2:3055&pairToken=abc-123&workspaceId=default")!
        XCTAssertTrue(router.handle(url: url))
        XCTAssertEqual(router.pendingPair, PendingPair(
            server: "http://10.0.2.2:3055",
            pairToken: "abc-123",
            workspaceId: "default"
        ))
    }

    func testPairUrlMissingFieldRejected() {
        let router = DeepLinkRouter.shared
        router.pendingPair = nil
        let url = URL(string: "papercup://pair?server=foo&pairToken=bar")!
        XCTAssertFalse(router.handle(url: url))
        XCTAssertNil(router.pendingPair)
    }

    func testPairUrlEmptyTokenRejected() {
        let router = DeepLinkRouter.shared
        router.pendingPair = nil
        let url = URL(string: "papercup://pair?server=foo&pairToken=&workspaceId=default")!
        XCTAssertFalse(router.handle(url: url))
        XCTAssertNil(router.pendingPair)
    }
}
