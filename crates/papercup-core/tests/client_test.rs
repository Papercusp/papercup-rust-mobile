// SPDX-License-Identifier: GPL-3.0-or-later
//
// Integration tests for `papercup-core::client::OperatorClient`.
//
// These spin up a real localhost HTTP server via wiremock-rs and assert
// the wire shape produced by each method matches what backend's
// openapi.yaml says to expect. They catch:
//   - bearer auth header presence
//   - URL path / method correctness
//   - request body camelCase serialisation (PairBody, PushRegisterBody)
//   - response deserialisation across the new shapes
//   - 401 → ApiError::Unauthorized, 5xx → ApiError::Server
//
// They do NOT validate the contract against backend (that would need
// the OpenAPI spec wired in). Wire fixtures here are hand-mirrored from
// papercup-rust-server/openapi.yaml; if the spec changes, these break
// loudly and we know to refresh both sides.

use papercup_core::client::{ApiError, OperatorClient};
use papercup_core::types::{PairBody, PushRegisterBody};
use serde_json::json;
use wiremock::matchers::{bearer_token, body_json, method, path};
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
        .and(path("/api/mobile/harnesses"))
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

#[tokio::test]
async fn list_harnesses_maps_401() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/mobile/harnesses"))
        .respond_with(ResponseTemplate::new(401).set_body_json(json!({"error":"bad token"})))
        .mount(&server)
        .await;
    let err = client.list_harnesses().await.unwrap_err();
    assert!(matches!(err, ApiError::Unauthorized));
}

#[tokio::test]
async fn running_snapshot_decodes_scan_and_harnesses() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/mobile/running"))
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

#[tokio::test]
async fn list_harnesses_maps_500_with_detail() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/mobile/harnesses"))
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

#[tokio::test]
async fn pair_serialises_camel_case_and_returns_outcome() {
    let server = MockServer::start().await;
    let client = OperatorClient::new(server.uri(), None);

    Mock::given(method("POST"))
        .and(path("/api/mobile/pair"))
        .and(body_json(json!({
            "pairToken": "PT-123",
            "wireguardPubkey": "PUBKEY"
        })))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "deviceToken": "JWT",
            "deviceId": "did-1",
            "desktopHost": "10.0.0.1:3070",
            "workspaceId": "default",
            "wgConfig": {
                "peer_public_key": "PEER",
                "peer_endpoint": "1.2.3.4:51820",
                "allowed_ips": ["10.10.0.0/16"],
                "assigned_ip": "10.10.0.5/32",
                "mtu": 1380
            }
        })))
        .expect(1)
        .mount(&server)
        .await;

    let resp = client
        .pair(PairBody {
            pair_token: "PT-123".into(),
            wireguard_pubkey: Some("PUBKEY".into()),
        })
        .await
        .unwrap();
    assert_eq!(resp.device_token, "JWT");
    assert_eq!(resp.device_id, "did-1");
    let mesh = resp.wg_config.expect("mesh present");
    assert_eq!(mesh["assigned_ip"], "10.10.0.5/32");
}

#[tokio::test]
async fn get_harness_status_decodes_status_resp() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/mobile/harnesses/alpha"))
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

#[tokio::test]
async fn register_push_serialises_body() {
    let (client, server) = paired_client().await;
    Mock::given(method("POST"))
        .and(path("/api/mobile/push/register"))
        .and(bearer_token(TOKEN))
        .and(body_json(json!({"platform":"fcm","token":"FCM-TOK"})))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"ok": true})))
        .expect(1)
        .mount(&server)
        .await;

    client
        .register_push(PushRegisterBody {
            platform: "fcm".into(),
            token: "FCM-TOK".into(),
        })
        .await
        .unwrap();
}

#[tokio::test]
async fn heartbeat_posts_with_bearer() {
    let (client, server) = paired_client().await;
    Mock::given(method("POST"))
        .and(path("/api/mobile/heartbeat"))
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
    Mock::given(method("GET"))
        .and(path("/api/mobile/workspaces"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "workspaces": [
                { "id": "default", "name": "Default", "current": true, "last_activity_at": 1_700_000_000 },
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
        .and(path("/api/mobile/devices"))
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
        .and(path("/api/mobile/devices/d-other"))
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
        .and(path("/api/mobile/operator/pause"))
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

#[tokio::test]
async fn pause_set_post_then_delete_for_unpause() {
    let (client, server) = paired_client().await;
    Mock::given(method("POST"))
        .and(path("/api/mobile/operator/pause"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"ok":true,"paused":true})))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("DELETE"))
        .and(path("/api/mobile/operator/pause"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"ok":true,"paused":false})))
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
        .and(path("/api/mobile/notifications/recent"))
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
        .and(path("/api/mobile/actions/recent"))
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
async fn list_operator_cards_unwraps_envelope() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/mobile/operator/cards"))
        .and(bearer_token(TOKEN))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "cards": [
                {
                    "id": "c1",
                    "action": "send_directive",
                    "reason": "why",
                    "target_harness": "alpha",
                    "directive_kind": "Directive",
                    "directive_subject": "Do x",
                    "directive_body": "body",
                    "status": "pending"
                },
                {
                    "id": "c2",
                    "action": "inform",
                    "status": "shown"
                }
            ]
        })))
        .mount(&server)
        .await;
    let cards = client.list_operator_cards().await.unwrap();
    assert_eq!(cards.len(), 2);
    assert_eq!(cards[0].id, "c1");
    assert_eq!(cards[0].target_harness.as_deref(), Some("alpha"));
    assert_eq!(cards[1].action, "inform");
}

#[tokio::test]
async fn dispatch_operator_card_returns_message() {
    let (client, server) = paired_client().await;
    Mock::given(method("POST"))
        .and(path("/api/mobile/operator/cards/c1/dispatch"))
        .and(bearer_token(TOKEN))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "ok": true,
            "message": "Dispatched to alpha."
        })))
        .mount(&server)
        .await;
    let message = client.dispatch_operator_card("c1").await.unwrap();
    assert_eq!(message, "Dispatched to alpha.");
}

#[tokio::test]
async fn dismiss_operator_card_returns_message() {
    let (client, server) = paired_client().await;
    Mock::given(method("POST"))
        .and(path("/api/mobile/operator/cards/c2/dismiss"))
        .and(bearer_token(TOKEN))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "ok": true,
            "message": "Dismissed: test."
        })))
        .mount(&server)
        .await;
    let message = client.dismiss_operator_card("c2").await.unwrap();
    assert_eq!(message, "Dismissed: test.");
}

#[tokio::test]
async fn standing_candidates_unwraps_envelope() {
    let (client, server) = paired_client().await;
    Mock::given(method("GET"))
        .and(path("/api/mobile/operator/standing-candidates"))
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
        .and(path("/api/mobile/operator/standing-candidates/decide"))
        .and(bearer_token(TOKEN))
        .and(body_json(json!({
            "capability": "shell:run",
            "targetHarness": "alpha",
            "decision": "approve"
        })))
        .respond_with(ResponseTemplate::new(204))
        .mount(&server)
        .await;
    client
        .standing_candidate_decide("shell:run", "alpha", "approve")
        .await
        .unwrap();
}

#[tokio::test]
async fn standing_candidate_decide_dismiss_posts_correct_body() {
    let (client, server) = paired_client().await;
    Mock::given(method("POST"))
        .and(path("/api/mobile/operator/standing-candidates/decide"))
        .and(bearer_token(TOKEN))
        .and(body_json(json!({
            "capability": "git:push",
            "targetHarness": "beta",
            "decision": "dismiss"
        })))
        .respond_with(ResponseTemplate::new(200))
        .mount(&server)
        .await;
    client
        .standing_candidate_decide("git:push", "beta", "dismiss")
        .await
        .unwrap();
}

#[tokio::test]
async fn standing_candidate_decide_surfaces_server_error() {
    let (client, server) = paired_client().await;
    Mock::given(method("POST"))
        .and(path("/api/mobile/operator/standing-candidates/decide"))
        .respond_with(ResponseTemplate::new(500))
        .mount(&server)
        .await;
    let err = client
        .standing_candidate_decide("shell:run", "alpha", "approve")
        .await
        .unwrap_err();
    match err {
        papercup_core::client::ApiError::Server { status, .. } => assert_eq!(status, 500),
        other => panic!("expected ApiError::Server, got {other:?}"),
    }
}

#[tokio::test]
async fn fallback_url_used_when_primary_unreachable() {
    // Primary URL points at a closed port → connection refused → ApiError::Network.
    // Fallback is a real wiremock server. Client should silently swap.
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/api/mobile/harnesses"))
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
        .and(path("/api/mobile/harnesses"))
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
