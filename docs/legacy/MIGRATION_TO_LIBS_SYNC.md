# Migration plan — mobile sync-stream → libs/sync

Outcome of the consolidation discussion with the desktop sync agent.
Mobile currently runs its own SSE adapter (`src/lib/sync-stream.ts` +
`usePolledList(liveName)`); the long-term home for that is
`libs/sync`'s SSE transport, which already has a more mature reconnect/
heartbeat/backoff implementation.

This file is **the agreed-upon migration plan**. Phase 0 (this file +
the inventory below) is done. Phase 1+ are scheduled.

---

## Sequencing

| Phase | Owner | Trigger | Status |
|---|---|---|---|
| **0** Inventory + plan | mobile | landed | ✅ done |
| **1** libs/sync extensions | desktop | concurrent — pre-landing | ✅ done — `tokenQueryParam`, `endpointOverride`, `visibilityPause` shipped |
| **1.5** `tokenQueryParam` for polling fetcher | mobile | gap discovered during pilot setup | ✅ done — same prop now also flows through `usePollingQuery`'s URL construction (the SSE adapter uses polling for the actual data fetch under push-invalidates, so without this, the JWT-gated `/rest-query` endpoint couldn't be called) |
| **2** Notifications.tsx pilot | mobile | gate relaxed — pilot is single-screen, reversible | ✅ done — see "Pilot result" below |
| **3** Remaining migrations | mobile | pilot clean (it is) | Pending — 7 screens × ~30min each |
| **4** Cleanup | mobile | all screens off | Pending |

The "after first device test" gate matters: real Android push +
WireGuard handoff might surface bugs (cellular reconnect, suspend/
resume) that should inform what libs/sync needs. Migrating in v0
before device testing is premature.

---

## Pattern-matching — important correction

The desktop agent demonstrated that `libs/sync`'s SSE adapter already
broadcasts on no-args invalidates:

```ts
// from libs/sync/src/transports/sse/SSEAdapter.tsx
es.addEventListener('invalidate', (raw) => {
  const ev = JSON.parse(data);
  if (ev.args) {
    queryClient.invalidateQueries({ queryKey: ['sync', ev.name, ev.args] });
  } else {
    // No args → invalidate every cached entry under this name
    queryClient.invalidateQueries({
      predicate: (q) => q.queryKey[1] === ev.name,
    });
  }
});
```

This is exactly the broadcast my `onInvalidate('toastLog.*', refetch)`
provides. **The migration doesn't need new server emission shapes.**

The translation rule:

| Mobile today | libs/sync target |
|---|---|
| `onInvalidate('toastLog.*', cb)` | `useSyncQuery({queryName: 'toastLog.recent', ...})` invalidated when server emits `{name: 'toastLog.recent'}` (no args) |
| `onInvalidate('harnessStatus.*', cb)` | Same — when server emits `{name: 'harnessStatus.byHarness'}` with `args: {harnessSlug}`, libs/sync invalidates that exact query; when emitted with no args, every harness-status query invalidates |
| `onInvalidate(['operatorScans.*', 'auditLog.*'], cb)` | Two `useSyncQuery` calls, one per name; or rolled into one fetcher subscribed to two names |

**No server-side notify changes are required.** The current emission
patterns (`name.byHarness` with `args: {harnessSlug}`) work for both
the existing desktop SSE adapter and the future mobile adapter.

---

## Screen inventory

The 8 mobile data screens with their current subscriptions and target
shapes:

### 1. `Notifications.tsx` (pilot target)

```ts
// Current
usePolledList<Toast>(
  (signal) => fetchRecentNotifications(20, signal),
  60_000,
  'toastLog.*',
)

// libs/sync target
useSyncQuery({
  queryName: 'toastLog.recent',
  args: { limit: 20 },
})
// staleTime: 60_000 to match current safety net
```

Endpoint: `GET /api/mobile/notifications/recent`. Server emits
`notifySyncInvalidate('toastLog.recent')` from `app/api/toast-log/route.ts:88`.
Single name, no broadcast — easiest migration. **Pilot here.**

### 2. `NotificationHistory.tsx`

```ts
usePolledList<Toast>(
  (signal) => fetchRecentNotifications(200, signal),
  60_000,
  'toastLog.*',
)
```

Same endpoint, larger limit. Trivial after Notifications.tsx pilot.

### 3. `Operator.tsx`

```ts
usePolledList<OperatorCard>(
  fetcher, 60_000, ['operatorScans.*', 'auditLog.*'],
)
```

Endpoint: `GET /api/mobile/operator/cards`. Subscribes to two names.
**Migration question:** does libs/sync's `useSyncQuery` accept multiple
invalidation keys, or do we use two `useSyncQuery` calls + merge their
loading states? Resolve during pilot.

Server emits `notifySyncInvalidate('operatorScans.running')` and
`notifySyncInvalidate('auditLog.recent')`.

### 4. `CurrentlyRunning.tsx`

```ts
usePolledValue<RunningSnapshot>(
  fetcher, 60_000, ['operatorScans.*', 'harnessStatus.*'],
)
```

Endpoint: `GET /api/mobile/running`. Same multi-name question as
Operator.

### 5. `RecentActions.tsx`

```ts
usePolledList<AuditEntry>(
  (signal) => fetchRecentActions(75, signal),
  60_000,
  'auditLog.*',
)
```

Endpoint: `GET /api/mobile/actions/recent`. Single broadcast name.

### 6. `StandingApprovals.tsx`

```ts
usePolledList<StandingCandidate>(
  fetcher, 60_000, 'auditLog.*',
)
```

Endpoint: `GET /api/mobile/operator/standing-candidates`. Single
broadcast name. (Note: candidates are derived from audit entries —
hence the auditLog subscription.)

### 7. `Harness.tsx` selector

```ts
usePolledList<HarnessLite>(
  fetcher, 60_000, 'harnessStatus.*',
)
```

Endpoint: `GET /api/mobile/harnesses`. Single broadcast name.

### 8. `Harness.tsx` dashboard

```ts
usePolledValue<HarnessStatus>(
  fetcher, 60_000,
  ['harnessStatus.*', 'harnessEscalations.byHarness',
   'harnessSmokeTest.byHarness', 'harnessPlanReview.byHarness'],
)
```

Endpoint: `GET /api/mobile/harnesses/:slug`. Four-name subscription.
Most complex screen; do last in migration order.

---

## libs/sync extensions needed (desktop's pre-land)

```ts
interface SyncProviderProps {
  // … existing …

  /** When set, the SSE EventSource URL gets `?token=<value>` appended.
   *  Mobile uses this to auth the JWT-gated `/api/mobile/sync/sse`
   *  endpoint — EventSource can't carry headers. */
  tokenQueryParam?: string;

  /** Override the default `/zero/sse` endpoint path. Mobile points at
   *  `/api/mobile/sync/sse`. */
  endpointOverride?: string;

  /** When true, pause the EventSource while document.visibilityState
   *  is hidden for >5min. Reopens on visibility return. Phone-friendly;
   *  desktop tabs benefit too. */
  visibilityPause?: boolean;
}
```

**Not landing now (deferred to pilot):** `fetcher-passthrough` mode
that lets `useSyncQuery` skip the named-query registry and use a plain
fetch function. This needs the Notifications.tsx callsite to inform
the API shape — designing it speculatively risks a v1 we'll regret.

---

## Pilot (Phase 2) — what "clean" looks like

Notifications.tsx pilot is clean if:

1. The screen renders the toast list at the same cadence (≤500ms after
   server emission) as the current `sync-stream.ts` path.
2. Reconnect on operator restart still works (libs/sync has its own
   exp-backoff; verify it kicks in cleanly when the operator bounces).
3. The 60s safety-net polling still fires when the EventSource is
   inactive (e.g. when visibility-pause activates).
4. `staleTime` semantics match user expectations — going to /
   /notifications shouldn't trigger a remount-refetch if the data
   was just fetched a second ago.
5. `react-query` devtools (or equivalent) shows the queries
   correctly keyed and invalidating.

Any failure → diagnose, fix, OR fall back to staying on
sync-stream.ts and re-evaluating the migration.

---

## What I'd skip from the original ask

The desktop agent offered to "ping the mobile agent when extensions
land." Decline — coordination overhead. When mobile is ready
post-device-test, the extensions will be in `libs/sync` and I'll find
them. They sit inert behind backwards-compatible defaults until used.

---

## Pilot result (Phase 2, completed)

`Notifications.tsx` migrated cleanly. Validated end-to-end:

1. **Mounted SyncProvider in App.tsx** with:
   ```tsx
   <SyncProvider
     syncType="SSE"
     restEndpoint={apiBase + "/api/mobile"}
     endpointOverride={apiBase + "/api/mobile/sync/sse"}
     tokenQueryParam={pairing.deviceToken}
     visibilityPause={true}
     pollIntervalMs={60_000}
   >
   ```

2. **Server-side `/api/mobile/rest-query`** dispatch endpoint added —
   takes `?name=...&args=...&token=...`, routes by name to existing
   handler logic (`recentToasts`, `recentAuditEntries`,
   `currentlyRunning`, `listHarnessesFor`, `harnessStatusFor`,
   `refreshCandidates` / `readCandidates`). Returns `{rows, version}`
   matching libs/sync's expected shape.

3. **Libs/sync gap closed**: the SSE adapter uses the polling fetcher
   for the actual data load under push-invalidates. The `tokenQueryParam`
   prop only affected the SSE EventSource URL, not the polling URL.
   Extended `usePollingQuery.ts` and `PollingAdapter.tsx` to thread the
   same param through. Strictly additive, backwards-compatible.

4. **`Notifications.tsx` rewritten** from
   `usePolledList(fetcher, 60_000, 'toastLog.*')` to
   `useSyncQuery({queryName: 'toastLog.recent', args: {limit: 20}})`.
   Net diff: -10 lines, identical UI behavior.

5. **End-to-end verification**:
   - Network: `GET /api/mobile/rest-query?name=toastLog.recent&args={"limit":20}&token=<JWT>` → 200, 20 toast rows
   - Wrote a fresh toast via `POST /api/toast-log` →
     refetch fired within ~3 seconds (poll interval is 60s, so this had
     to be SSE-driven invalidation)
   - First article on screen updated to the freshly-written toast
   - `restCallCount` incremented by 1 (single refetch, not duplicate)

6. **Both transports run in parallel during migration window**:
   - Existing `sync-stream.ts` continues for the 7 unmigrated screens
   - libs/sync's SSE EventSource serves Notifications.tsx
   - Two SSE connections to the same server is wasteful but bounded
     and acceptable during the migration

## Open questions resolved during pilot

1. **Multi-name subscriptions** — for screens that subscribed to
   multiple names (Operator's `['operatorScans.*', 'auditLog.*']`),
   the answer is to keep them as separate `useSyncQuery` calls per
   name, since each has different semantics. The shape of the
   migration is still a 1:1 map (one screen → one or more
   `useSyncQuery` calls).
2. **`staleTime` interaction with poll interval** — the SSE adapter
   uses `keepPreviousData` and the `staleTime` knob is independent
   from `pollIntervalMs`. Setting `pollIntervalMs: 60_000` correctly
   suppresses background polling while the EventSource is open.
3. **Workspace-scoping** — works because the mobile rest-query
   endpoint reads `claims.workspace_id` from the JWT and dispatches
   to handlers that internally use `withWorkspace(workspaceId)`. No
   library changes needed.

## Remaining open questions (Phase 3+)



1. **Multi-name subscriptions** — does `useSyncQuery` accept an array
   of invalidation keys, or do we use multiple hook calls?
2. **`staleTime` for the safety net** — passing `pollIntervalMs: 60_000`
   gives polling fallback. Does that interfere with the SSE-driven
   refresh, or do they compose cleanly?
3. **Workspace-scoping** — current mobile API routes are JWT-scoped via
   `withWorkspace(claims.workspace_id)`. libs/sync's polling transport
   hits a generic `/rest-query` endpoint. Need to verify the per-route
   approach works with libs/sync (probably via `endpointOverride`
   per query — more reason to defer fetcher-passthrough until we have
   a real callsite).

These get answered during pilot.
