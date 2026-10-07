//! Phone device-http requests over the existing Noise-sealed WebSocket ingress.
//! The portal sees only sealed.packet envelopes; JWT/body/SSE remain encrypted.
//! D-019/020/021: reuse http.request/body/end, with 48 KiB upload fragments.

use base64::{engine::general_purpose::STANDARD, Engine as _};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Map, Value};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::{Error as WsError, Message};

use crate::byoc_sealed::{decode_packet, ByocSealedChannel, ByocSealedPacket};
use crate::client::ApiError;
use crate::noise_stream::Ed25519KeyPair;

const CHUNK_BYTES: usize = 48 * 1024;
const MAX_UPLOAD_BYTES: usize = 32 * 1024 * 1024;
const MAX_PACKET_BYTES: usize = 512 * 1024;

#[derive(Debug, Clone)]
pub(crate) struct SealedIdentity {
    pub local: Ed25519KeyPair,
    pub remote: [u8; 32],
}

fn malformed(detail: impl Into<String>) -> ApiError {
    ApiError::Decode(format!("sealed device HTTP: {}", detail.into()))
}

fn socket_url(base: &str) -> Result<url::Url, ApiError> {
    let mut url = url::Url::parse(base).map_err(|e| malformed(e.to_string()))?;
    let scheme = match url.scheme() {
        "http" => "ws",
        "https" => "wss",
        _ => return Err(malformed("server URL must use HTTP or HTTPS")),
    };
    if !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(malformed(
            "server URL contains credentials, query or fragment",
        ));
    }
    url.set_scheme(scheme)
        .map_err(|_| malformed("invalid WebSocket URL"))?;
    url.set_path(&format!(
        "{}/api/device/sealed",
        url.path().trim_end_matches('/')
    ));
    Ok(url)
}

fn request_frames(
    method: &str,
    path: &str,
    token: Option<&str>,
    body: Option<&Value>,
) -> Result<Vec<Map<String, Value>>, ApiError> {
    let bytes = body
        .map(serde_json::to_vec)
        .transpose()
        .map_err(|e| malformed(e.to_string()))?;
    if bytes.as_ref().is_some_and(|b| b.len() > MAX_UPLOAD_BYTES) {
        return Err(ApiError::PayloadTooLarge {
            detail: "sealed upload exceeds 32 MiB".into(),
        });
    }
    let mut headers = Map::new();
    if let Some(token) = token {
        headers.insert("authorization".into(), json!(format!("Bearer {token}")));
    }
    if bytes.is_some() {
        headers.insert("content-type".into(), json!("application/json"));
    }
    let mut header = json!({"type":"http.request", "requestId":"mobile-1", "method":method, "path":path, "headers":headers});
    let chunked = bytes.as_ref().is_some_and(|b| b.len() > CHUNK_BYTES);
    if chunked {
        header["bodyChunked"] = json!(true);
    } else if let Some(bytes) = &bytes {
        header["body"] = json!(STANDARD.encode(bytes));
    }
    let mut frames = vec![header.as_object().unwrap().clone()];
    if chunked {
        for chunk in bytes.as_ref().unwrap().chunks(CHUNK_BYTES) {
            frames.push(
                json!({"type":"http.body", "requestId":"mobile-1", "data":STANDARD.encode(chunk)})
                    .as_object()
                    .unwrap()
                    .clone(),
            );
        }
        frames.push(
            json!({"type":"http.end", "requestId":"mobile-1"})
                .as_object()
                .unwrap()
                .clone(),
        );
    }
    Ok(frames)
}

type Socket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn send_packet(socket: &mut Socket, packet: &ByocSealedPacket) -> Result<(), ApiError> {
    let text = serde_json::to_string(packet).map_err(|e| malformed(e.to_string()))?;
    if text.len() > MAX_PACKET_BYTES {
        return Err(malformed("packet exceeds relay frame cap"));
    }
    socket
        .send(Message::Text(text))
        .await
        .map_err(|e| ApiError::Network(e.to_string()))
}

async fn receive(
    socket: &mut Socket,
    channel: &mut ByocSealedChannel,
) -> Result<Vec<Map<String, Value>>, ApiError> {
    loop {
        let message = socket
            .next()
            .await
            .ok_or_else(|| ApiError::Network("sealed socket ended before http.end".into()))?
            .map_err(|e| ApiError::Network(e.to_string()))?;
        match message {
            Message::Ping(bytes) => {
                socket
                    .send(Message::Pong(bytes))
                    .await
                    .map_err(|e| ApiError::Network(e.to_string()))?;
            }
            Message::Pong(_) => {}
            Message::Text(text) => {
                if text.len() > MAX_PACKET_BYTES {
                    return Err(malformed("relay frame exceeds cap"));
                }
                let packet: ByocSealedPacket =
                    serde_json::from_str(&text).map_err(|e| malformed(e.to_string()))?;
                if !packet.is_ours() {
                    return Err(malformed("unexpected relay envelope"));
                }
                let progress = channel
                    .receive(&packet)
                    .map_err(|e| malformed(e.to_string()))?;
                for packet in progress.outbound {
                    send_packet(socket, &packet).await?;
                }
                return Ok(progress.frames);
            }
            _ => {
                return Err(ApiError::Network(
                    "sealed socket closed or sent non-packet data".into(),
                ))
            }
        }
    }
}

fn error_response(frame: &Map<String, Value>) -> Result<reqwest::Response, ApiError> {
    let code = frame
        .get("code")
        .and_then(Value::as_str)
        .ok_or_else(|| malformed("http.error lacks code"))?;
    let status = frame.get("status").and_then(Value::as_u64).unwrap_or(502);
    let status = u16::try_from(status).map_err(|_| malformed("invalid error status"))?;
    let response = http::Response::builder()
        .status(status)
        .body(json!({"error":code}).to_string())
        .map_err(|e| malformed(e.to_string()))?;
    Ok(response.into())
}

/// Return a normal reqwest response, preserving the existing JSON/error/SSE pipeline.
/// A bounded body queue propagates consumer cancellation back to the owned socket.
pub(crate) async fn request(
    base: &str,
    identity: SealedIdentity,
    method: &str,
    path: &str,
    token: Option<&str>,
    body: Option<&Value>,
) -> Result<reqwest::Response, ApiError> {
    let frames = request_frames(method, path, token, body)?;
    let budget = std::time::Duration::from_secs(if path == "/api/device/operator/converse" {
        90
    } else {
        15
    });
    let deadline = tokio::time::Instant::now() + budget;
    let operation = async {
        let url = socket_url(base)?;
        let (mut socket, _) = tokio_tungstenite::connect_async(url.as_str())
            .await
            .map_err(|error| match error {
                WsError::Http(response) if response.status().as_u16() == 503 => {
                    ApiError::WorkspaceOffline {
                        retry_after_secs: response
                            .headers()
                            .get("retry-after")
                            .and_then(|v| v.to_str().ok())
                            .and_then(|v| v.trim().parse().ok()),
                    }
                }
                WsError::Http(response) => ApiError::RelayRefused {
                    status: response.status().as_u16(),
                    code: "sealed_ingress_refused".into(),
                },
                other => ApiError::Network(other.to_string()),
            })?;
        let (mut channel, first) = ByocSealedChannel::start(identity.local, identity.remote)
            .map_err(|e| malformed(e.to_string()))?;
        send_packet(&mut socket, &first).await?;
        while !channel.is_open() {
            receive(&mut socket, &mut channel).await?;
        }
        for frame in frames {
            for packet in channel.send(&frame).map_err(|e| malformed(e.to_string()))? {
                send_packet(&mut socket, &packet).await?;
            }
        }
        let (sender, receiver) = mpsc::channel::<Result<Vec<u8>, ApiError>>(8);
        loop {
            let received = receive(&mut socket, &mut channel).await?;
            for (index, frame) in received.iter().enumerate() {
                // Readiness belongs to the channel and has no requestId.
                // HostedWorkspaceSessionHost sends it inside Noise on open.
                if matches!(
                    frame.get("type").and_then(Value::as_str),
                    Some("hello" | "http.ready")
                ) {
                    continue;
                }
                check_id(frame)?;
                match frame.get("type").and_then(Value::as_str) {
                    Some("http.error") => return error_response(frame),
                    Some("http.response") => {
                        let status = frame
                            .get("status")
                            .and_then(Value::as_u64)
                            .and_then(|v| u16::try_from(v).ok())
                            .filter(|v| (100..=599).contains(v))
                            .ok_or_else(|| malformed("invalid response status"))?;
                        let headers = frame
                            .get("headers")
                            .and_then(Value::as_object)
                            .ok_or_else(|| malformed("invalid response headers"))?;
                        let mut response = http::Response::builder().status(status);
                        for (key, value) in headers {
                            response = response.header(
                                key,
                                value
                                    .as_str()
                                    .ok_or_else(|| malformed("invalid header value"))?,
                            );
                        }
                        let stream = futures_util::stream::unfold(receiver, |mut rx| async {
                            rx.recv().await.map(|chunk| (chunk, rx))
                        });
                        let response: reqwest::Response = response
                            .body(reqwest::Body::wrap_stream(stream))
                            .map_err(|e| malformed(e.to_string()))?
                            .into();
                        let remainder = received[index + 1..].to_vec();
                        tokio::spawn(async move {
                            let result = tokio::time::timeout_at(
                                deadline,
                                stream_body(&mut socket, &mut channel, &sender, remainder),
                            )
                            .await;
                            let error = match result {
                                Ok(Ok(())) => None,
                                Ok(Err(e)) => Some(e),
                                Err(_) => {
                                    Some(ApiError::Network("sealed request timed out".into()))
                                }
                            };
                            if let Some(error) = error {
                                let _ = sender.send(Err(error)).await;
                            }
                            // Close the owned channel/socket on completion, error or cancellation.
                            let _ = tokio::time::timeout(
                                std::time::Duration::from_secs(1),
                                socket.close(None),
                            )
                            .await;
                        });
                        return Ok(response);
                    }
                    _ => return Err(malformed("body or end arrived before response headers")),
                }
            }
        }
    };
    tokio::time::timeout_at(deadline, operation)
        .await
        .map_err(|_| ApiError::Network("sealed request timed out".into()))?
}

fn check_id(frame: &Map<String, Value>) -> Result<(), ApiError> {
    if frame.get("requestId").and_then(Value::as_str) != Some("mobile-1") {
        return Err(malformed("response requestId mismatch"));
    }
    Ok(())
}

async fn stream_body(
    socket: &mut Socket,
    channel: &mut ByocSealedChannel,
    sender: &mpsc::Sender<Result<Vec<u8>, ApiError>>,
    mut pending: Vec<Map<String, Value>>,
) -> Result<(), ApiError> {
    loop {
        for frame in pending.drain(..) {
            check_id(&frame)?;
            match frame.get("type").and_then(Value::as_str) {
                Some("http.body") => {
                    let encoded = frame
                        .get("data")
                        .and_then(Value::as_str)
                        .ok_or_else(|| malformed("body lacks data"))?;
                    let bytes = decode_packet(encoded).map_err(|e| malformed(e.to_string()))?;
                    if bytes.len() > CHUNK_BYTES {
                        return Err(malformed("response body fragment exceeds cap"));
                    }
                    if sender.send(Ok(bytes)).await.is_err() {
                        return Ok(());
                    }
                }
                Some("http.end") => return Ok(()),
                Some("http.error") => {
                    return Err(ApiError::Server {
                        status: 502,
                        detail: frame
                            .get("code")
                            .and_then(Value::as_str)
                            .unwrap_or("operator_stream_failed")
                            .into(),
                    })
                }
                _ => return Err(malformed("unexpected frame after response headers")),
            }
        }
        tokio::select! {
            _ = sender.closed() => return Ok(()),
            frames = receive(socket, channel) => pending = frames?,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ingress_preserves_opaque_relay_prefix_and_has_no_credentials() {
        assert_eq!(
            socket_url("https://portal.test/api/workspaces/ws_1/")
                .unwrap()
                .as_str(),
            "wss://portal.test/api/workspaces/ws_1/api/device/sealed"
        );
        assert!(socket_url("https://token@portal.test").is_err());
        assert!(socket_url("https://portal.test?token=x").is_err());
    }

    #[test]
    fn upload_chunks_are_ordered_bounded_and_reconstruct_exact_json() {
        let body = json!({"audio":"a".repeat(512*1024)});
        let frames = request_frames("POST", "/api/device/voice", Some("jwt"), Some(&body)).unwrap();
        assert_eq!(frames[0]["bodyChunked"], true);
        assert!(frames[0].get("body").is_none());
        assert_eq!(frames.last().unwrap()["type"], "http.end");
        let mut bytes = Vec::new();
        for frame in &frames[1..frames.len() - 1] {
            assert_eq!(frame["type"], "http.body");
            assert_eq!(frame["requestId"], "mobile-1");
            let chunk = decode_packet(frame["data"].as_str().unwrap()).unwrap();
            assert!(chunk.len() <= CHUNK_BYTES);
            bytes.extend(chunk);
        }
        assert_eq!(serde_json::from_slice::<Value>(&bytes).unwrap(), body);
    }

    #[test]
    fn pair_frames_contain_no_bearer_and_small_bodies_stay_inline() {
        let frames = request_frames(
            "POST",
            "/api/device/pair",
            None,
            Some(&json!({"pairToken":"tok"})),
        )
        .unwrap();
        assert_eq!(frames.len(), 1);
        assert!(frames[0]["headers"].get("authorization").is_none());
        assert!(frames[0].get("bodyChunked").is_none());
        assert_eq!(
            decode_packet(frames[0]["body"].as_str().unwrap()).unwrap(),
            br#"{"pairToken":"tok"}"#
        );
    }
}
