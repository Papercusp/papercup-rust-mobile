// SPDX-License-Identifier: GPL-3.0-or-later
//
// HTTP client for the Papercusp operator's `/api/device/*` surface.
//
// Contract notes (re-audited against the live server, 2026-06-05 —
// mobile-apps-revival-redesign D-001):
//   - Errors arrive in TWO envelopes: route-stack errors are nested
//     `{"error":{code,message}}`; handler errors are flat
//     `{"error":"code", hint?, detail?}`. `ErrorBody` decodes both.
//   - 401 (no/bad token) AND 403 (principal resolved but rejected) both
//     mean "this device token is no good here" → `ApiError::Unauthorized`
//     → the UI re-pairs.
//   - Pairing returns `defguardEnrollmentUrl` (Defguard self-enrollment);
//     no WireGuard config is exchanged at pair time.
//   - Sync is polled via `GET /api/device/rest-query` (`rest_query`);
//     the old `/sync/sse` stream is gone.
//   - The voice WS lives on its own port, discovered via
//     `GET /api/device/runtime-config` (`runtime_config`).

use serde::de::DeserializeOwned;

use crate::types::{
    AttentionResp, AuditResp, AuditRow, ConversationRead, ConverseBody, DesktopDevicesResp,
    DeviceRow, ErrorBody, HarnessLite, HarnessStatusFull, ListResp, PairBody, PairResp, PauseInfo,
    PlanDetail, PlanItemStatusBody, PlanSummary, PlansResp, PushRegisterBody, RestQueryResp,
    RunningHarnessPhase, RunningResp, RunningScan, RuntimeConfig, StandingCandidate,
    StandingCandidatesResp, StandingDecisionBody, ToastRow, ToastsResp, VoiceLeaseRead,
    VoiceLeaseShape, VoiceSessionInit, WorkspaceItem, WorkspaceSwitchBody, WorkspaceSwitchResp,
    WorkspacesResp,
};

#[derive(Debug, thiserror::Error)]
pub enum ApiError {
    #[error("network: {0}")]
    Network(String),
    #[error("server returned {status}: {detail}")]
    Server { status: u16, detail: String },
    #[error("malformed JSON from server: {0}")]
    Decode(String),
    #[error("not authenticated — re-pair the device")]
    Unauthorized,
    /// The cloud portal relay reached no live connector for the workspace
    /// (`503 workspace_offline`). Retryable; the pairing is still valid.
    #[error("cloud workspace offline — retry later")]
    WorkspaceOffline { retry_after_secs: Option<u32> },
    /// The cloud portal relay refused the request by policy
    /// (`route_not_relayed`, `byoc_plaintext_relay_refused`, …). This is
    /// never a credential verdict, so it must never trigger a re-pair
    /// (android-public-release-2026-10-01 D-013).
    #[error("cloud relay refused the request ({status} {code})")]
    RelayRefused { status: u16, code: String },
    /// `413` — the body exceeded the relay frame cap (512 KiB); callers
    /// that can chunk (voice, long turns) should split and retry.
    #[error("request body too large: {detail}")]
    PayloadTooLarge { detail: String },
    /// `429` — rate limited; honour `retry_after_secs` before retrying.
    #[error("rate limited — retry later")]
    RateLimited { retry_after_secs: Option<u32> },
}

/// Error codes the cloud portal relay itself answers with (see
/// `papercusp/packages/operator-core/lib/workspace-host/hosted-app-relay.ts`
/// `refuse(...)`). A 401/403 carrying one of these is a relay POLICY
/// refusal, not the VM rejecting the device token, so it must not map to
/// `Unauthorized` (which wipes the pairing).
const RELAY_POLICY_CODES: &[&str] = &[
    "route_not_relayed",
    "byoc_plaintext_relay_refused",
    "app_key_required",
    "invalid_path",
    "method_not_allowed",
];

fn retry_after_secs(headers: &reqwest::header::HeaderMap) -> Option<u32> {
    headers
        .get(reqwest::header::RETRY_AFTER)?
        .to_str()
        .ok()?
        .trim()
        .parse::<u32>()
        .ok()
}

impl From<reqwest::Error> for ApiError {
    fn from(e: reqwest::Error) -> Self {
        ApiError::Network(e.to_string())
    }
}

/// Parse one SSE frame (`event: x\ndata: {...}`) into `(event, data)`.
/// Multiple `data:` lines join with newlines per the SSE spec; the event
/// name defaults to `message` when absent. Frames with no data (e.g. a
/// bare comment/keep-alive `: ping`) return None.
fn parse_sse_frame(frame: &str) -> Option<(String, String)> {
    let mut event = String::from("message");
    let mut data_lines: Vec<&str> = Vec::new();
    for line in frame.lines() {
        if let Some(v) = line.strip_prefix("event:") {
            event = v.trim().to_string();
        } else if let Some(v) = line.strip_prefix("data:") {
            data_lines.push(v.strip_prefix(' ').unwrap_or(v));
        }
    }
    if data_lines.is_empty() {
        return None;
    }
    Some((event, data_lines.join("\n")))
}

// Keep transport chunks as bytes until a complete frame arrives: an HTTP
// chunk boundary can fall inside a UTF-8 character or a CRLF separator.
fn take_sse_frame(buffer: &mut Vec<u8>) -> Result<Option<String>, ApiError> {
    let lf = buffer
        .windows(2)
        .position(|bytes| bytes == b"\n\n")
        .map(|pos| (pos, 2));
    let crlf = buffer
        .windows(4)
        .position(|bytes| bytes == b"\r\n\r\n")
        .map(|pos| (pos, 4));
    let Some((position, separator_length)) = lf
        .into_iter()
        .chain(crlf)
        .min_by_key(|(position, _)| *position)
    else {
        return Ok(None);
    };
    let frame = std::str::from_utf8(&buffer[..position])
        .map_err(|error| ApiError::Decode(format!("invalid UTF-8 in chat stream: {error}")))?
        .to_owned();
    buffer.drain(..position + separator_length);
    Ok(Some(frame))
}

#[cfg(test)]
mod stream_frame_tests {
    use super::*;

    #[test]
    fn chunk_boundaries_do_not_corrupt_utf8_or_frame_separators() {
        for separator in ["\n", "\r\n"] {
            let wire = format!(
                "event: delta{separator}data: {{\"text\":\"héllo 🌍\"}}{separator}{separator}"
            );
            for split in 1..wire.len() {
                let mut buffer = wire.as_bytes()[..split].to_vec();
                assert!(take_sse_frame(&mut buffer).unwrap().is_none());
                buffer.extend_from_slice(&wire.as_bytes()[split..]);
                let frame = take_sse_frame(&mut buffer).unwrap().unwrap();
                let (event, data) = parse_sse_frame(&frame).unwrap();
                assert_eq!(event, "delta");
                assert_eq!(
                    serde_json::from_str::<serde_json::Value>(&data).unwrap()["text"],
                    "héllo 🌍"
                );
                assert!(buffer.is_empty());
            }
        }
    }

    #[test]
    fn complete_frames_reject_invalid_utf8() {
        assert!(matches!(
            take_sse_frame(&mut b"data: \xff\n\n".to_vec()),
            Err(ApiError::Decode(_))
        ));
    }
}

/// Map a non-success response to an `ApiError`.
///
/// The body's error CODE is read before the status is trusted, because
/// the cloud portal relay and the VM share status codes with different
/// meanings (D-013):
/// - a relay policy code (`RELAY_POLICY_CODES`) → `RelayRefused`, never
///   a re-pair, whatever the status;
/// - `workspace_offline` (503) → `WorkspaceOffline` with `retry-after`;
/// - any other 401/403 is the VM rejecting the device principal →
///   `Unauthorized` (re-pair);
/// - 413 → `PayloadTooLarge`, 429 → `RateLimited`;
/// - everything else → `Server` with the decoded error envelope.
async fn into_api_error(resp: reqwest::Response) -> ApiError {
    let status = resp.status();
    let code = status.as_u16();
    let retry_after = retry_after_secs(resp.headers());
    let bytes = resp.bytes().await.unwrap_or_default();
    let body = serde_json::from_slice::<ErrorBody>(&bytes).ok();
    let error_code = body.as_ref().map(|b| b.code().to_string());

    if let Some(ec) = error_code.as_deref() {
        if RELAY_POLICY_CODES.contains(&ec) {
            return ApiError::RelayRefused {
                status: code,
                code: ec.to_string(),
            };
        }
        if ec == "workspace_offline" {
            return ApiError::WorkspaceOffline {
                retry_after_secs: retry_after,
            };
        }
    }
    if code == 401 || code == 403 {
        return ApiError::Unauthorized;
    }
    let detail = match &body {
        Some(b) => b.detail_string(),
        None => status.canonical_reason().unwrap_or("").to_string(),
    };
    match code {
        413 => ApiError::PayloadTooLarge { detail },
        429 => ApiError::RateLimited {
            retry_after_secs: retry_after,
        },
        _ => ApiError::Server {
            status: code,
            detail,
        },
    }
}

#[derive(Debug, Clone, Copy)]
enum BodyKind {
    None,
    Json,
}

#[derive(Debug, Clone)]
pub struct OperatorClient {
    base_url: std::sync::Arc<std::sync::RwLock<String>>,
    fallback_url: Option<String>,
    device_token: Option<String>,
    http: reqwest::Client,
}

impl OperatorClient {
    /// `base_url` should not include a trailing slash. e.g.
    /// `https://api.papercupai.com` or `http://10.10.0.2:3070`.
    pub fn new(base_url: impl Into<String>, device_token: Option<String>) -> Self {
        let http = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(15))
            .user_agent(concat!("papercup-mobile/", env!("CARGO_PKG_VERSION")))
            .build()
            .expect("reqwest client should build with these defaults");
        Self {
            base_url: std::sync::Arc::new(std::sync::RwLock::new(
                base_url.into().trim_end_matches('/').to_string(),
            )),
            fallback_url: None,
            device_token,
            http,
        }
    }

    /// `new_with_fallback(mesh, public, token)` — preferred mesh URL
    /// (e.g. `http://10.10.0.2:3070`) with automatic switch to the
    /// public URL (e.g. `https://api.papercupai.com`) on connect
    /// failure.
    pub fn new_with_fallback(
        primary: impl Into<String>,
        fallback: impl Into<String>,
        device_token: Option<String>,
    ) -> Self {
        let mut s = Self::new(primary, device_token);
        s.fallback_url = Some(fallback.into().trim_end_matches('/').to_string());
        s
    }

    pub fn base_url(&self) -> String {
        self.base_url.read().unwrap().clone()
    }

    /// Swap the active base URL. Public so the host can flip when mesh
    /// status changes.
    pub fn set_base_url(&self, url: impl Into<String>) {
        let mut w = self.base_url.write().unwrap();
        *w = url.into().trim_end_matches('/').to_string();
    }

    /// Returns true if the error is a connection-level network error
    /// (unreachable host, timeout) — i.e. one we should retry on the
    /// fallback URL rather than surface to the caller.
    fn is_transport_failure(err: &ApiError) -> bool {
        matches!(err, ApiError::Network(_))
    }

    /// Try `op` against the primary base URL; on transport failure +
    /// presence of a fallback URL, swap and retry once. Caller's
    /// closure receives the current base URL string.
    async fn with_fallback<F, Fut, T>(&self, op: F) -> Result<T, ApiError>
    where
        F: Fn(String) -> Fut,
        Fut: std::future::Future<Output = Result<T, ApiError>>,
    {
        let primary = self.base_url();
        match op(primary.clone()).await {
            Ok(v) => Ok(v),
            Err(e) if Self::is_transport_failure(&e) => match &self.fallback_url {
                Some(fb) if *fb != primary => {
                    self.set_base_url(fb.clone());
                    op(fb.clone()).await
                }
                _ => Err(e),
            },
            Err(e) => Err(e),
        }
    }

    /// Single request pipeline for every bearer-authed endpoint:
    /// fallback retry on transport failure, 401/403 → Unauthorized,
    /// error-envelope decode (both shapes) on other failures.
    async fn request(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<serde_json::Value>,
    ) -> Result<reqwest::Response, ApiError> {
        let token = match &self.device_token {
            Some(tok) => tok.clone(),
            None => return Err(ApiError::Unauthorized),
        };
        let body_kind = if body.is_some() {
            BodyKind::Json
        } else {
            BodyKind::None
        };
        self.with_fallback(move |base| {
            let url = format!("{base}{path}");
            let method = method.clone();
            let token = token.clone();
            let body = body.clone();
            async move {
                let mut req = self.http.request(method, &url).bearer_auth(&token);
                if path == "/api/device/operator/converse" {
                    req = req.timeout(std::time::Duration::from_secs(90));
                }
                if let (BodyKind::Json, Some(b)) = (body_kind, body) {
                    req = req.json(&b);
                }
                let resp = req.send().await?;
                if !resp.status().is_success() {
                    return Err(into_api_error(resp).await);
                }
                Ok(resp)
            }
        })
        .await
    }

    async fn request_json<T: DeserializeOwned>(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<serde_json::Value>,
    ) -> Result<T, ApiError> {
        let resp = self.request(method, path, body).await?;
        resp.json::<T>()
            .await
            .map_err(|e| ApiError::Decode(e.to_string()))
    }

    async fn request_empty(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<serde_json::Value>,
    ) -> Result<(), ApiError> {
        self.request(method, path, body).await.map(|_| ())
    }

    /// `GET /api/device/harnesses` — returns the user's harnesses.
    pub async fn list_harnesses(&self) -> Result<Vec<HarnessLite>, ApiError> {
        self.request_json::<ListResp>(reqwest::Method::GET, "/api/device/harnesses", None)
            .await
            .map(|r| r.harnesses)
    }

    /// `GET /api/device/harnesses/{slug}` — per-harness status (desktop
    /// StatusResp shape).
    pub async fn get_harness_status(&self, slug: &str) -> Result<HarnessStatusFull, ApiError> {
        let path = format!("/api/device/harnesses/{slug}");
        self.request_json::<HarnessStatusFull>(reqwest::Method::GET, &path, None)
            .await
    }

    /// `GET /api/device/running` — per-phase status of every active
    /// harness (passed/todo/blocked counts + active_roles).
    pub async fn list_running(&self) -> Result<Vec<RunningHarnessPhase>, ApiError> {
        self.request_json::<RunningResp>(reqwest::Method::GET, "/api/device/running", None)
            .await
            .map(|r| r.harnesses)
    }

    /// `GET /api/device/running` — full running snapshot including the
    /// current operator scan summary when one is active.
    pub async fn running_snapshot(
        &self,
    ) -> Result<(Option<RunningScan>, Vec<RunningHarnessPhase>), ApiError> {
        self.request_json::<RunningResp>(reqwest::Method::GET, "/api/device/running", None)
            .await
            .map(|r| (r.scan, r.harnesses))
    }

    /// Current presence-based fleet/pot activity. A null tile is unavailable,
    /// never a measured empty fleet.
    pub async fn monitoring(&self) -> Result<crate::types::MonitoringSnapshot, ApiError> {
        self.request_json(reqwest::Method::GET, "/api/device/monitoring", None)
            .await
    }

    /// `GET /api/device/runtime-config` — post-pair device config: mesh
    /// host + the voice WS port/path (the WS lives on its own port, NOT
    /// the API port; `voice_ws.port == None` means voice is unavailable).
    pub async fn runtime_config(&self) -> Result<RuntimeConfig, ApiError> {
        self.request_json::<RuntimeConfig>(reqwest::Method::GET, "/api/device/runtime-config", None)
            .await
    }

    /// `GET /api/device/rest-query?name=&args=` — the polling sync
    /// fetcher. Returns the raw `rows` JSON (the cache layer stays
    /// name-keyed + UI-agnostic). Known names today: `toastLog.recent`,
    /// `auditLog.recent`, `operatorScans.running`, `harnessStatus.list`,
    /// `harnessStatus.byHarness`, `standingCandidates.list`.
    pub async fn rest_query(&self, name: &str, args_json: &str) -> Result<RestQueryResp, ApiError> {
        let path = format!(
            "/api/device/rest-query?name={}&args={}",
            urlencode(name),
            urlencode(args_json),
        );
        self.request_json::<RestQueryResp>(reqwest::Method::GET, &path, None)
            .await
    }

    /// `GET /api/device/voice-session-init` — mints an ElevenLabs Conv AI
    /// session token (the EL conversational voice flow). Server-side
    /// cooldown (8s) and EL concurrency limits surface as
    /// `ApiError::Server` with the hint text in `detail`.
    pub async fn voice_session_init(&self) -> Result<VoiceSessionInit, ApiError> {
        self.request_json::<VoiceSessionInit>(
            reqwest::Method::GET,
            "/api/device/voice-session-init",
            None,
        )
        .await
    }

    /// `GET /api/device/voice-lease` — current lease holder (or `None`
    /// if no one is listening).
    pub async fn voice_lease_get(&self) -> Result<Option<VoiceLeaseShape>, ApiError> {
        self.request_json::<VoiceLeaseRead>(reqwest::Method::GET, "/api/device/voice-lease", None)
            .await
            .map(|r| r.lease)
    }

    /// `POST /api/device/voice-lease/claim` — phone always pre-empts.
    pub async fn voice_lease_claim(&self) -> Result<(), ApiError> {
        self.request_empty(reqwest::Method::POST, "/api/device/voice-lease/claim", None)
            .await
    }

    /// `POST /api/device/voice-lease/heartbeat` — refresh-if-mine.
    pub async fn voice_lease_heartbeat(&self) -> Result<(), ApiError> {
        self.request_empty(
            reqwest::Method::POST,
            "/api/device/voice-lease/heartbeat",
            None,
        )
        .await
    }

    /// `DELETE /api/device/voice-lease` — release-if-mine; idempotent.
    pub async fn voice_lease_release(&self) -> Result<(), ApiError> {
        self.request_empty(reqwest::Method::DELETE, "/api/device/voice-lease", None)
            .await
    }

    /// `POST /api/device/heartbeat` — bumps `last_seen` server-side.
    pub async fn heartbeat(&self) -> Result<(), ApiError> {
        self.request_empty(reqwest::Method::POST, "/api/device/heartbeat", None)
            .await
    }

    /// `GET /api/device/notifications/recent` — recent toast_log entries.
    pub async fn recent_notifications(&self) -> Result<Vec<ToastRow>, ApiError> {
        self.request_json::<ToastsResp>(
            reqwest::Method::GET,
            "/api/device/notifications/recent",
            None,
        )
        .await
        .map(|r| r.toasts)
    }

    /// `GET /api/device/actions/recent` — recent audit_log entries.
    pub async fn recent_actions(&self) -> Result<Vec<AuditRow>, ApiError> {
        self.request_json::<AuditResp>(reqwest::Method::GET, "/api/device/actions/recent", None)
            .await
            .map(|r| r.entries)
    }

    /// `GET /api/device/operator/pause` — current global pause state.
    pub async fn pause_get(&self) -> Result<PauseInfo, ApiError> {
        self.request_json::<PauseInfo>(reqwest::Method::GET, "/api/device/operator/pause", None)
            .await
    }

    /// `POST` (set) or `DELETE` (clear) the global pause flag. The server
    /// responds with the new `PauseInfo`; returns its `paused`.
    pub async fn pause_set(&self, paused: bool) -> Result<bool, ApiError> {
        let method = if paused {
            reqwest::Method::POST
        } else {
            reqwest::Method::DELETE
        };
        self.request_json::<PauseInfo>(method, "/api/device/operator/pause", None)
            .await
            .map(|r| r.paused)
    }

    /// `POST /api/device/workspace/switch` — re-issues a deviceToken
    /// scoped to the new workspace. Persist the new token immediately.
    pub async fn workspace_switch(
        &self,
        workspace_id: &str,
    ) -> Result<WorkspaceSwitchResp, ApiError> {
        let body = serde_json::to_value(WorkspaceSwitchBody {
            workspace_id: workspace_id.to_string(),
        })
        .expect("WorkspaceSwitchBody serialises");
        self.request_json::<WorkspaceSwitchResp>(
            reqwest::Method::POST,
            "/api/device/workspace/switch",
            Some(body),
        )
        .await
    }

    /// `GET /api/device/workspaces` — workspaces the device can see.
    pub async fn list_workspaces(&self) -> Result<Vec<WorkspaceItem>, ApiError> {
        self.request_json::<WorkspacesResp>(reqwest::Method::GET, "/api/device/workspaces", None)
            .await
            .map(|r| r.workspaces)
    }

    /// `GET /api/device/devices` — every paired device, including this one.
    pub async fn list_desktop_devices(&self) -> Result<Vec<DeviceRow>, ApiError> {
        self.request_json::<DesktopDevicesResp>(reqwest::Method::GET, "/api/device/devices", None)
            .await
            .map(|r| r.devices)
    }

    /// `GET /api/device/operator/standing-candidates`.
    pub async fn standing_candidates(&self) -> Result<Vec<StandingCandidate>, ApiError> {
        self.request_json::<StandingCandidatesResp>(
            reqwest::Method::GET,
            "/api/device/operator/standing-candidates",
            None,
        )
        .await
        .map(|r| r.candidates)
    }

    /// `POST /api/device/operator/standing-candidates/decide`.
    pub async fn standing_candidate_decide(
        &self,
        capability: &str,
        target_harness: &str,
        decision: &str,
    ) -> Result<(), ApiError> {
        let body = serde_json::to_value(StandingDecisionBody {
            capability: capability.to_string(),
            target_harness: target_harness.to_string(),
            decision: decision.to_string(),
        })
        .expect("StandingDecisionBody serialises");
        self.request_empty(
            reqwest::Method::POST,
            "/api/device/operator/standing-candidates/decide",
            Some(body),
        )
        .await
    }

    /// `DELETE /api/device/devices/{id}` — unpair the given device.
    pub async fn revoke_device(&self, device_id: &str) -> Result<(), ApiError> {
        let path = format!("/api/device/devices/{device_id}");
        self.request_empty(reqwest::Method::DELETE, &path, None)
            .await
    }

    /// `GET /api/device/operator/conversation?limit=N` — the shared
    /// operator conversation + its most-recent turns (D-002). The Operator
    /// tab's chat history.
    pub async fn operator_conversation(&self, limit: u32) -> Result<ConversationRead, ApiError> {
        let path = format!("/api/device/operator/conversation?limit={limit}");
        self.request_json::<ConversationRead>(reqwest::Method::GET, &path, None)
            .await
    }

    /// `POST /api/device/operator/converse` — send a typed message to the
    /// operator and stream the assistant's reply deltas as they arrive.
    /// `on_delta` is called with each `delta` event's text fragment (the
    /// UI appends them into a live bubble). When this resolves Ok, the
    /// server has persisted both turns — re-read operator_conversation()
    /// to reconcile against the canonical thread. A brain turn can take
    /// tens of seconds, so this uses an extended per-request timeout.
    pub async fn operator_converse_stream(
        &self,
        text: &str,
        mut on_delta: impl FnMut(&str),
    ) -> Result<(), ApiError> {
        use futures_util::StreamExt;
        let body = serde_json::to_value(ConverseBody {
            text: text.to_string(),
            modality: "text".to_string(),
            trigger: "user_message".to_string(),
        })
        .expect("ConverseBody serialises");
        let resp = self
            .request(
                reqwest::Method::POST,
                "/api/device/operator/converse",
                Some(body),
            )
            .await?;
        // Incrementally parse the SSE frames. `delta` events carry
        // `{"text": "..."}` fragments; an `error` event carries
        // `{"message": "..."}` and fails the send.
        let mut stream = resp.bytes_stream();
        let mut buf = Vec::new();
        while let Some(chunk) = stream.next().await {
            let chunk = chunk?;
            buf.extend_from_slice(&chunk);
            while let Some(frame) = take_sse_frame(&mut buf)? {
                match parse_sse_frame(&frame) {
                    Some((event, data)) if event == "delta" => {
                        let value: serde_json::Value =
                            serde_json::from_str(&data).map_err(|error| {
                                ApiError::Decode(format!("invalid chat delta: {error}"))
                            })?;
                        let text = value
                            .get("text")
                            .and_then(|text| text.as_str())
                            .ok_or_else(|| {
                                ApiError::Decode("chat delta requires string text".into())
                            })?;
                        if !text.is_empty() {
                            on_delta(text);
                        }
                    }
                    Some((event, data)) if event == "done" => {
                        let value: serde_json::Value =
                            serde_json::from_str(&data).map_err(|error| {
                                ApiError::Decode(format!("invalid chat completion: {error}"))
                            })?;
                        if !value.is_object() {
                            return Err(ApiError::Decode(
                                "chat completion requires an object".into(),
                            ));
                        }
                        return Ok(());
                    }
                    Some((event, data)) if event == "error" => {
                        let detail = serde_json::from_str::<serde_json::Value>(&data)
                            .ok()
                            .and_then(|v| {
                                v.get("message").and_then(|m| m.as_str()).map(String::from)
                            })
                            .unwrap_or(data);
                        return Err(ApiError::Server {
                            status: 502,
                            detail,
                        });
                    }
                    _ => {}
                }
            }
        }
        Err(ApiError::Decode(
            "chat stream ended before completion".into(),
        ))
    }

    /// Buffered variant of [`operator_converse_stream`] — drains the SSE
    /// to completion without surfacing deltas; the caller re-reads
    /// operator_conversation() to display the persisted turns.
    pub async fn operator_converse(&self, text: &str) -> Result<(), ApiError> {
        self.operator_converse_stream(text, |_| {}).await
    }

    /// `GET /api/device/attention` — the Inbox attention feed (D-002):
    /// canonical attention `groups` + the work_items-native `work_items`
    /// layer (needs-human/blocked/failing features + open bugs/changes).
    pub async fn attention(&self) -> Result<AttentionResp, ApiError> {
        self.request_json::<AttentionResp>(reqwest::Method::GET, "/api/device/attention", None)
            .await
    }

    /// `GET /api/device/plans?harness=&includeArchived=` — plan summaries.
    /// `harness=None`/`"all"` fans out across every pot ("All Pots").
    pub async fn plans_list(
        &self,
        harness: Option<&str>,
        include_archived: bool,
    ) -> Result<Vec<PlanSummary>, ApiError> {
        let mut path = String::from("/api/device/plans?");
        if let Some(h) = harness {
            path.push_str(&format!("harness={}&", urlencode(h)));
        }
        path.push_str(&format!("includeArchived={include_archived}"));
        self.request_json::<PlansResp>(reqwest::Method::GET, &path, None)
            .await
            .map(|r| r.plans)
    }

    /// `GET /api/device/plans/:slug?harness=` — one plan's full parsed
    /// structure (frontmatter + now + items + decisions).
    pub async fn plan_get(
        &self,
        slug: &str,
        harness: Option<&str>,
    ) -> Result<PlanDetail, ApiError> {
        let mut path = format!("/api/device/plans/{}", urlencode(slug));
        if let Some(h) = harness {
            path.push_str(&format!("?harness={}", urlencode(h)));
        }
        self.request_json::<PlanDetail>(reqwest::Method::GET, &path, None)
            .await
    }

    /// `POST /api/device/plans/:slug/items/:itemId/status` — flip a plan
    /// item's status (approve→done, nudge→wip, gate→needs-human). Returns
    /// the tool's raw result JSON.
    pub async fn plan_item_set_status(
        &self,
        slug: &str,
        item_id: &str,
        status: &str,
        note: Option<&str>,
        harness: Option<&str>,
    ) -> Result<serde_json::Value, ApiError> {
        let path = format!(
            "/api/device/plans/{}/items/{}/status",
            urlencode(slug),
            urlencode(item_id),
        );
        let body = serde_json::to_value(PlanItemStatusBody {
            status: status.to_string(),
            note: note.map(str::to_string),
            harness: harness.map(str::to_string),
        })
        .expect("PlanItemStatusBody serialises");
        self.request_json::<serde_json::Value>(reqwest::Method::POST, &path, Some(body))
            .await
    }

    /// `POST /api/device/push/register` — registers an FCM/APNS token.
    /// NOTE: the route is being rebuilt server-side (revival D-004);
    /// shape pinned to the rebuild's contract.
    pub async fn register_push(&self, body: PushRegisterBody) -> Result<(), ApiError> {
        let body = serde_json::to_value(body).expect("PushRegisterBody serialises");
        self.request_empty(
            reqwest::Method::POST,
            "/api/device/push/register",
            Some(body),
        )
        .await
    }

    /// `POST /api/device/pair` — exchanges a one-time pair token (from
    /// the desktop's QR code) for a long-lived device JWT. No bearer
    /// auth. The response's `defguard_enrollment_url` is the Defguard
    /// self-enrollment hand-off (D-005); no WG config at pair time.
    pub async fn pair(&self, body: PairBody) -> Result<PairResp, ApiError> {
        let url = format!("{}/api/device/pair", self.base_url());
        let resp = self.http.post(&url).json(&body).send().await?;
        if !resp.status().is_success() {
            return Err(into_api_error(resp).await);
        }
        resp.json::<PairResp>()
            .await
            .map_err(|e| ApiError::Decode(e.to_string()))
    }
}

/// Minimal query-value escape (RFC 3986 unreserved set passes through).
/// `rest_query` args are JSON, which needs this for `{`, `}`, `"` etc.
pub(crate) fn urlencode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}
