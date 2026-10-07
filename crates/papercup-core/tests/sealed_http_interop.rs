//! Actual client WebSocket/Noise/HTTP/SSE interop with the maintained TS responder.
//! Mandatory in release proof with PAPERCUP_REQUIRE_SECRET_STREAM_INTEROP=1.
use papercup_core::client::{ApiError, OperatorClient};
use papercup_core::noise_stream::Ed25519KeyPair;
use papercup_core::types::PairBody;
use serde_json::Value;
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::Duration;

struct Responder {
    child: Child,
    base: String,
    key: [u8; 32],
}
impl Drop for Responder {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn responder(mode: &str) -> Option<Responder> {
    let root = std::env::var_os("PAPERCUP_PAPERCUSP_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../papercusp"));
    if !root.join("node_modules/tsx/package.json").is_file()
        || !root.join("node_modules/ws/package.json").is_file()
    {
        assert_ne!(
            std::env::var("PAPERCUP_REQUIRE_SECRET_STREAM_INTEROP").as_deref(),
            Ok("1"),
            "mandatory TS interop dependencies absent"
        );
        eprintln!("SKIP sealed HTTP interop: set PAPERCUP_PAPERCUSP_ROOT");
        return None;
    }
    let fixture =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/sealed-http-responder.mjs");
    let mut child = Command::new("node")
        .current_dir(&root)
        .args(["--import", "tsx"])
        .arg(fixture)
        .arg(&root)
        .arg(mode)
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("start TS responder");
    let stdout = child.stdout.take().unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut line = String::new();
        let result = BufReader::new(stdout).read_line(&mut line);
        let _ = tx.send((result, line));
    });
    let (result, line) = rx
        .recv_timeout(Duration::from_secs(20))
        .expect("bounded fixture ready");
    result.expect("read fixture ready");
    let ready: Value = serde_json::from_str(&line).expect("fixture ready JSON");
    Some(Responder {
        child,
        base: ready["base"].as_str().unwrap().into(),
        key: serde_json::from_value(ready["publicKey"].clone()).unwrap(),
    })
}

fn client(responder: &Responder, token: Option<&str>) -> OperatorClient {
    let client = OperatorClient::new(&responder.base, token.map(String::from));
    client
        .configure_sealed_transport(&[0x31; 32], &responder.key)
        .unwrap();
    client
}

#[tokio::test]
async fn sealed_pair_and_authenticated_json_never_expose_bearer_to_portal() {
    let Some(server) = responder("normal") else {
        return;
    };
    let anon = client(&server, Some("old-device-token"));
    let key = Ed25519KeyPair::from_seed(&[0x31; 32]);
    let outcome = anon
        .pair_with_noise(
            PairBody {
                pair_token: "pair-canary".into(),
            },
            &key.public_key(),
        )
        .await
        .unwrap();
    assert_eq!(outcome.device_id, "did-sealed");
    let paired = client(&server, Some(&outcome.device_token));
    let result = paired.rest_query("test", "{}").await.unwrap();
    assert_eq!(result.rows["authorization"], "Bearer test-jwt");
    assert_eq!(result.rows["plaintextCanaryFound"], false);
    assert!(result.rows["maximumPacketBytes"].as_u64().unwrap() < 512 * 1024);
}

#[tokio::test]
async fn sealed_large_upload_and_sse_preserve_chunks_and_utf8() {
    let Some(server) = responder("normal") else {
        return;
    };
    let client = client(&server, Some("test-jwt"));
    let mut deltas = Vec::new();
    client
        .operator_converse_stream(
            &format!("CANARY-private-🌍{}", "x".repeat(700 * 1024)),
            |text| deltas.push(text.to_string()),
        )
        .await
        .unwrap();
    assert_eq!(deltas[0], "héllo 🌍");
    let chunks: usize = deltas[1].strip_prefix("chunks=").unwrap().parse().unwrap();
    assert!(chunks > 14, "actual upload must use bounded body fragments");
}

#[tokio::test]
async fn sealed_offline_remains_retryable_and_reconnect_uses_same_credentials() {
    let Some(server) = responder("offline") else {
        return;
    };
    let client = client(&server, Some("test-jwt"));
    for _ in 0..2 {
        assert!(matches!(
            client.list_harnesses().await,
            Err(ApiError::WorkspaceOffline {
                retry_after_secs: Some(7)
            })
        ));
    }
    let recovered = responder("normal").expect("same-key recovery fixture");
    client.set_base_url(&recovered.base);
    let result = client.rest_query("test", "{}").await.unwrap();
    assert_eq!(result.rows["authorization"], "Bearer test-jwt");
}

#[tokio::test]
async fn sealed_auth_and_relay_policy_verdicts_keep_their_distinct_meanings() {
    for mode in ["unauthorized", "relay-refused"] {
        let Some(server) = responder(mode) else {
            return;
        };
        let client = client(&server, Some("test-jwt"));
        for _ in 0..2 {
            let result = client.list_harnesses().await;
            if mode == "unauthorized" {
                assert!(matches!(result, Err(ApiError::Unauthorized)));
            } else {
                assert!(matches!(
                    result,
                    Err(ApiError::RelayRefused { status: 403, .. })
                ));
            }
        }
    }
}

#[tokio::test]
async fn wrong_machine_pin_never_downgrades_to_plaintext() {
    let Some(server) = responder("normal") else {
        return;
    };
    let client =
        OperatorClient::new_with_fallback(&server.base, &server.base, Some("test-jwt".into()));
    client
        .configure_sealed_transport(
            &[0x31; 32],
            &Ed25519KeyPair::from_seed(&[7; 32]).public_key(),
        )
        .unwrap();
    assert!(matches!(
        client.list_harnesses().await,
        Err(ApiError::Decode(_))
    ));
}

#[tokio::test]
async fn mismatched_http_response_identity_fails_closed() {
    let Some(server) = responder("bad-id") else {
        return;
    };
    assert!(matches!(
        client(&server, Some("test-jwt")).list_harnesses().await,
        Err(ApiError::Decode(_))
    ));
}
