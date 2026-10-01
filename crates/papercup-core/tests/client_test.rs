// SPDX-License-Identifier: GPL-3.0-or-later
//
// Integration tests for `papercup-core::client::OperatorClient`.
//
// These spin up a real localhost HTTP server via wiremock-rs and assert
// the wire shape produced by each method matches what the LIVE server
// (papercup packages/operator-core lib/endpoint-route/routes/device/*)
// speaks — fixtures re-audited 2026-06-05 against source
// (mobile-apps-revival-redesign D-001). They catch:
//   - bearer auth header presence
//   - URL path / method / query-param correctness
//   - request body camelCase serialisation (PairBody, PushRegisterBody)
//   - response deserialisation across the CURRENT shapes
//   - BOTH error envelopes: route-stack `{"error":{code,message}}` and
//     handler-level `{"error":"code"}`
//   - 401 AND 403 → ApiError::Unauthorized (re-pair), 5xx → Server
//
// If the backend contract changes, refresh the fixture AND the source
// citation, not just whatever makes the test pass.

use papercup_core::client::{ApiError, OperatorClient};
use papercup_core::types::{PairBody, PushRegisterBody};
use serde_json::json;
use wiremock::matchers::{bearer_token, body_json, method, path, query_param};
use wiremock::{Mock, MockServer, ResponseTemplate};

const TOKEN: &str = "test-jwt-token";

async fn paired_client() -> (OperatorClient, MockServer) {
    let server = MockServer::start().await;
    let client = OperatorClient::new(server.uri(), Some(TOKEN.to_string()));
    (client, server)
}

#[tokio::test]
async fn list_harnesses_happy_path() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/harnesses"))
        .and(bearer_token(TOKEN))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "harnesses": [
                {
                    "slug": "alpha",
                    "path": "/p/alpha",
                    "has_state": true,
                    "harness_kind": "scratch",
                    "iteration": 7,
                    "last_active_ts": 1_700_000_000,
                    "status": "running"
                }
            ]
        })))
        .expect(1)
        .mount(&server)
        .await;

    let result = client.list_harnesses().await.unwrap();
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].slug, "alpha");
    assert_eq!(result[0].iteration, Some(7));
}

#[tokio::test]
async fn list_harnesses_unauthorized_when_no_token() {
    let server = MockServer::start().await;
    let client = OperatorClient::new(server.uri(), None);
    let err = client.list_harnesses().await.unwrap_err();
    assert!(matches!(err, ApiError::Unauthorized));
}

// Route-stack auth failure: nested envelope, 401 (no principal).
#[tokio::test]
async fn nested_401_maps_to_unauthorized() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/harnesses"))
        .respond_with(ResponseTemplate::new(401).set_body_json(json!({
            "error": { "code": "unauthorized", "message": "no principal resolved" }
        })))
        .mount(&server)
        .await;
    let err = client.list_harnesses().await.unwrap_err();
    assert!(matches!(err, ApiError::Unauthorized));
}

// Route-stack principal rejection: 403 (kind/trust not in allowlist) is
// the device-route failure mode for a stale-but-decodable token — it
// must ALSO mean re-pair, not a generic error (D-001.6).
#[tokio::test]
async fn nested_403_maps_to_unauthorized() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/harnesses"))
        .respond_with(ResponseTemplate::new(403).set_body_json(json!({
            "error": { "code": "forbidden", "message": "kind loopback not in allowlist" }
        })))
        .mount(&server)
        .await;
    let err = client.list_harnesses().await.unwrap_err();
    assert!(matches!(err, ApiError::Unauthorized));
}

// Handler-level flat error envelope on a 5xx.
#[tokio::test]
async fn flat_500_maps_to_server_with_detail() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/harnesses"))
        .respond_with(ResponseTemplate::new(500).set_body_json(json!({"error":"db down"})))
        .mount(&server)
        .await;
    match client.list_harnesses().await.unwrap_err() {
        ApiError::Server { status, detail } => {
            assert_eq!(status, 500);
            assert_eq!(detail, "db down");
        }
        e => panic!("unexpected: {e:?}"),
    }
}

// Route-stack handler_error: nested envelope on a 5xx → detail carries
// "code: message".
#[tokio::test]
async fn nested_500_maps_to_server_with_code_and_message() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/harnesses"))
        .respond_with(ResponseTemplate::new(500).set_body_json(json!({
            "error": { "code": "handler_error", "message": "boom" }
        })))
        .mount(&server)
        .await;
    match client.list_harnesses().await.unwrap_err() {
        ApiError::Server { status, detail } => {
            assert_eq!(status, 500);
            assert_eq!(detail, "handler_error: boom");
        }
        e => panic!("unexpected: {e:?}"),
    }
}

// Handler-level error with a hint sibling (voice-session-init style).
#[tokio::test]
async fn flat_error_with_hint_lands_in_detail() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/voice-session-init"))
        .respond_with(ResponseTemplate::new(404).set_body_json(json!({
            "error": "voice_not_enabled",
            "hint": "Set fullAgentEngine to elevenlabs-conv in /settings/voice."
        })))
        .mount(&server)
        .await;
    match client.voice_session_init().await.unwrap_err() {
        ApiError::Server { status, detail } => {
            assert_eq!(status, 404);
            assert!(detail.contains("voice_not_enabled"));
            assert!(detail.contains("fullAgentEngine"));
        }
        e => panic!("unexpected: {e:?}"),
    }
}

#[tokio::test]
async fn running_snapshot_decodes_scan_and_harnesses() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/running"))
        .and(bearer_token(TOKEN))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "scan": {
                "id": 42,
                "started_at": 1_700_000_000_000i64,
                "request_text": "scan auth",
                "cost_usd": 0.0123
            },
            "harnesses": [
                {
                    "harness_slug": "alpha",
                    "phase": "planning",
                    "status": "running",
                    "iteration": 7,
                    "total_features": 12,
                    "passed_count": 4,
                    "todo_count": 6,
                    "blocked_count": 2,
                    "active_roles": ["architect"],
                    "last_active_ts": 1_700_000_000
                }
            ]
        })))
        .mount(&server)
        .await;
    let (scan, harnesses) = client.running_snapshot().await.unwrap();
    let scan = scan.expect("scan");
    assert_eq!(scan.id, 42);
    assert_eq!(scan.request_text.as_deref(), Some("scan auth"));
    assert_eq!(harnesses.len(), 1);
    assert_eq!(harnesses[0].harness_slug, "alpha");
    assert_eq!(harnesses[0].active_roles, vec!["architect"]);
}

// Current pair contract (routes/device/pair.ts): body is {pairToken}
// only; response carries defguardEnrollmentUrl — no wgConfig, no mesh
// fields (Defguard self-enrollment, D-005).
#[tokio::test]
async fn pair_serialises_camel_case_and_returns_defguard_url() {
    let server = MockServer::start().await;
    let client = OperatorClient::new(server.uri(), None);

    Mock::given(method("POST"))
        .and(path("/api/device/pair"))
        .and(body_json(json!({ "pairToken": "PT-123" })))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "deviceToken": "JWT",
            "deviceId": "did-1",
            "desktopHost": "10.0.0.1:3070",
            "workspaceId": "default",
            "defguardEnrollmentUrl": "https://mesh.papercuspai.com/enroll"
        })))
        .expect(1)
        .mount(&server)
        .await;

    let resp = client
        .pair(PairBody {
            pair_token: "PT-123".into(),
        })
        .await
        .unwrap();
    assert_eq!(resp.device_token, "JWT");
    assert_eq!(resp.device_id, "did-1");
    assert_eq!(
        resp.defguard_enrollment_url.as_deref(),
        Some("https://mesh.papercuspai.com/enroll")
    );
}

// Pair failure: handler-level flat 401 {error:'invalid_or_expired_token'}.
#[tokio::test]
async fn pair_invalid_token_maps_to_unauthorized() {
    let server = MockServer::start().await;
    let client = OperatorClient::new(server.uri(), None);
    Mock::given(method("POST"))
        .and(path("/api/device/pair"))
        .respond_with(
            ResponseTemplate::new(401).set_body_json(json!({"error":"invalid_or_expired_token"})),
        )
        .mount(&server)
        .await;
    let err = client
        .pair(PairBody {
            pair_token: "stale".into(),
        })
        .await
        .unwrap_err();
    assert!(matches!(err, ApiError::Unauthorized));
}

// Regression (caught only by the LIVE smoke, 2026-06-05): postgres-js
// serialises NUMERIC columns as decimal STRINGS, so scan.cost_usd arrives
// as "0.0000", not 0.0. The decoder must accept string-or-number.
#[tokio::test]
async fn running_snapshot_decodes_string_cost_usd() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/running"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "scan": {
                "id": 498,
                "started_at": 1_780_227_592_000i64,
                "request_text": "Background scan",
                "cost_usd": "0.0123"
            },
            "harnesses": []
        })))
        .mount(&server)
        .await;
    let (scan, harnesses) = client.running_snapshot().await.unwrap();
    let scan = scan.expect("scan");
    assert_eq!(scan.id, 498);
    assert!((scan.cost_usd - 0.0123).abs() < 1e-9, "string cost decoded");
    assert!(harnesses.is_empty());
}

// Companion: mission_cost_usd is also NUMERIC → string-or-number.
#[tokio::test]
async fn harness_status_decodes_string_mission_cost() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/harnesses/alpha"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "project": { "slug": "alpha", "path": "/p/alpha" },
            "counts": {},
            "iteration": 0,
            "alive": false,
            "escalated": false,
            "pendingCheckpoints": 0,
            "activeCompetitions": 0,
            "smokeFail": false,
            "missionCostUsd": "12.3456",
            "missionInputTokens": 100,
            "missionOutputTokens": 50,
            "features": []
        })))
        .mount(&server)
        .await;
    let s = client.get_harness_status("alpha").await.unwrap();
    assert!((s.mission_cost_usd - 12.3456).abs() < 1e-9);
}

#[tokio::test]
async fn get_harness_status_decodes_status_resp() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/harnesses/alpha"))
        .and(bearer_token(TOKEN))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "project": { "slug": "alpha", "path": "/p/alpha" },
            "counts": { "DONE": 12, "IN_PROGRESS": 3 },
            "iteration": 5,
            "alive": true,
            "escalated": false,
            "pendingCheckpoints": 1,
            "activeCompetitions": 0,
            "smokeFail": false,
            "missionCostUsd": 1.2345,
            "missionInputTokens": 100,
            "missionOutputTokens": 50,
            "lastDecision": "ship it",
            "features": []
        })))
        .mount(&server)
        .await;

    let s = client.get_harness_status("alpha").await.unwrap();
    assert_eq!(s.project.slug, "alpha");
    assert_eq!(s.counts.get("DONE"), Some(&12));
    assert!(s.alive);
    assert_eq!(s.last_decision.as_deref(), Some("ship it"));
}

// Current runtime-config contract (routes/device/pair.ts
// runtimeConfigRoute): voiceWs.port is the WS discovery field.
#[tokio::test]
async fn runtime_config_decodes_voice_ws_port() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/runtime-config"))
        .and(bearer_token(TOKEN))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "meshHost": "10.10.0.2:3055",
            "workspaceId": "default",
            "deviceKind": "mobile",
            "voiceWs": { "port": 3068, "path": "/api/device/voice" }
        })))
        .mount(&server)
        .await;
    let cfg = client.runtime_config().await.unwrap();
    assert_eq!(cfg.mesh_host, "10.10.0.2:3055");
    assert_eq!(cfg.voice_ws.port, Some(3068));
    assert_eq!(cfg.voice_ws.path, "/api/device/voice");
}

// voiceWs.port is null when the server's WS failed to bind.
#[tokio::test]
async fn runtime_config_null_voice_port_decodes_as_none() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/runtime-config"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "meshHost": "localhost:3055",
            "workspaceId": "default",
            "deviceKind": "mobile",
            "voiceWs": { "port": null, "path": "/api/device/voice" }
        })))
        .mount(&server)
        .await;
    let cfg = client.runtime_config().await.unwrap();
    assert_eq!(cfg.voice_ws.port, None);
}

// rest-query: the polling-sync fetch. Asserts the query params land
// URL-encoded and the {rows, version} envelope decodes.
#[tokio::test]
async fn rest_query_sends_name_and_args_and_decodes_rows() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/rest-query"))
        .and(query_param("name", "harnessStatus.byHarness"))
        .and(query_param("args", r#"{"harnessSlug":"alpha"}"#))
        .and(bearer_token(TOKEN))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "rows": [ { "slug": "alpha", "status": "running" } ],
            "version": "1764920000000"
        })))
        .expect(1)
        .mount(&server)
        .await;
    let resp = client
        .rest_query("harnessStatus.byHarness", r#"{"harnessSlug":"alpha"}"#)
        .await
        .unwrap();
    assert_eq!(resp.rows[0]["slug"], "alpha");
    assert_eq!(resp.version, "1764920000000");
}

// rest-query unknown name → flat 400 {error:"unknown query: X"}.
#[tokio::test]
async fn rest_query_unknown_name_surfaces_flat_error() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/rest-query"))
        .respond_with(
            ResponseTemplate::new(400).set_body_json(json!({"error":"unknown query: nope"})),
        )
        .mount(&server)
        .await;
    match client.rest_query("nope", "{}").await.unwrap_err() {
        ApiError::Server { status, detail } => {
            assert_eq!(status, 400);
            assert_eq!(detail, "unknown query: nope");
        }
        e => panic!("unexpected: {e:?}"),
    }
}

// voice-session-init happy path (routes/device/voice.ts).
#[tokio::test]
async fn voice_session_init_decodes_el_bootstrap() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/voice-session-init"))
        .and(bearer_token(TOKEN))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "mode": "elevenlabs-conv",
            "conversationToken": "EL-TOK",
            "agentId": "agent-1",
            "idleTimeoutMin": 2.0,
            "sessionMaxMin": 30.0,
            "voiceMode": "ptt",
            "dynamicVariables": {
                "device_id": "did-1",
                "workspace_id": "default",
                "surface": "ios",
                "voice_mode": "ptt"
            }
        })))
        .mount(&server)
        .await;
    let init = client.voice_session_init().await.unwrap();
    assert_eq!(init.mode, "elevenlabs-conv");
    assert_eq!(init.conversation_token, "EL-TOK");
    assert_eq!(init.agent_id, "agent-1");
    assert_eq!(init.voice_mode, "ptt");
    assert_eq!(init.dynamic_variables["device_id"], "did-1");
}

#[tokio::test]
async fn voice_session_init_decodes_desktop_local_bootstrap() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/voice-session-init"))
        .and(bearer_token(TOKEN))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "mode": "desktop-local",
            "turnPath": "/api/device/voice/turn",
            "warmupPath": "/api/device/voice/warmup",
            "idleTimeoutMin": 2.0,
            "sessionMaxMin": 30.0,
            "voiceMode": "ptt",
            "audienceMode": "engineer",
            "deviceId": "did-1",
            "workspaceId": "default",
            "baseUrls": [
                {"kind": "mesh", "url": "http://10.10.0.2:3170"},
                {"kind": "lan", "url": "http://192.168.1.2:3170"}
            ]
        })))
        .mount(&server)
        .await;

    let init = client.voice_session_init().await.unwrap();
    assert_eq!(init.mode, "desktop-local");
    assert!(init.conversation_token.is_empty());
    assert!(init.agent_id.is_empty());
    assert_eq!(init.turn_path.as_deref(), Some("/api/device/voice/turn"));
    assert_eq!(
        init.warmup_path.as_deref(),
        Some("/api/device/voice/warmup")
    );
    assert_eq!(init.device_id.as_deref(), Some("did-1"));
    assert_eq!(init.workspace_id.as_deref(), Some("default"));
    assert_eq!(init.base_urls.as_array().map(Vec::len), Some(2));
}

#[tokio::test]
async fn register_push_serialises_body() {
    let (client, server) = paired_client().await;
    Mock::given(method("POST"))
        .and(path("/api/device/push/register"))
        .and(bearer_token(TOKEN))
        .and(body_json(json!({"platform":"apns","token":"APNS-TOK"})))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"ok": true})))
        .expect(1)
        .mount(&server)
        .await;

    client
        .register_push(PushRegisterBody {
            platform: "apns".into(),
            token: "APNS-TOK".into(),
        })
        .await
        .unwrap();
}

#[tokio::test]
async fn heartbeat_posts_with_bearer() {
    let (client, server) = paired_client().await;
    Mock::given(method("POST"))
        .and(path("/api/device/heartbeat"))
        .and(bearer_token(TOKEN))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"ok": true})))
        .expect(1)
        .mount(&server)
        .await;
    client.heartbeat().await.unwrap();
}

#[tokio::test]
async fn list_workspaces_unwraps_envelope() {
    let (client, server) = paired_client().await;
    // Current shape (routes/device/pair.ts workspacesRoute): id/name/current
    // only — no last_activity_at.
    Mock::given(method("GET"))
        .and(path("/api/device/workspaces"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "workspaces": [
                { "id": "default", "name": "Default", "current": true },
                { "id": "side", "name": "Side", "current": false }
            ]
        })))
        .mount(&server)
        .await;
    let ws = client.list_workspaces().await.unwrap();
    assert_eq!(ws.len(), 2);
    assert!(ws[0].current);
    assert_eq!(ws[1].last_activity_at, None);
}

#[tokio::test]
async fn list_desktop_devices_unwraps_envelope() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/devices"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "devices": [
                {
                    "device_id": "d1",
                    "workspace_id": "default",
                    "device_label": "Fold5",
                    "last_seen": "2026-05-09T10:00:00Z",
                    "paired_at": "2026-05-09T09:00:00Z"
                }
            ]
        })))
        .mount(&server)
        .await;
    let devices = client.list_desktop_devices().await.unwrap();
    assert_eq!(devices.len(), 1);
    assert_eq!(devices[0].device_label.as_deref(), Some("Fold5"));
}

#[tokio::test]
async fn revoke_device_uses_delete_method() {
    let (client, server) = paired_client().await;
    Mock::given(method("DELETE"))
        .and(path("/api/device/devices/d-other"))
        .and(bearer_token(TOKEN))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"ok": true})))
        .expect(1)
        .mount(&server)
        .await;
    client.revoke_device("d-other").await.unwrap();
}

#[tokio::test]
async fn pause_get_decodes_pause_info() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/operator/pause"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "paused": true,
            "at": "2026-05-09T08:00:00Z",
            "by": "did-1"
        })))
        .mount(&server)
        .await;
    let info = client.pause_get().await.unwrap();
    assert!(info.paused);
    assert_eq!(info.by.as_deref(), Some("did-1"));
}

// POST/DELETE pause both answer with the new PauseInfo (the server's
// getPauseInfo()), not {ok,paused}.
#[tokio::test]
async fn pause_set_post_then_delete_for_unpause() {
    let (client, server) = paired_client().await;
    Mock::given(method("POST"))
        .and(path("/api/device/operator/pause"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "paused": true, "at": "2026-06-05T08:00:00Z", "by": "mobile"
        })))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path("/api/device/operator/pause"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "paused": false, "at": null, "by": null
        })))
        .expect(1)
        .mount(&server)
        .await;
    assert!(client.pause_set(true).await.unwrap());
    assert!(!client.pause_set(false).await.unwrap());
}

#[tokio::test]
async fn recent_notifications_unwraps_toasts_envelope() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/notifications/recent"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "toasts": [
                {
                    "id": 1,
                    "level": "error",
                    "message": "smoke failed",
                    "created_at": 1_700_000_000,
                    "harness_slug": "alpha"
                }
            ]
        })))
        .mount(&server)
        .await;
    let toasts = client.recent_notifications().await.unwrap();
    assert_eq!(toasts.len(), 1);
    assert_eq!(toasts[0].level, "error");
    assert_eq!(toasts[0].harness_slug.as_deref(), Some("alpha"));
}

#[tokio::test]
async fn recent_actions_unwraps_entries_envelope() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/actions/recent"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "entries": [
                {
                    "id": "a1",
                    "ts": 1_700_000_000,
                    "actor": "did-1",
                    "action": "harness:replan",
                    "subject": "harness:alpha",
                    "details": {"reason": "smoke"}
                }
            ]
        })))
        .mount(&server)
        .await;
    let entries = client.recent_actions().await.unwrap();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].subject, "harness:alpha");
    assert_eq!(entries[0].details["reason"], "smoke");
}

#[tokio::test]
async fn standing_candidates_unwraps_envelope() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/operator/standing-candidates"))
        .and(bearer_token(TOKEN))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "candidates": [
                {
                    "capability": "shell:run",
                    "targetHarness": "alpha",
                    "count": 4,
                    "lastSeenAt": "2026-05-10T12:00:00Z",
                    "firstShownAt": "2026-05-10T08:00:00Z"
                },
                {
                    "capability": "git:push",
                    "targetHarness": "beta",
                    "count": 7,
                    "lastSeenAt": "2026-05-10T11:00:00Z",
                    "firstShownAt": null
                }
            ]
        })))
        .mount(&server)
        .await;
    let candidates = client.standing_candidates().await.unwrap();
    assert_eq!(candidates.len(), 2);
    assert_eq!(candidates[0].capability, "shell:run");
    assert_eq!(candidates[0].target_harness, "alpha");
    assert_eq!(candidates[0].count, 4);
    assert_eq!(
        candidates[0].first_shown_at.as_deref(),
        Some("2026-05-10T08:00:00Z")
    );
    assert_eq!(candidates[1].capability, "git:push");
    assert!(candidates[1].first_shown_at.is_none());
}

#[tokio::test]
async fn standing_candidate_decide_approve_posts_correct_body() {
    let (client, server) = paired_client().await;
    Mock::given(method("POST"))
        .and(path("/api/device/operator/standing-candidates/decide"))
        .and(bearer_token(TOKEN))
        .and(body_json(json!({
            "capability": "shell:run",
            "targetHarness": "alpha",
            "decision": "approve"
        })))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"ok": true})))
        .mount(&server)
        .await;
    client
        .standing_candidate_decide("shell:run", "alpha", "approve")
        .await
        .unwrap();
}

#[tokio::test]
async fn standing_candidate_decide_surfaces_nested_invalid_input() {
    let (client, server) = paired_client().await;
    // Route-stack zod rejection: nested invalid_input envelope.
    Mock::given(method("POST"))
        .and(path("/api/device/operator/standing-candidates/decide"))
        .respond_with(ResponseTemplate::new(400).set_body_json(json!({
            "error": { "code": "invalid_input", "message": "decision: Invalid enum value" }
        })))
        .mount(&server)
        .await;
    let err = client
        .standing_candidate_decide("shell:run", "alpha", "maybe")
        .await
        .unwrap_err();
    match err {
        ApiError::Server { status, detail } => {
            assert_eq!(status, 400);
            assert!(detail.contains("invalid_input"));
        }
        other => panic!("expected ApiError::Server, got {other:?}"),
    }
}

#[tokio::test]
async fn workspace_switch_posts_camel_case_and_decodes_new_token() {
    let (client, server) = paired_client().await;
    Mock::given(method("POST"))
        .and(path("/api/device/workspace/switch"))
        .and(bearer_token(TOKEN))
        .and(body_json(json!({"workspaceId":"side"})))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "deviceToken": "JWT-2",
            "workspaceId": "side"
        })))
        .expect(1)
        .mount(&server)
        .await;
    let r = client.workspace_switch("side").await.unwrap();
    assert_eq!(r.device_token, "JWT-2");
    assert_eq!(r.workspace_id, "side");
}

// ── D-002 routes: attention (Inbox) + plans ────────────────────────────
// Fixtures mirror packages/operator-core/lib/endpoint-route/routes/device/
// {attention,plans}.ts (verified 2026-06-05). workItems mirror the server
// WorkItem interface (work-items.ts).

#[tokio::test]
async fn attention_decodes_groups_workitems_and_counts() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/attention"))
        .and(bearer_token(TOKEN))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "groups": [ { "kind": "plan-item", "title": "Approve X" } ],
            "workItems": [
                {
                    "id": "F-001", "kind": "feature", "family": "feature",
                    "harness": "papercup", "title": "Fix the thing",
                    "summary": "", "state": "needs-human",
                    "assignee": null, "assignedBy": null, "severity": null,
                    "parent": null, "payload": null,
                    "createdAt": "2026-06-05T08:00:00Z", "updatedAt": "2026-06-05T09:00:00Z"
                },
                {
                    "id": "EI-7", "kind": "bug", "family": "issue",
                    "harness": null, "title": "broken route",
                    "summary": "details", "state": "open",
                    "assignee": null, "assignedBy": "su-1", "severity": "major",
                    "parent": null, "payload": {"x": 1},
                    "createdAt": "2026-06-05T08:00:00Z", "updatedAt": "2026-06-05T09:00:00Z"
                }
            ],
            "counts": { "groups": 1, "workItems": 2 }
        })))
        .mount(&server)
        .await;
    let a = client.attention().await.unwrap();
    assert_eq!(a.counts.groups, 1);
    assert_eq!(a.counts.work_items, 2);
    assert_eq!(a.work_items.len(), 2);
    assert_eq!(a.work_items[0].id, "F-001");
    assert_eq!(a.work_items[0].state, "needs-human");
    assert_eq!(a.work_items[1].severity.as_deref(), Some("major"));
    assert_eq!(a.work_items[1].assigned_by.as_deref(), Some("su-1"));
    assert!(a.groups.is_array());
}

// The work_items-native layer can be empty (nothing needs a human); the
// route still returns groups + counts. Optional/default fields must hold.
#[tokio::test]
async fn attention_empty_workitems_ok() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/attention"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "groups": [],
            "workItems": [],
            "counts": { "groups": 0, "workItems": 0 }
        })))
        .mount(&server)
        .await;
    let a = client.attention().await.unwrap();
    assert!(a.work_items.is_empty());
    assert!(a.system_alerts.is_empty());
    assert_eq!(a.counts.work_items, 0);
}

// Exact current device/attention shape: system health can be the only reason
// the owner needs attention. Unknown additive fields must remain compatible.
#[tokio::test]
async fn attention_preserves_system_alerts_when_other_layers_are_empty() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/attention"))
        .and(bearer_token(TOKEN))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "groups": [],
            "workItems": [],
            "systemAlerts": [{
                "id": "system:pool-exhaustion",
                "kind": "pool-exhaustion",
                "severity": "high",
                "title": "Inference pool exhausted",
                "body": "No account can serve the next operator turn.",
                "futureMetadata": {"source": "pool"}
            }],
            "counts": {"groups": 0, "workItems": 0, "systemAlerts": 1}
        })))
        .expect(1)
        .mount(&server)
        .await;
    let feed = client.attention().await.unwrap();
    assert!(feed.work_items.is_empty());
    assert_eq!(feed.counts.groups, 0);
    assert_eq!(feed.system_alerts.len(), 1);
    let alert = &feed.system_alerts[0];
    assert_eq!(alert.id, "system:pool-exhaustion");
    assert_eq!(alert.kind, "pool-exhaustion");
    assert_eq!(alert.severity, "high");
    assert_eq!(alert.title, "Inference pool exhausted");
    assert_eq!(alert.body, "No account can serve the next operator turn.");
}

#[tokio::test]
async fn monitoring_decodes_current_fleets_and_pots() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/monitoring"))
        .and(bearer_token(TOKEN))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "fleets": {
                "agents": 3, "live": 2,
                "fleets": [{"fleetSlug": "release", "members": 2, "live": 1, "leader": "leader"}],
                "pots": [{"potSlug": "papercusp", "agents": 3, "live": 2}]
            },
            "releaseGate": null, "pool": null, "connection": null,
            "alerts": [], "generatedAtMs": 1_700_000_000_000i64
        })))
        .expect(1)
        .mount(&server)
        .await;
    let snapshot = client.monitoring().await.unwrap();
    assert_eq!(snapshot.generated_at_ms, 1_700_000_000_000);
    let activity = snapshot.fleets.unwrap();
    assert_eq!(activity.agents, 3);
    assert_eq!(activity.live, 2);
    assert_eq!(activity.fleets[0].fleet_slug, "release");
    assert_eq!(activity.fleets[0].leader.as_deref(), Some("leader"));
    assert_eq!(activity.pots[0].pot_slug, "papercusp");
}

#[tokio::test]
async fn monitoring_unavailable_tile_stays_unknown() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/monitoring"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "fleets": null, "generatedAtMs": 1_700_000_000_000i64
        })))
        .mount(&server)
        .await;
    assert!(client.monitoring().await.unwrap().fleets.is_none());
}

#[tokio::test]
async fn plans_list_sends_filters_and_decodes_summaries() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/plans"))
        .and(query_param("harness", "papercup"))
        .and(query_param("includeArchived", "false"))
        .and(bearer_token(TOKEN))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "plans": [
                {
                    "slug": "mobile-apps-revival-redesign-2026-06-05",
                    "harness": "papercup",
                    "title": "Mobile apps revival",
                    "status": "active",
                    "updated": "2026-06-05",
                    "owner": "aviynw6@gmail.com",
                    "archived": false,
                    "itemCounts": { "todo": 2, "done": 5 },
                    "nowState": "P1 in flight",
                    "nowNext": "wire the tabs"
                }
            ]
        })))
        .mount(&server)
        .await;
    let plans = client.plans_list(Some("papercup"), false).await.unwrap();
    assert_eq!(plans.len(), 1);
    assert_eq!(plans[0].slug, "mobile-apps-revival-redesign-2026-06-05");
    assert_eq!(plans[0].item_counts.get("done"), Some(&5));
    assert_eq!(plans[0].now_next.as_deref(), Some("wire the tabs"));
}

// "All Pots" view — no harness param.
#[tokio::test]
async fn plans_list_all_pots_omits_harness() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/plans"))
        .and(query_param("includeArchived", "true"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"plans": []})))
        .mount(&server)
        .await;
    let plans = client.plans_list(None, true).await.unwrap();
    assert!(plans.is_empty());
}

// Regression (caught only by the live smoke, 2026-06-05): a plan without
// frontmatter status serialises `status: null` — the decoder must accept it.
#[tokio::test]
async fn plans_list_tolerates_null_status() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/plans"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "plans": [
                {
                    "slug": "legacy-draft", "harness": "papercup",
                    "title": "Legacy draft", "status": null,
                    "updated": "2026-06-05", "owner": null, "archived": false,
                    "itemCounts": {}, "nowState": null, "nowNext": null
                }
            ]
        })))
        .mount(&server)
        .await;
    let plans = client.plans_list(None, false).await.unwrap();
    assert_eq!(plans.len(), 1);
    assert!(plans[0].status.is_none());
    assert!(plans[0].now_state.is_none());
}

#[tokio::test]
async fn plan_get_decodes_detail_with_opaque_sections() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/plans/some-plan"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "slug": "some-plan", "harness": "papercup", "archived": false,
            "title": "Some Plan", "status": "active", "owner": "x@y.com",
            "frontmatter": { "raw": {} },
            "now": { "state": "doing", "next": "ship" },
            "items": [ { "id": "P-001", "status": "todo" } ],
            "decisions": [ { "id": "D-001", "title": "use rust" } ]
        })))
        .mount(&server)
        .await;
    let d = client.plan_get("some-plan", None).await.unwrap();
    assert_eq!(d.slug, "some-plan");
    assert_eq!(d.now["next"], "ship");
    assert_eq!(d.items[0]["id"], "P-001");
}

#[tokio::test]
async fn plan_item_set_status_posts_body() {
    let (client, server) = paired_client().await;
    Mock::given(method("POST"))
        .and(path("/api/device/plans/some-plan/items/P-001/status"))
        .and(bearer_token(TOKEN))
        .and(body_json(
            json!({ "status": "done", "note": "approved from phone" }),
        ))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "ok": true })))
        .mount(&server)
        .await;
    let res = client
        .plan_item_set_status(
            "some-plan",
            "P-001",
            "done",
            Some("approved from phone"),
            None,
        )
        .await
        .unwrap();
    assert_eq!(res["ok"], true);
}

// ── operator conversation (chat, D-002) ────────────────────────────────

#[tokio::test]
async fn operator_conversation_decodes_thread() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/device/operator/conversation"))
        .and(query_param("limit", "50"))
        .and(bearer_token(TOKEN))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "conversation": {
                "id": "conv-1", "workspaceId": "default", "harnessSlug": null,
                "title": null, "status": "active", "startedAt": 1_779_000_000_000i64,
                "endedAt": null, "elConversationIds": [], "hasAudio": false
            },
            "turns": [
                {
                    "id": "t1", "conversationId": "conv-1", "seq": 1, "role": "user",
                    "text": "status?", "source": "text_typed",
                    "elConvId": null, "audioUrl": null, "createdAt": 1_779_000_000_001i64,
                    "tools": null
                },
                {
                    "id": "t2", "conversationId": "conv-1", "seq": 2, "role": "assistant",
                    "text": "All green.", "source": "text_typed",
                    "elConvId": null, "audioUrl": null, "createdAt": 1_779_000_000_002i64,
                    "tools": null
                }
            ],
            "hasMoreEarlier": false
        })))
        .mount(&server)
        .await;
    let read = client.operator_conversation(50).await.unwrap();
    assert_eq!(read.conversation.id, "conv-1");
    assert_eq!(read.turns.len(), 2);
    assert_eq!(read.turns[1].role, "assistant");
    assert_eq!(read.turns[1].text, "All green.");
    assert_eq!(read.turns[0].seq, 1);
    assert!(!read.has_more_earlier);
}

// converse: POST a typed message; the route answers SSE, the client drains
// it to completion (turns are persisted server-side, re-read separately).
#[tokio::test]
async fn operator_converse_posts_and_drains_sse() {
    let (client, server) = paired_client().await;
    Mock::given(method("POST"))
        .and(path("/api/device/operator/converse"))
        .and(bearer_token(TOKEN))
        .and(body_json(json!({
            "text": "hello operator",
            "modality": "text",
            "trigger": "user_message"
        })))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("content-type", "text/event-stream")
                .set_body_string("event: delta\ndata: {\"text\":\"hi\"}\n\nevent: done\ndata: {\"costUsd\":0.01}\n\n"),
        )
        .expect(1)
        .mount(&server)
        .await;
    client.operator_converse("hello operator").await.unwrap();
}

#[tokio::test]
async fn fallback_url_used_when_primary_unreachable() {
    // Primary URL points at a closed port → connection refused → ApiError::Network.
    // Fallback is a real wiremock server. Client should silently swap.
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/api/device/harnesses"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "harnesses": [
                {"slug": "alpha", "path": "/p/alpha", "has_state": false}
            ]
        })))
        .mount(&server)
        .await;

    // 0.0.0.0:1 is reliably refused on every linux box.
    let primary = "http://0.0.0.0:1".to_string();
    let client =
        OperatorClient::new_with_fallback(primary.clone(), server.uri(), Some(TOKEN.to_string()));
    let result = client.list_harnesses().await.unwrap();
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].slug, "alpha");
    // Subsequent calls should use the fallback URL — verified by checking
    // the client's active base_url moved away from primary.
    assert_ne!(client.base_url(), primary);
}

#[tokio::test]
async fn fallback_not_used_for_4xx() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/api/device/harnesses"))
        .respond_with(ResponseTemplate::new(503))
        .mount(&server)
        .await;
    // Both URLs valid; primary returns 503 → ApiError::Server, NOT a
    // transport failure, so we should NOT swap to fallback.
    let primary = server.uri();
    let fallback = MockServer::start().await; // not configured; would 404
    let client =
        OperatorClient::new_with_fallback(primary.clone(), fallback.uri(), Some(TOKEN.to_string()));
    let err = client.list_harnesses().await.unwrap_err();
    assert!(matches!(
        err,
        papercup_core::client::ApiError::Server { status: 503, .. }
    ));
    assert_eq!(
        client.base_url(),
        primary,
        "fallback should not be activated by HTTP errors"
    );
}

// ── operator_converse_stream (SSE delta parsing) ────────────────────────
// routes/device/operator-converse.ts streams the assistant turn as
// `event: delta` + `data: {"text":"…"}` frames; an `error` event carries
// `{"message":"…"}`. The buffered operator_converse() rides the same
// parser with a no-op callback.

#[tokio::test]
async fn operator_converse_stream_emits_deltas_in_order() {
    let (client, server) = paired_client().await;
    // Includes a keep-alive comment frame and a frame with no data —
    // both must be skipped without breaking the delta sequence.
    let sse = ": ping\n\n\
               event: delta\ndata: {\"text\":\"Hel\"}\n\n\
               event: delta\ndata: {\"text\":\"lo \"}\n\n\
               event: delta\ndata: {\"text\":\"world\"}\n\n\
               event: done\ndata: {}\n\n";
    Mock::given(method("POST"))
        .and(path("/api/device/operator/converse"))
        .and(bearer_token(TOKEN))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("content-type", "text/event-stream")
                .set_body_string(sse),
        )
        .mount(&server)
        .await;

    let mut got = String::new();
    client
        .operator_converse_stream("hi", |d| got.push_str(d))
        .await
        .unwrap();
    assert_eq!(got, "Hello world");
}

#[tokio::test]
async fn operator_converse_stream_surfaces_error_event() {
    let (client, server) = paired_client().await;
    let sse = "event: delta\ndata: {\"text\":\"par\"}\n\n\
               event: error\ndata: {\"message\":\"brain unavailable\"}\n\n";
    Mock::given(method("POST"))
        .and(path("/api/device/operator/converse"))
        .and(bearer_token(TOKEN))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("content-type", "text/event-stream")
                .set_body_string(sse),
        )
        .mount(&server)
        .await;

    let mut got = String::new();
    let err = client
        .operator_converse_stream("hi", |d| got.push_str(d))
        .await
        .unwrap_err();
    assert_eq!(got, "par", "deltas before the error still surface");
    match err {
        ApiError::Server { detail, .. } => assert_eq!(detail, "brain unavailable"),
        other => panic!("expected Server error, got {other:?}"),
    }
}

#[tokio::test]
async fn operator_converse_buffered_drains_without_deltas() {
    let (client, server) = paired_client().await;
    let sse = "event: delta\ndata: {\"text\":\"x\"}\n\nevent: done\ndata: {}\n\n";
    Mock::given(method("POST"))
        .and(path("/api/device/operator/converse"))
        .and(bearer_token(TOKEN))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("content-type", "text/event-stream")
                .set_body_string(sse),
        )
        .mount(&server)
        .await;
    client.operator_converse("hi").await.unwrap();
}
