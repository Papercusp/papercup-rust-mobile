// SPDX-License-Identifier: GPL-3.0-or-later
//
// LIVE smoke against a running operator with two registered workspaces — the antidote to
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

use base64::{engine::general_purpose::STANDARD, Engine};
use futures_util::FutureExt;
use papercup_core::client::{ApiError, OperatorClient};
use papercup_core::noise_stream::Ed25519KeyPair;
use papercup_core::types::PairBody;
use rand_core::{OsRng, RngCore};
use serde::Deserialize;
use std::future::Future;
use std::panic::{resume_unwind, AssertUnwindSafe};
use zeroize::Zeroizing;

// The focused cloud preflight consumes the same private QR fields as the
// native app. No token, server response body, or private key is printed.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SealedQr {
    server: String,
    pair_token: String,
    workspace_id: String,
    noise_key: String,
}

fn sealed_qr(text: &str) -> Result<(SealedQr, [u8; 32]), &'static str> {
    let qr: SealedQr = serde_json::from_str(text).map_err(|_| "invalid sealed QR")?;
    let url = url::Url::parse(&qr.server).map_err(|_| "invalid sealed QR server")?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || qr.pair_token.trim().is_empty()
        || qr.workspace_id.trim().is_empty()
    {
        return Err("invalid sealed QR fields");
    }
    let bytes = STANDARD
        .decode(&qr.noise_key)
        .map_err(|_| "invalid machine key")?;
    let key: [u8; 32] = bytes.try_into().map_err(|_| "invalid machine key")?;
    if STANDARD.encode(key) != qr.noise_key
        || Ed25519KeyPair::from_seed(&[1; 32])
            .diffie_hellman(&key)
            .is_err()
    {
        return Err("invalid machine key");
    }
    Ok((qr, key))
}

fn qr_fixture() -> serde_json::Value {
    serde_json::json!({
        "server": "https://example.test/api/workspaces/cloud-scope",
        "pairToken": "private-test-canary",
        "workspaceId": "cloud-scope",
        "noiseKey": STANDARD.encode(Ed25519KeyPair::from_seed(&[2; 32]).public_key()),
    })
}

#[test]
fn sealed_preflight_keeps_cloud_prefix_and_requires_machine_pin() {
    let fixture = qr_fixture();
    let (qr, _) = sealed_qr(&fixture.to_string()).unwrap();
    assert_eq!(qr.server, "https://example.test/api/workspaces/cloud-scope");
    let mut missing = fixture;
    missing.as_object_mut().unwrap().remove("noiseKey");
    assert!(sealed_qr(&missing.to_string()).is_err());
}

#[test]
fn sealed_preflight_rejects_unpinned_or_invalid_key() {
    for key in [
        "",
        "not-base64",
        &STANDARD.encode([0; 32]),
        &STANDARD.encode([1; 31]),
    ] {
        let mut fixture = qr_fixture();
        fixture["noiseKey"] = key.into();
        assert!(sealed_qr(&fixture.to_string()).is_err());
    }
}

#[test]
fn sealed_preflight_rejects_plaintext_and_credential_bearing_urls() {
    for server in [
        "http://example.test",
        "https://user:secret@example.test",
        "https://example.test?token=secret",
        "https://example.test#secret",
    ] {
        let mut fixture = qr_fixture();
        fixture["server"] = server.into();
        assert!(sealed_qr(&fixture.to_string()).is_err());
    }
}

#[test]
fn sealed_preflight_errors_do_not_echo_private_payload() {
    for field in ["pairToken", "workspaceId"] {
        let mut fixture = qr_fixture();
        fixture[field] = "".into();
        let error = sealed_qr(&fixture.to_string()).err().unwrap();
        assert!(!error.contains("private-test-canary"));
        assert!(!error.contains("example.test"));
    }
    assert_eq!(
        sealed_qr("private-test-canary").err(),
        Some("invalid sealed QR")
    );
}

fn require_live<T>(result: Result<T, ApiError>, stage: &str) -> T {
    result.unwrap_or_else(|error| {
        let class = match error {
            ApiError::Server { status, .. } => format!("Server:{status}"),
            ApiError::Unauthorized => "Unauthorized".into(),
            _ => "TransportOrDecode".into(),
        };
        panic!("sealed preflight {stage} failed ({class})")
    })
}

#[test]
fn sealed_preflight_server_error_only_reports_stage_and_status() {
    let panic = std::panic::catch_unwind(|| {
        require_live::<()>(
            Err(ApiError::Server {
                status: 503,
                detail: "private-response-canary".into(),
            }),
            "attention",
        );
    })
    .expect_err("503 must fail the preflight");
    let message = panic.downcast_ref::<String>().unwrap();
    assert_eq!(message, "sealed preflight attention failed (Server:503)");
    assert!(!message.contains("private-response-canary"));
}

// Run ONLY this live test with a freshly minted QR stored outside the tree:
// PAPERCUP_LIVE_QR_FILE=/private/qr.json cargo test -p papercup-core \
//   --test live_smoke live_sealed_attention_preflight -- --ignored --nocapture
// This is host/client proof; it does not assert native credential-store/UI proof.
#[tokio::test]
#[ignore = "needs a fresh private public-cloud QR file and adopted customer runtime"]
async fn live_sealed_attention_preflight() {
    let file = std::env::var("PAPERCUP_LIVE_QR_FILE").expect("set PAPERCUP_LIVE_QR_FILE");
    let text = Zeroizing::new(std::fs::read_to_string(file).expect("read private QR file"));
    let (qr, machine_key) = sealed_qr(&text).expect("validate sealed QR");
    let mut seed = Zeroizing::new([0u8; 32]);
    OsRng.fill_bytes(&mut *seed);
    let public_key = Ed25519KeyPair::from_seed(&seed).public_key();
    let anon = OperatorClient::new(qr.server.clone(), None);
    require_live(
        anon.configure_sealed_transport(&seed, &machine_key),
        "configure",
    );
    let pair = require_live(
        anon.pair_with_noise(
            PairBody {
                pair_token: qr.pair_token,
            },
            &public_key,
        )
        .await,
        "pair",
    );
    let client = OperatorClient::new(qr.server.clone(), Some(pair.device_token.clone()));
    require_live(
        client.configure_sealed_transport(&seed, &machine_key),
        "configure authenticated",
    );
    with_pair_cleanup(&client, &pair.device_id, async {
        assert_eq!(pair.workspace_id, qr.workspace_id, "QR workspace scope");
        let attention = require_live(client.attention().await, "attention");
        // Fresh connection with the same pin and phone key exercises reconnect.
        let restored = OperatorClient::new(qr.server, Some(pair.device_token));
        require_live(
            restored.configure_sealed_transport(&seed, &machine_key),
            "configure reconnect",
        );
        require_live(restored.attention().await, "reconnected attention");
        let _ = attention;
        println!("sealed preflight: paired=true attention=true reconnected=true scope=true");
    })
    .await;
    println!("sealed preflight: revoked=true");
}

// A failed contract assertion must not leave its private live pairing behind.
// Catch the test body's panic only long enough to revoke, then retain the
// original failure. A cleanup failure must never turn the smoke green.
async fn with_pair_cleanup(
    client: &OperatorClient,
    device_id: &str,
    checks: impl Future<Output = ()>,
) {
    let outcome = AssertUnwindSafe(checks).catch_unwind().await;
    let cleanup = client.revoke_device(device_id).await;
    if let Err(original_panic) = outcome {
        if cleanup.is_err() {
            eprintln!("smoke pairing cleanup failed; original contract failure retained");
        }
        resume_unwind(original_panic);
    }
    require_live(cleanup, "revoke smoke pairing");
}

// These guards run in the ordinary workspace suite; only the actual live
// smoke below is ignored. All requests use a private localhost mock identity.
async fn cleanup_fixture(status: u16) -> (OperatorClient, wiremock::MockServer) {
    use wiremock::matchers::{bearer_token, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    let server = MockServer::start().await;
    Mock::given(method("DELETE"))
        .and(path("/api/device/devices/smoke-test"))
        .and(bearer_token("private-test-token"))
        .respond_with(
            ResponseTemplate::new(status).set_body_json(serde_json::json!({
                "ok": status == 200,
                "error": "cleanup-test",
            })),
        )
        .expect(1)
        .mount(&server)
        .await;
    (
        OperatorClient::new(server.uri(), Some("private-test-token".into())),
        server,
    )
}

#[tokio::test]
async fn successful_checks_revoke_pairing() {
    let (client, server) = cleanup_fixture(200).await;
    with_pair_cleanup(&client, "smoke-test", async {}).await;
    server.verify().await;
}

#[tokio::test]
async fn panicking_checks_revoke_pairing_and_preserve_failure() {
    let (client, server) = cleanup_fixture(200).await;
    let panic = AssertUnwindSafe(with_pair_cleanup(&client, "smoke-test", async {
        panic!("original contract failure");
    }))
    .catch_unwind()
    .await
    .expect_err("the original failure must not be swallowed");
    assert_eq!(
        panic.downcast_ref::<&str>(),
        Some(&"original contract failure")
    );
    server.verify().await;
}

#[tokio::test]
async fn cleanup_failure_cannot_report_success() {
    let (client, server) = cleanup_fixture(500).await;
    assert!(
        AssertUnwindSafe(with_pair_cleanup(&client, "smoke-test", async {}))
            .catch_unwind()
            .await
            .is_err(),
        "a rejected revoke must fail the smoke"
    );
    server.verify().await;
}

#[tokio::test]
async fn cleanup_failure_preserves_original_contract_failure() {
    let (client, server) = cleanup_fixture(500).await;
    let panic = AssertUnwindSafe(with_pair_cleanup(&client, "smoke-test", async {
        panic!("original contract failure");
    }))
    .catch_unwind()
    .await
    .expect_err("the original failure must survive a cleanup rejection");
    assert_eq!(
        panic.downcast_ref::<&str>(),
        Some(&"original contract failure")
    );
    server.verify().await;
}

fn live_env() -> Option<(String, String)> {
    let base = std::env::var("PAPERCUP_LIVE_BASE").ok()?;
    let token = std::env::var("PAPERCUP_LIVE_PAIR_TOKEN").ok()?;
    Some((base, token))
}

#[tokio::test]
#[ignore = "needs a live operator, two workspaces and one-time pair token (see file header)"]
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
    assert!(!pair.device_id.is_empty(), "deviceId present");
    println!(
        "paired: device={} workspace={} defguard={:?}",
        pair.device_id, pair.workspace_id, pair.defguard_enrollment_url
    );

    let client = OperatorClient::new(base.clone(), Some(pair.device_token.clone()));
    let mut switched_client = None;

    with_pair_cleanup(&client, &pair.device_id, async {
        assert!(!pair.device_token.is_empty(), "deviceToken present");

        // One-use pairing, absent auth and workspace scope must be exercised
        // against the current API, beyond the sanitized wiremock fixtures.
        match anon.pair(PairBody { pair_token }).await {
            Err(ApiError::Unauthorized) => {}
            Ok(replayed) => {
                let replayed_client =
                    OperatorClient::new(base.clone(), Some(replayed.device_token));
                replayed_client
                    .revoke_device(&replayed.device_id)
                    .await
                    .expect("clean an unexpectedly replayed pairing");
                panic!("a consumed pair token must never create another device");
            }
            Err(_) => panic!("consumed pair token must map to Unauthorized"),
        }
        assert!(matches!(
            anon.runtime_config().await,
            Err(ApiError::Unauthorized)
        ));

        let absent = format!("android-contract-missing-{}", pair.device_id);
        assert!(matches!(
            client.workspace_switch(&absent).await,
            Err(ApiError::Unauthorized)
        ));
        let workspaces = client.list_workspaces().await.expect("workspace list");
        let private_scope = std::env::var("PAPERCUP_LIVE_SECOND_WORKSPACE").ok();
        let target = workspaces
            .iter()
            .find(|workspace| {
                workspace.id != pair.workspace_id
                    && match private_scope.as_deref() {
                        Some(id) => workspace.id == id,
                        None => true,
                    }
            })
            .expect("scope acceptance requires two registered workspaces");
        let switched = client
            .workspace_switch(&target.id)
            .await
            .expect("workspace switch");
        assert_eq!(switched.workspace_id, target.id);
        assert!(!switched.device_token.is_empty());
        let scoped = OperatorClient::new(base.clone(), Some(switched.device_token));
        assert_eq!(
            scoped
                .runtime_config()
                .await
                .expect("rotated token auth")
                .workspace_id,
            target.id
        );
        assert!(!scoped
            .list_desktop_devices()
            .await
            .expect("scoped device list")
            .iter()
            .any(|device| device.device_id == pair.device_id));
        // The new scope may not revoke the private device owned by the old
        // scope. Original credentials are kept exclusively for cleanup.
        scoped
            .revoke_device(&pair.device_id)
            .await
            .expect("foreign-scope revoke is a no-op");
        assert_eq!(
            client
                .runtime_config()
                .await
                .expect("original scope remains active")
                .workspace_id,
            pair.workspace_id
        );
        switched_client = Some(scoped);

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
    })
    .await;
    assert!(
        matches!(client.heartbeat().await, Err(ApiError::Unauthorized)),
        "revoked original token must require re-pairing"
    );
    assert!(
        matches!(
            switched_client
                .expect("rotated client was exercised")
                .runtime_config()
                .await,
            Err(ApiError::Unauthorized)
        ),
        "revocation must also reject the rotated token"
    );
    println!("revoked smoke device {}", pair.device_id);
}
