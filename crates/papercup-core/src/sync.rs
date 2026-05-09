// SPDX-License-Identifier: GPL-3.0-or-later
//
// Mobile sync stream — consumes `GET /api/mobile/sync/sse?token=<jwt>`.
// Backend emits one event type today, `invalidate`, with a JSON body
// `{ "id": "<ulid>", "name": "<key>", "args": <json|null> }`. The server
// also keeps a 60s ring of recent ids so reconnects can resume via
// `Last-Event-ID`.
//
// The stream is opened once via `SyncStream::connect`; a background
// task drains the underlying `EventSource` (which already reconnects
// on transient network errors with backoff) and pipes parsed events
// into an mpsc channel that the platform UI polls via `next_event`.

use std::sync::Arc;

use futures_util::StreamExt as _;
use reqwest_eventsource::{Event, RequestBuilderExt as _};
use serde::Deserialize;
use tokio::sync::{mpsc, Mutex};

#[derive(Debug, Clone)]
pub struct SyncEvent {
    pub id: String,
    pub name: String,
    /// Raw JSON for `args`, or `"null"` when the server sends none. The
    /// platform UI keeps this opaque — invalidation keys are scoped by
    /// `name`, not args.
    pub args_json: String,
}

#[derive(Debug, thiserror::Error)]
pub enum SyncError {
    #[error("stream closed")]
    Closed,
}

#[derive(Debug, Deserialize)]
struct InvalidatePayload {
    id: String,
    name: String,
    #[serde(default)]
    args: Option<serde_json::Value>,
}

pub struct SyncStream {
    rx: Mutex<mpsc::Receiver<SyncEvent>>,
    /// Drop the sender's owner to stop the background task. We hold an
    /// `Arc<Notify>`-shaped shutdown via dropping the source `EventSource`
    /// inside the task when this handle is closed.
    shutdown: Arc<tokio::sync::Notify>,
}

impl SyncStream {
    /// Open the SSE stream. The background task starts immediately and
    /// will reconnect on its own; events stream into the returned
    /// receiver until `close` is called or the task hits an
    /// unrecoverable error.
    pub fn connect(base_url: &str, device_token: &str) -> Self {
        let url = format!(
            "{}/api/mobile/sync/sse?token={}",
            base_url.trim_end_matches('/'),
            urlencode(device_token),
        );
        let (tx, rx) = mpsc::channel::<SyncEvent>(64);
        let shutdown = Arc::new(tokio::sync::Notify::new());
        let shutdown_task = shutdown.clone();

        tokio::spawn(async move {
            let client = reqwest::Client::builder()
                .user_agent(concat!("papercup-mobile/", env!("CARGO_PKG_VERSION")))
                .build()
                .expect("reqwest client");
            let mut es = match client.get(&url).eventsource() {
                Ok(es) => es,
                Err(_) => return,
            };

            loop {
                tokio::select! {
                    _ = shutdown_task.notified() => break,
                    item = es.next() => {
                        let Some(item) = item else { break };
                        match item {
                            Ok(Event::Open) => {}
                            Ok(Event::Message(msg)) if msg.event == "invalidate" => {
                                if let Ok(payload) = serde_json::from_str::<InvalidatePayload>(&msg.data) {
                                    let ev = SyncEvent {
                                        id: payload.id,
                                        name: payload.name,
                                        args_json: payload
                                            .args
                                            .as_ref()
                                            .map(|v| v.to_string())
                                            .unwrap_or_else(|| "null".to_string()),
                                    };
                                    if tx.send(ev).await.is_err() {
                                        break;
                                    }
                                }
                            }
                            Ok(Event::Message(_)) => {}
                            Err(reqwest_eventsource::Error::StreamEnded) => break,
                            Err(_) => {
                                // EventSource reconnects internally; nothing to do here.
                            }
                        }
                    }
                }
            }
            es.close();
        });

        Self {
            rx: Mutex::new(rx),
            shutdown,
        }
    }

    /// Wait for the next event. Returns `Err(SyncError::Closed)` when
    /// the background task has shut down (manually or terminally).
    pub async fn next_event(&self) -> Result<SyncEvent, SyncError> {
        let mut guard = self.rx.lock().await;
        match guard.recv().await {
            Some(ev) => Ok(ev),
            None => Err(SyncError::Closed),
        }
    }

    pub fn close(&self) {
        self.shutdown.notify_waiters();
    }
}

impl Drop for SyncStream {
    fn drop(&mut self) {
        self.close();
    }
}

fn urlencode(s: &str) -> String {
    // Minimal escape for the query value; tokens are URL-safe base64
    // already, so this is mostly defence-in-depth.
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(b as char),
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}
