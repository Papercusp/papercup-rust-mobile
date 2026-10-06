// SPDX-License-Identifier: GPL-3.0-or-later
//
// WI-5035 (iOS sibling of WI-4966): raw UniFFI/reqwest transport failures
// must never reach the user — FriendlyError maps every client error enum
// to actionable copy. These tests pin the mapping so a copy regression
// (or raw detail leaking back into user-visible copy) is caught in the
// unit suite, not by a user screenshot.

import XCTest
import PapercupCore
@testable import Papercup

final class FriendlyErrorTests: XCTestCase {

    // ── ApiError ──

    func testApiNetworkIsActionableAndHidesRawDetail() {
        let msg = FriendlyError.message(
            ApiError.Network(detail: "reqwest::Error { kind: Connect, source: hyper_util }"),
            doing: "loading the conversation"
        )
        XCTAssertTrue(msg.contains("Can't reach your desktop"))
        XCTAssertTrue(msg.contains("while loading the conversation"))
        XCTAssertFalse(msg.contains("reqwest"), "raw transport detail must never surface")
    }

    func testApiServerCarriesHttpStatusButNotServerDetail() {
        let msg = FriendlyError.message(
            ApiError.Server(status: 502, detail: "upstream exploded: stack trace…")
        )
        XCTAssertTrue(msg.contains("HTTP 502"))
        XCTAssertFalse(msg.contains("exploded"), "server-side detail stays out of user copy")
    }

    // ── P-015 BYOC-P-015-offline-message: relay workspace_offline ──

    func testCloudWorkspaceOfflineSaysTheCloudWorkspaceIsOffline() {
        let msg = FriendlyError.message(
            ApiError.Server(status: 503, detail: "workspace_offline"),
            doing: "loading your workspaces"
        )
        XCTAssertTrue(msg.contains("Your cloud workspace is offline"))
        XCTAssertTrue(msg.contains("while loading your workspaces"))
        XCTAssertFalse(msg.contains("HTTP 503"), "not the generic server-error copy")
        XCTAssertFalse(msg.contains("Re-pair"), "offline is never a re-pair")
    }

    func testCloudWorkspaceOfflineMatchesOnlyThe503RelayCode() {
        XCTAssertTrue(FriendlyError.isCloudWorkspaceOffline(
            ApiError.Server(status: 503, detail: "workspace_offline — connector reconnecting")))
        XCTAssertFalse(FriendlyError.isCloudWorkspaceOffline(
            ApiError.Server(status: 503, detail: "concurrent_limit")))
        XCTAssertFalse(FriendlyError.isCloudWorkspaceOffline(
            ApiError.Server(status: 502, detail: "workspace_offline")))
        XCTAssertFalse(FriendlyError.isCloudWorkspaceOffline(ApiError.Network(detail: "workspace_offline")))
    }

    // ── P-015: relay policy refusals, rate limits, frame cap (shared-core mapping, android#D-013) ──

    func testRelayRefusalNamesTheCodeAndIsNeitherRetryNorRePair() {
        let msg = FriendlyError.message(
            ApiError.Server(status: 403, detail: "relay_refused: byoc_plaintext_relay_refused"),
            doing: "loading your workspaces"
        )
        XCTAssertTrue(msg.contains("relay refused this request"))
        XCTAssertTrue(msg.contains("byoc_plaintext_relay_refused"))
        XCTAssertTrue(msg.contains("while loading your workspaces"))
        XCTAssertFalse(msg.contains("HTTP 403"), "not the generic server-error copy")
        XCTAssertFalse(msg.contains("Give it a moment"), "a policy refusal does not clear by waiting")
        XCTAssertFalse(msg.contains("Re-pair"), "a relay refusal is never a credential verdict")
    }

    func testRelayRefusalCodeParsesOnlyTheRelayPrefix() {
        XCTAssertEqual(FriendlyError.relayRefusalCode(
            ApiError.Server(status: 401, detail: "relay_refused: route_not_relayed")), "route_not_relayed")
        XCTAssertEqual(FriendlyError.relayRefusalCode(
            ApiError.Server(status: 403, detail: "relay_refused:")), "relay_refused")
        XCTAssertNil(FriendlyError.relayRefusalCode(ApiError.Server(status: 403, detail: "forbidden")))
        XCTAssertNil(FriendlyError.relayRefusalCode(ApiError.Network(detail: "relay_refused: x")))
        XCTAssertEqual(FriendlyError.relayRefusalCode(
            ApiError.Server(status: 403, detail: "relay_refused: " + String(repeating: "x", count: 200)))?.count, 60)
    }

    func testRateLimitedAndPayloadTooLargeGetSpecificCopy() {
        let limited = FriendlyError.message(ApiError.Server(status: 429, detail: "rate_limited retry_after=5"))
        XCTAssertTrue(limited.contains("too many requests"))
        XCTAssertFalse(limited.contains("HTTP 429"))
        let tooBig = FriendlyError.message(
            ApiError.Server(status: 413, detail: "request_body_too_large: 600000 > 524288"),
            doing: "sending your message"
        )
        XCTAssertTrue(tooBig.contains("too large to send while sending your message"))
        XCTAssertFalse(tooBig.contains("HTTP 413"))
        XCTAssertFalse(FriendlyError.isRateLimited(ApiError.Server(status: 503, detail: "rate_limited")))
        XCTAssertFalse(FriendlyError.isPayloadTooLarge(ApiError.Server(status: 413, detail: "other")))
    }

    func testApiUnauthorizedPointsAtRePairing() {
        let msg = FriendlyError.message(ApiError.Unauthorized)
        XCTAssertTrue(msg.contains("Re-pair"))
    }

    // ── PairError ──

    func testPairUnauthorizedExplainsConsumedOrExpiredToken() {
        let msg = FriendlyError.message(PairError.Unauthorized(detail: "HTTP 401 body"))
        XCTAssertTrue(msg.contains("already used or expired"))
        XCTAssertFalse(msg.contains("401 body"))
    }

    func testPairInvalidQrAsksForFreshCode() {
        let msg = FriendlyError.message(PairError.InvalidQr(detail: "bad base64 blob"))
        XCTAssertTrue(msg.contains("fresh QR"))
        XCTAssertFalse(msg.contains("base64"))
    }

    // ── VoiceError ──

    func testVoiceClosedSuggestsRetryWithoutWireDetail() {
        let msg = FriendlyError.message(
            VoiceError.Closed(message: "ws close code 1006"),
            doing: "talking to the operator"
        )
        XCTAssertTrue(msg.contains("voice connection dropped"))
        XCTAssertTrue(msg.contains("while talking to the operator"))
        XCTAssertFalse(msg.contains("1006"))
    }

    // ── Unknown errors: bounded, single-line compact detail ──

    private struct WeirdError: Error, CustomStringConvertible {
        let description: String
    }

    func testUnknownErrorKeepsBoundedSingleLineDetail() {
        let long = String(repeating: "x", count: 300) + "\nsecond line"
        let msg = FriendlyError.message(WeirdError(description: long))
        XCTAssertTrue(msg.contains("Something went wrong"))
        XCTAssertFalse(msg.contains("\n"), "detail must fold to a single line")
        XCTAssertTrue(msg.contains("…"), "over-cap detail must be truncated with an ellipsis")
        XCTAssertLessThan(msg.count, 220, "unknown-error copy stays bounded")
    }

    func testCompactDetailCapAndNewlineFolding() {
        XCTAssertEqual(FriendlyError.compactDetail(WeirdError(description: "a\nb")), "a b")
        let capped = FriendlyError.compactDetail(WeirdError(description: String(repeating: "y", count: 500)))
        XCTAssertEqual(capped.count, 121, "120-char cap plus the ellipsis character")
    }
}
