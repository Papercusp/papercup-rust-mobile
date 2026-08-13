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

    // ── attention-kind → Inbox routing (D-004) ──
    // The server (attention-notify.ts) tags actionable pushes with a
    // `kind`; an attention kind deep-links to the Inbox tab.

    func testAttentionKindRoutesToInbox() {
        let router = DeepLinkRouter.shared
        router.pendingInbox = false
        router.pendingSlug = nil
        router.handle(notificationUserInfo: ["kind": "needs-human"])
        XCTAssertTrue(router.pendingInbox, "needs-human push should open the Inbox")
    }

    func testAttentionKindWithHarnessRoutesBoth() {
        let router = DeepLinkRouter.shared
        router.pendingInbox = false
        router.pendingSlug = nil
        router.handle(notificationUserInfo: ["kind": "plan-review", "harness": "alpha-1"])
        XCTAssertTrue(router.pendingInbox, "attention push opens the Inbox")
        XCTAssertEqual(router.pendingSlug, "alpha-1", "and pushes the harness detail over it")
    }

    func testBareNotificationOpensInbox() {
        let router = DeepLinkRouter.shared
        router.pendingInbox = false
        router.pendingSlug = nil
        router.handle(notificationUserInfo: [:])
        XCTAssertTrue(router.pendingInbox, "a kind-less, harness-less tap still opens the Inbox")
    }

    func testNonAttentionKindWithoutHarnessIsInert() {
        // A kind the attention-set doesn't recognise, with no harness, is
        // inert (the bare-tap Inbox fallback only fires when kind == nil).
        // The server's MOBILE_KIND map only sends recognised kinds, so
        // this branch is defensive, not a live path.
        let router = DeepLinkRouter.shared
        router.pendingInbox = false
        router.pendingSlug = nil
        router.handle(notificationUserInfo: ["kind": "completion"])
        XCTAssertFalse(router.pendingInbox, "unrecognised kind without a harness routes nowhere")
        XCTAssertNil(router.pendingSlug, "no harness slug to route")
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

    func testLaunchPairPayloadIsInstalledSynchronously() {
        let router = DeepLinkRouter.shared
        router.pendingPair = nil
        let payload = #"{"server":"http://192.168.40.216:3070","pairToken":"one-shot","workspaceId":"papercusp-workspace"}"#
        XCTAssertTrue(router.handle(pairPayload: payload))
        XCTAssertEqual(router.pendingPair, PendingPair(
            server: "http://192.168.40.216:3070",
            pairToken: "one-shot",
            workspaceId: "papercusp-workspace"
        ))
    }

    func testLaunchPairPayloadMissingFieldRejectedWithoutMutatingPendingPair() {
        let router = DeepLinkRouter.shared
        router.pendingPair = nil
        XCTAssertFalse(router.handle(pairPayload: #"{"server":"http://host","pairToken":"one-shot"}"#))
        XCTAssertNil(router.pendingPair)
    }
}
