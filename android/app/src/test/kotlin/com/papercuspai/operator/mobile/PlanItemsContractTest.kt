// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import org.junit.Assert.*
import org.junit.Test

/**
 * Contract test for `GET /api/device/plans/:slug` `items`.
 *
 * Source of truth: papercusp/packages/operator-core/lib/endpoint-route/routes/device/plans.ts
 * returns `items: parsed.items` straight from plan-parser's `parsePlan`, whose
 * `PlanItem` (papercusp/libs/generic/plan-parser/src/parser.ts) carries
 * `storedStatus` and optional `authority` (`system` | `owner`), never `status`.
 * The fixture mirrors that shape field for field.
 */
class PlanItemsContractTest {
    private val serverItems = """
        [
          {"id":"P-001","text":"Ship it","storedStatus":"done","importance":"normal",
           "riskTier":null,"authority":"system","blockedBy":[],"decisionRefs":[],
           "phase":null,"lineNumber":12,"rawLine":"- [x] **P-001** Ship it"},
          {"id":"P-002","text":"Owner approves","storedStatus":"needs-human","importance":"high",
           "riskTier":"high","authority":"owner","blockedBy":["P-001"],"decisionRefs":["D-002"],
           "phase":"Release","lineNumber":13,"rawLine":"- [ ] **P-002** Owner approves"},
          {"id":"P-003","text":"In flight","storedStatus":"wip","importance":"normal",
           "blockedBy":[],"decisionRefs":[],"phase":null,"lineNumber":14,"rawLine":"- [ ] **P-003**"}
        ]
    """.trimIndent()

    @Test
    fun readsStoredStatusFromCurrentServerShape() {
        val items = parsePlanItems(serverItems)
        assertEquals(listOf("P-001", "P-002", "P-003"), items.map { it.id })
        assertEquals(listOf("done", "needs-human", "wip"), items.map { it.status })
    }

    @Test
    fun ownerAuthorityMarksItemOwnerGated() {
        val items = parsePlanItems(serverItems).associateBy { it.id }
        assertFalse(items.getValue("P-001").ownerGated)
        assertTrue(items.getValue("P-002").ownerGated)
        // authority omitted (older plans) defaults to system, not owner
        assertEquals("system", items.getValue("P-003").authority)
        assertFalse(items.getValue("P-003").ownerGated)
    }

    @Test
    fun effectiveStatusWinsOverStoredStatusWhenServerSendsIt() {
        val items = parsePlanItems(
            """[{"id":"P-009","text":"t","storedStatus":"todo","effectiveStatus":"blocked"}]""",
        )
        assertEquals("blocked", items.single().status)
    }

    @Test
    fun legacyStatusKeyAndNullsStillParse() {
        val items = parsePlanItems(
            """[{"id":"P-010","status":"done"},
                {"id":"P-011","storedStatus":null,"authority":null},
                {"id":"  ","storedStatus":"done"},
                "not-an-object"]""",
        )
        assertEquals(listOf("P-010", "P-011"), items.map { it.id })
        assertEquals("done", items[0].status)
        // a JSON null must not render as the literal string "null"
        assertEquals("todo", items[1].status)
        assertEquals("system", items[1].authority)
    }

    @Test
    fun malformedPayloadYieldsEmptyListNotCrash() {
        assertTrue(parsePlanItems("{not json").isEmpty())
        assertTrue(parsePlanItems("{}").isEmpty())
    }
}
