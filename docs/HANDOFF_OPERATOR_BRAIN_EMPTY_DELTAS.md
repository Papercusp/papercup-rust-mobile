<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Hand-off: operator-converse emits zero text_delta events

**Owner sought**: operator-brain agent (not mobile)
**Severity**: P1 — blocks voice end-to-end output on **both desktop and mobile**
**Filed**: 2026-05-12

## Symptom

When the EL agent's `ask_operator` client tool fires (which happens for any free-form user question), the phone or desktop proxies it through `POST /api/agent-mcp/operator-converse` (SSE). The endpoint:

- Returns 200 in ~15-20 seconds
- Emits exactly **1 event** total (the final `result` with cost) — and that's only when the OMP spawn ends
- Yields **zero `text_delta` events**
- Final `assembled.length: 0` — empty agent output

The voice client then falls back to the literal string `"I had trouble just then — say that again?"` (see `apps/operator/lib/voice-engines/elevenlabs-conv.ts:528`).

From the user's perspective: agent says hi, user asks a question, agent says "I had trouble just then" instead of answering.

## Verification

```bash
# 1. Ensure operator desktop is running + dev server :3055 alive
# 2. Send a query through the converse endpoint:

curl -N -X POST http://127.0.0.1:3055/api/agent-mcp/operator-converse \
  -H "content-type: application/json" \
  -H "x-papercusp-superuser: $(grep SUPERUSER_TOKEN apps/operator/.env.local | cut -d= -f2)" \
  -d '{"workspaceId":"default","message":"what harnesses do we have","surface":"diagnostic"}'

# Expected: stream of `data: {"event":"text_delta","content":"..."}` lines
# Actual: long pause (~15-20s), then one `data: {"event":"result", ...}`, then end
```

Server log shows:
```
[operator-converse] events received: 1 cost: 0 assembled.length: 0 principalOk: true superuserToken?: true
```

## Where I'd start digging

1. **`apps/operator/lib/agent-mcp/runAgentChat.ts`** (or wherever the OMP/claude-code spawn happens). Does the parser handle the current event shape OMP emits? OMP version is `14.9.3` — check for a recent change in event names (e.g. `thinking_delta` vs `text_delta`).

2. **Prompt assembly**. Maybe the model is being asked to do nothing — system+user prompt could be malformed, the chat history could be empty, or the workspace context could be silently failing to load. Log the actual prompt bytes that go into the OMP spawn.

3. **Tool catalog**. If the LLM is calling a tool we haven't wired and waiting for the response, it'd produce zero `text_delta` until timeout. Check OMP run output for `tool_use_delta` events that never get `tool_result`.

4. **Model selection**. The agent claims to use Claude Haiku — but the brain might be using a different model that has different streaming semantics. Verify the actual model ID in the OMP spawn args.

5. **OMP transport**. The chat-stream subprocess might be running but producing output to stderr instead of stdout, or to a non-JSON-Lines format.

## What's blocked

- All voice end-to-end output (desktop **and** mobile)
- Phase D test matrix rows A2 / C1 / D1 / F1 — none can pass
- Anything in the test matrix that depends on the agent actually saying something useful

## What's NOT blocked

- Voice path infrastructure (session-init, tool dispatch, audio in/out)
- All client-tool calls (`harness_status`, `nav_open_harness`, etc.) which the agent routes through the mobile proxy and the server tools side, not through ask_operator
- Voice cost-control (idle timers, session-max, mint cooldown)

The mobile agent has not touched this surface because it's out of mobile scope. Mobile path E2E is verified correct via the proxy + tool dispatch tests in `VOICE_TEST_MATRIX.md` §C.

## Repro steps

1. Pair a phone (or just have desktop voice mode open)
2. Tap Listen → say "what harnesses do we have"
3. Observe: agent greets fine, then on your reply says "I had trouble just then"
4. In server log `/tmp/operator-dev.log`, look for `[operator-converse] events received: 1 cost:` — confirms empty deltas
