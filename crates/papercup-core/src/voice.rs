// SPDX-License-Identifier: GPL-3.0-or-later
//
// Voice WebSocket client for `/api/device/voice`.
//
// Wire protocol (mirrors the Tauri-era impl, see legacy/VOICE_FEEDBACK_RESPONSE.md):
//   Auth   : Sec-WebSocket-Protocol: papercusp.bearer.<jwt>
//   Phone→Server frames (JSON):
//     {kind:"hello", wakeWord}                      sent on connect
//     {kind:"transcript", text}                     STT result from phone
//     {kind:"status", status:"idle"|"listening"|"speaking"|"connecting"|"paused"}
//   Server→Phone frames (JSON):
//     {kind:"speak", text, source:"operator"|"oracle"|"agent"|"system",
//      agentId?, format?:"plain"|"ssml"}            TTS request
//
// Phone does STT + TTS locally (Android SpeechRecognizer / TextToSpeech;
// iOS SFSpeechRecognizer / AVSpeechSynthesizer). The server only routes
// transcripts to the operator and speak frames back. We never carry PCM.
//
// Reconnect: exponential backoff 1s → 30s. On close 1008 (auth) the
// caller is responsible for re-pair + reconnect (out of scope here so
// the platform UI can surface an "unauthenticated" message).

use std::sync::Arc;

use futures_util::{SinkExt as _, StreamExt as _};
use serde::{Deserialize, Serialize};
use tokio::sync::{mpsc, Mutex};
use tokio_tungstenite::tungstenite::handshake::client::generate_key;
use tokio_tungstenite::tungstenite::http::{Request, Uri};
use tokio_tungstenite::tungstenite::protocol::Message;

#[derive(Debug, Clone)]
pub enum VoiceStatus {
    Idle,
    Connecting,
    Listening,
    Speaking,
    Paused,
}

impl VoiceStatus {
    fn as_str(&self) -> &'static str {
        match self {
            VoiceStatus::Idle => "idle",
            VoiceStatus::Connecting => "connecting",
            VoiceStatus::Listening => "listening",
            VoiceStatus::Speaking => "speaking",
            VoiceStatus::Paused => "paused",
        }
    }
}

#[derive(Debug, Clone)]
pub enum VoiceEvent {
    /// First frame after the WebSocket completes its handshake.
    Connected,
    /// TTS-side speak request from server.
    Speak {
        text: String,
        source: String,
        agent_id: Option<String>,
        format: Option<String>,
    },
    /// Server closed the connection. `code` is the WS close code; 1008 means
    /// auth was rejected and the caller should re-pair before reconnecting.
    Closed { code: u16, reason: String },
}

#[derive(Debug, thiserror::Error)]
pub enum VoiceError {
    #[error("connect failed: {0}")]
    Connect(String),
    #[error("stream closed")]
    Closed,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "kind")]
enum InboundFrame {
    #[serde(rename = "speak")]
    Speak {
        text: String,
        source: String,
        #[serde(default, rename = "agentId")]
        agent_id: Option<String>,
        #[serde(default)]
        format: Option<String>,
    },
    /// Catch-all so a future server-side frame doesn't crash the client.
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Serialize)]
#[serde(tag = "kind")]
enum OutboundFrame<'a> {
    #[serde(rename = "hello")]
    Hello {
        #[serde(rename = "wakeWord")]
        wake_word: &'a str,
    },
    #[serde(rename = "status")]
    Status { status: &'a str },
    #[serde(rename = "transcript")]
    Transcript { text: &'a str },
}

pub struct VoiceClient {
    rx: Mutex<mpsc::Receiver<VoiceEvent>>,
    tx: mpsc::Sender<OwnedOutbound>,
    shutdown: Arc<tokio::sync::Notify>,
}

enum OwnedOutbound {
    Hello { wake_word: String },
    Status { status: String },
    Transcript { text: String },
}

impl VoiceClient {
    /// Open the WebSocket. The background task negotiates the handshake,
    /// pushes frames to / from `next_event` + the `send_*` methods, and
    /// reconnects on transient errors. `next_event` returns `Closed` once
    /// per terminal close (e.g. auth-fail) so the platform UI can react.
    pub fn connect(base_url: &str, device_token: &str, wake_word: Option<&str>) -> Self {
        let (event_tx, event_rx) = mpsc::channel::<VoiceEvent>(64);
        let (out_tx, mut out_rx) = mpsc::channel::<OwnedOutbound>(64);
        let shutdown = Arc::new(tokio::sync::Notify::new());

        let url = build_ws_url(base_url);
        let token = device_token.to_string();
        let initial_wake = wake_word.map(str::to_string);
        let shutdown_task = shutdown.clone();
        let event_tx_task = event_tx.clone();

        tokio::spawn(async move {
            let mut backoff_ms: u64 = 1000;
            loop {
                tokio::select! {
                    _ = shutdown_task.notified() => break,
                    result = run_session(&url, &token, &initial_wake, &event_tx_task, &mut out_rx) => {
                        match result {
                            SessionResult::Closed { code, reason } => {
                                let _ = event_tx_task
                                    .send(VoiceEvent::Closed { code, reason })
                                    .await;
                                if code == 1008 {
                                    break; // auth-fail; caller must re-pair
                                }
                            }
                            SessionResult::Transient(_) => {}
                        }
                    }
                }
                // Exponential backoff capped at 30s.
                tokio::time::sleep(std::time::Duration::from_millis(backoff_ms)).await;
                backoff_ms = (backoff_ms * 2).min(30_000);
            }
        });

        Self {
            rx: Mutex::new(event_rx),
            tx: out_tx,
            shutdown,
        }
    }

    pub async fn next_event(&self) -> Result<VoiceEvent, VoiceError> {
        let mut g = self.rx.lock().await;
        g.recv().await.ok_or(VoiceError::Closed)
    }

    pub async fn send_status(&self, status: VoiceStatus) {
        let _ = self
            .tx
            .send(OwnedOutbound::Status {
                status: status.as_str().to_string(),
            })
            .await;
    }

    pub async fn send_transcript(&self, text: String) {
        let _ = self.tx.send(OwnedOutbound::Transcript { text }).await;
    }

    pub async fn send_hello(&self, wake_word: String) {
        let _ = self.tx.send(OwnedOutbound::Hello { wake_word }).await;
    }

    pub fn close(&self) {
        self.shutdown.notify_waiters();
    }
}

impl Drop for VoiceClient {
    fn drop(&mut self) {
        self.close();
    }
}

enum SessionResult {
    /// Server closed cleanly with a code. 1008 means auth rejected.
    Closed { code: u16, reason: String },
    /// Underlying transport error; treat as transient and reconnect.
    /// String is the underlying transport error, kept for future logging.
    Transient(#[allow(dead_code)] String),
}

async fn run_session(
    url: &str,
    token: &str,
    initial_wake: &Option<String>,
    event_tx: &mpsc::Sender<VoiceEvent>,
    out_rx: &mut mpsc::Receiver<OwnedOutbound>,
) -> SessionResult {
    // Build a Request manually so we can attach the bearer subprotocol.
    let uri: Uri = match url.parse() {
        Ok(u) => u,
        Err(e) => return SessionResult::Transient(format!("uri: {e}")),
    };
    let host = uri.host().unwrap_or("").to_string();
    let host_header = match uri.port() {
        Some(p) => format!("{host}:{p}"),
        None => host,
    };
    let req = match Request::builder()
        .method("GET")
        .uri(&uri)
        .header("Host", host_header)
        .header("Connection", "Upgrade")
        .header("Upgrade", "websocket")
        .header("Sec-WebSocket-Version", "13")
        .header("Sec-WebSocket-Key", generate_key())
        .header(
            "Sec-WebSocket-Protocol",
            format!("papercusp.bearer.{token}"),
        )
        .body(())
    {
        Ok(r) => r,
        Err(e) => return SessionResult::Transient(format!("req: {e}")),
    };

    let (ws, _resp) = match tokio_tungstenite::connect_async(req).await {
        Ok(p) => p,
        Err(e) => return SessionResult::Transient(format!("connect: {e}")),
    };

    let _ = event_tx.send(VoiceEvent::Connected).await;

    let (mut sink, mut stream) = ws.split();

    if let Some(w) = initial_wake.as_deref() {
        let frame = serde_json::to_string(&OutboundFrame::Hello { wake_word: w }).unwrap();
        if sink.send(Message::Text(frame)).await.is_err() {
            return SessionResult::Transient("send hello".into());
        }
    }

    loop {
        tokio::select! {
            biased;
            outbound = out_rx.recv() => {
                let Some(o) = outbound else { return SessionResult::Closed { code: 1000, reason: "shutdown".into() }; };
                let frame = match o {
                    OwnedOutbound::Hello { wake_word } => serde_json::to_string(&OutboundFrame::Hello { wake_word: &wake_word }),
                    OwnedOutbound::Status { status } => serde_json::to_string(&OutboundFrame::Status { status: &status }),
                    OwnedOutbound::Transcript { text } => serde_json::to_string(&OutboundFrame::Transcript { text: &text }),
                };
                let frame = match frame { Ok(f) => f, Err(_) => continue };
                if sink.send(Message::Text(frame)).await.is_err() {
                    return SessionResult::Transient("send".into());
                }
            }
            inbound = stream.next() => {
                let Some(item) = inbound else {
                    return SessionResult::Transient("eof".into());
                };
                match item {
                    Ok(Message::Text(text)) => {
                        if let Ok(InboundFrame::Speak { text, source, agent_id, format }) =
                            serde_json::from_str::<InboundFrame>(&text)
                        {
                            let _ = event_tx
                                .send(VoiceEvent::Speak { text, source, agent_id, format })
                                .await;
                        }
                    }
                    Ok(Message::Close(frame)) => {
                        let (code, reason) = frame
                            .map(|f| (u16::from(f.code), f.reason.into_owned()))
                            .unwrap_or((1006, String::new()));
                        return SessionResult::Closed { code, reason };
                    }
                    Ok(Message::Ping(p)) => {
                        let _ = sink.send(Message::Pong(p)).await;
                    }
                    Ok(_) => {}
                    Err(e) => return SessionResult::Transient(format!("recv: {e}")),
                }
            }
        }
    }
}

fn build_ws_url(base_url: &str) -> String {
    let trimmed = base_url.trim_end_matches('/');
    let scheme_swapped = if let Some(rest) = trimmed.strip_prefix("https://") {
        format!("wss://{rest}")
    } else if let Some(rest) = trimmed.strip_prefix("http://") {
        format!("ws://{rest}")
    } else {
        format!("ws://{trimmed}")
    };
    format!("{scheme_swapped}/api/device/voice")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ws_url_https_to_wss() {
        assert_eq!(
            build_ws_url("https://api.papercuspai.com/"),
            "wss://api.papercuspai.com/api/device/voice"
        );
    }

    #[test]
    fn ws_url_http_to_ws() {
        assert_eq!(
            build_ws_url("http://10.0.2.2:3055"),
            "ws://10.0.2.2:3055/api/device/voice"
        );
    }

    #[test]
    fn voice_status_serialises() {
        assert_eq!(VoiceStatus::Listening.as_str(), "listening");
        assert_eq!(VoiceStatus::Speaking.as_str(), "speaking");
    }
}
