// SPDX-License-Identifier: GPL-3.0-or-later
//
// WI-4984: the operator chat renders a submitted user turn optimistically
// and must drop the optimistic copy exactly when the persisted read covers
// it — never earlier (bubble vanishes), never later (bubble duplicates).

import XCTest
@testable import Papercup

final class PendingTurnCoverageTests: XCTestCase {
    private func turn(
        id: String = "t1",
        role: String = "user",
        text: String = "hello",
        createdAt: Int64 = 1_000_000
    ) -> OperatorTurn {
        OperatorTurn(
            id: id, seq: 1, role: role, text: text,
            source: "text", createdAt: createdAt, toolsJson: "null"
        )
    }

    private func pending(text: String = "hello", createdAt: Int64 = 1_000_000) -> OperatorTurn {
        OperatorTurn(
            id: "pending-x", seq: .max, role: "user", text: text,
            source: "text", createdAt: createdAt, toolsJson: "null"
        )
    }

    func testPersistedMatchCovers() {
        XCTAssertTrue(PendingTurnCoverage.isCovered(
            by: [turn(createdAt: 1_000_500)],
            pending: pending(createdAt: 1_000_000)
        ))
    }

    func testDifferentTextDoesNotCover() {
        XCTAssertFalse(PendingTurnCoverage.isCovered(
            by: [turn(text: "something else")],
            pending: pending()
        ))
    }

    func testAssistantRoleDoesNotCover() {
        // The assistant echoing the user's words back must not eat the bubble.
        XCTAssertFalse(PendingTurnCoverage.isCovered(
            by: [turn(role: "assistant")],
            pending: pending()
        ))
    }

    func testOldPersistedTurnWithSameTextDoesNotCover() {
        // A user turn persisted long BEFORE this submission (the user said
        // the same thing an hour ago) is history, not coverage.
        let hourAgo: Int64 = 1_000_000 - 3_600_000
        XCTAssertFalse(PendingTurnCoverage.isCovered(
            by: [turn(createdAt: hourAgo)],
            pending: pending(createdAt: 1_000_000)
        ))
    }

    func testServerClockSlightlyBehindDeviceStillCovers() {
        // Server stamped the row a bit before the device clock's submit
        // moment — within the skew slack it still covers.
        let skewedEarlier = 1_000_000 - (PendingTurnCoverage.clockSkewSlackMs - 1)
        XCTAssertTrue(PendingTurnCoverage.isCovered(
            by: [turn(createdAt: skewedEarlier)],
            pending: pending(createdAt: 1_000_000)
        ))
    }

    func testEmptyReadDoesNotCover() {
        XCTAssertFalse(PendingTurnCoverage.isCovered(by: [], pending: pending()))
    }
}
