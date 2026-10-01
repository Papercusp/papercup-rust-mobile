// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import PapercupCore
@testable import Papercup

final class AttentionFeedTests: XCTestCase {
    private func feed(groups: Int64 = 0, workItems: Int64 = 0, alerts: [AttentionSystemAlert] = []) -> AttentionFeed {
        AttentionFeed(groupsJson: "[]", workItems: [], systemAlerts: alerts,
                      groupCount: groups, workItemCount: workItems)
    }

    func testSystemAlertOnlyFeedNeedsAttention() {
        let alert = AttentionSystemAlert(id: "system:pool-exhaustion", kind: "pool-exhaustion",
                                         severity: "high", title: "Inference pool exhausted", body: "No account can serve.")
        let result = feed(alerts: [alert])
        XCTAssertEqual(result.inboxAttentionCount, 1)
        XCTAssertEqual(result.inboxStatusText, "1 awaiting you")
    }

    func testCountIncludesEveryAttentionLayer() {
        let alert = AttentionSystemAlert(id: "system:release-red-gate", kind: "release-red-gate",
                                         severity: "high", title: "Release gate is red", body: "Changes cannot ship.")
        XCTAssertEqual(feed(groups: 2, workItems: 3, alerts: [alert]).inboxAttentionCount, 6)
    }

    func testEmptyLegacyFeedIsAllClear() {
        XCTAssertEqual(feed().inboxAttentionCount, 0)
        XCTAssertEqual(feed().inboxStatusText, "All clear")
    }
}
