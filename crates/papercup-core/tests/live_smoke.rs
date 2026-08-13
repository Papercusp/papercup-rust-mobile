// SPDX-License-Identifier: GPL-3.0-or-later
//
// LIVE smoke against a running operator — the antidote to
// green-but-stale mocks (mobile-apps-revival-redesign "Risks": verify
// against the live server, never the wiremock fixtures alone).
//
// Ignored by default; run explicitly against a live host:
//
//   PAPERCUP_LIVE_BASE=http://127.0.0.1:3170 \
//   PAPERCUP_LIVE_PAIR_TOKEN=<one-time token from POST /api/device/desktop/mint-pair-token> \
//   cargo test -p papercup-core --test live_smoke -- --ignored --nocapture
//
// Mint a token first (loopback-only):
//   curl -s -X POST http://127.0.0.1:3170/api/device/desktop/mint-pair-token \
//     -H 'content-type: application/json' -d '{"workspaceId":"<active-workspace-id>"}' \
//     | jq -r '.qrPayload.pairToken'
//
// Exercises the full repaired P0 contract: pair (Defguard URL), bearer
// auth, runtime-config (voice WS discovery), rest-query (polling sync),
// list/feeds, both error envelopes, and 403→Unauthorized.

use papercup_core::client::{ApiError, OperatorClient};
use papercup_core::types::PairBody;

fn live_env() -> Option<(String, String)> {
    let base = std::env::var("PAPERCUP_LIVE_BASE").ok()?;
    let token = std::env::var("PAPERCUP_LIVE_PAIR_TOKEN").ok()?;
    Some((base, token))
}

#[tokio::test]
#[ignore = "needs a live operator + one-time pair token (see file header)"]
async fn live_p0_contract_smoke() {
    let (base, pair_token) =
        live_env().expect("set PAPERCUP_LIVE_BASE and PAPERCUP_LIVE_PAIR_TOKEN (see file header)");

    // 1. Pair — current contract: {pairToken} in, defguardEnrollmentUrl out.
    let anon = OperatorClient::new(base.clone(), None);
    let pair = anon
        .pair(PairBody {
            pair_token: pair_token.clone(),
        })
        .await
        .expect("pair should succeed with a fresh token");
    assert!(!pair.device_token.is_empty(), "deviceToken present");
    assert!(!pair.device_id.is_empty(), "deviceId present");
    println!(
        "paired: device={} workspace={} defguard={:?}",
        pair.device_id, pair.workspace_id, pair.defguard_enrollment_url
    );

    let client = OperatorClient::new(base.clone(), Some(pair.device_token.clone()));

    // 2. runtime-config — voice WS discovery.
    let cfg = client.runtime_config().await.expect("runtime-config");
    println!(
        "runtime-config: meshHost={} voiceWs={:?}/{}",
        cfg.mesh_host, cfg.voice_ws.port, cfg.voice_ws.path
    );
    assert_eq!(cfg.workspace_id, pair.workspace_id);
    assert_eq!(cfg.voice_ws.path, "/api/device/voice");

    // 3. rest-query — the polling sync path, all server-known names.
    for name in [
        "toastLog.recent",
        "auditLog.recent",
        "operatorScans.running",
        "harnessStatus.list",
        "standingCandidates.list",
    ] {
        let resp = client
            .rest_query(name, "{}")
            .await
            .unwrap_or_else(|e| panic!("rest_query {name}: {e}"));
        assert!(resp.rows.is_array(), "{name} rows is an array");
        println!(
            "rest-query {name}: {} rows",
            resp.rows.as_array().map(|a| a.len()).unwrap_or(0)
        );
    }
    // unknown name → flat 400 envelope decodes
    match client.rest_query("nope.unknown", "{}").await {
        Err(ApiError::Server {
            status: 400,
            detail,
        }) => {
            assert!(
                detail.contains("unknown query"),
                "flat envelope decoded: {detail}"
            );
        }
        other => panic!("unknown rest-query name should 400, got {other:?}"),
    }

    // 4. Typed reads.
    let harnesses = client.list_harnesses().await.expect("list_harnesses");
    println!("harnesses: {}", harnesses.len());
    let (_scan, running) = client.running_snapshot().await.expect("running_snapshot");
    println!("running phases: {}", running.len());
    client.recent_notifications().await.expect("notifications");
    client.recent_actions().await.expect("actions");
    client.list_workspaces().await.expect("workspaces");
    let devices = client.list_desktop_devices().await.expect("devices");
    assert!(
        devices.iter().any(|d| d.device_id == pair.device_id),
        "this device appears in the paired-device list"
    );
    client.pause_get().await.expect("pause_get");
    client.heartbeat().await.expect("heartbeat");

    // 4b. D-002 routes — attention (Inbox) + plans. These exercise the
    // work_items-native + PG-canonical-plans decoders against real data.
    let att = client.attention().await.expect("attention");
    println!(
        "attention: {} groups, {} workItems (counts {}/{})",
        att.groups.as_array().map(|a| a.len()).unwrap_or(0),
        att.work_items.len(),
        att.counts.groups,
        att.counts.work_items
    );
    let plans = client
        .plans_list(None, false)
        .await
        .expect("plans_list (All Pots)");
    println!("plans (All Pots): {}", plans.len());
    if let Some(p) = plans.first() {
        let detail = client
            .plan_get(&p.slug, Some(&p.harness))
            .await
            .unwrap_or_else(|e| panic!("plan_get {}: {e}", p.slug));
        println!(
            "plan_get {}: title={:?} items={}",
            detail.slug,
            detail.title,
            detail.items.as_array().map(|a| a.len()).unwrap_or(0)
        );
    }
    // push register — idempotent upsert; a dummy APNS token is fine, it
    // just lands in mobile_push_tokens keyed by (device_id, 'apns').
    client
        .register_push(papercup_core::types::PushRegisterBody {
            platform: "apns".into(),
            token: format!("live-smoke-apns-{}", pair.device_id),
        })
        .await
        .expect("register_push");
    println!("push registered (apns)");

    // 4c. Operator conversation (chat) — read the shared thread. The SEND
    // (operator_converse) posts a REAL turn to the owner's conversation and
    // burns a brain call, so it only runs when explicitly opted in via
    // PAPERCUP_LIVE_CONVERSE=1.
    let conv = client
        .operator_conversation(5)
        .await
        .expect("operator_conversation");
    println!(
        "conversation: {} turns={} hasMore={}",
        conv.conversation.id,
        conv.turns.len(),
        conv.has_more_earlier
    );
    if std::env::var("PAPERCUP_LIVE_CONVERSE").as_deref() == Ok("1") {
        let before = conv.turns.last().map(|t| t.seq).unwrap_or(0);
        client
            .operator_converse(
                "Live contract smoke from the iOS mobile client — reply with one short sentence.",
            )
            .await
            .expect("operator_converse");
        let after = client
            .operator_conversation(5)
            .await
            .expect("re-read conversation");
        let new_last = after.turns.last().map(|t| t.seq).unwrap_or(0);
        assert!(
            new_last > before,
            "converse should append turns (seq {before} -> {new_last})"
        );
        println!(
            "converse OK: seq {} -> {} (last role={})",
            before,
            new_last,
            after.turns.last().map(|t| t.role.as_str()).unwrap_or("?")
        );
    }

    // 5. voice-session-init — any outcome is fine as long as it's the
    // documented contract: a session OR a flat-envelope config error.
    match client.voice_session_init().await {
        Ok(init) if init.mode == "desktop-local" => {
            assert_eq!(init.turn_path.as_deref(), Some("/api/device/voice/turn"));
            assert_eq!(
                init.warmup_path.as_deref(),
                Some("/api/device/voice/warmup")
            );
            assert_eq!(init.device_id.as_deref(), Some(pair.device_id.as_str()));
            assert_eq!(
                init.workspace_id.as_deref(),
                Some(pair.workspace_id.as_str())
            );
            assert!(
                init.base_urls.is_array(),
                "desktop-local baseUrls is an array"
            );
            println!(
                "voice-session-init: mode={} voiceMode={} transports={}",
                init.mode,
                init.voice_mode,
                init.base_urls.as_array().map(Vec::len).unwrap_or(0),
            );
        }
        Ok(init) => {
            assert_eq!(init.mode, "elevenlabs-conv");
            assert!(
                !init.conversation_token.is_empty(),
                "EL conversation token present"
            );
            assert!(!init.agent_id.is_empty(), "EL agent id present");
            println!(
                "voice-session-init: mode={} agent={} voiceMode={}",
                init.mode, init.agent_id, init.voice_mode
            );
        }
        Err(ApiError::Server { status, detail }) => {
            println!("voice-session-init unavailable ({status}): {detail}");
            assert!(
                matches!(status, 404 | 429 | 502 | 503),
                "documented statuses"
            );
        }
        Err(e) => panic!("voice-session-init unexpected error: {e}"),
    }

    // 6. Auth failure mode — a garbage token must read as Unauthorized
    // (the route answers 401 no-principal or 403 forbidden; both re-pair).
    let bad = OperatorClient::new(base.clone(), Some("garbage-token".into()));
    match bad.list_harnesses().await {
        Err(ApiError::Unauthorized) => {}
        other => panic!("garbage token should map to Unauthorized, got {other:?}"),
    }

    // 7. Clean up — revoke this smoke pairing so the device list doesn't
    // accumulate test entries.
    client
        .revoke_device(&pair.device_id)
        .await
        .expect("revoke self");
    println!("revoked smoke device {}", pair.device_id);
}
