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
        .and(path("/api/mobile/desktop/devices"))
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
        .and(path("/api/mobile/desktop/devices/d-other"))
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
