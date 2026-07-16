// SPDX-License-Identifier: GPL-3.0-or-later
//
// WI-5035 (iOS sibling of WI-4966): raw UniFFI/reqwest transport failures
// must never reach the user — FriendlyError maps every client error enum
// to actionable copy. These tests pin the mapping so a copy regression
// (or raw detail leaking back into user-visible copy) is caught in the
// unit suite, not by a user screenshot.

import XCTest
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
