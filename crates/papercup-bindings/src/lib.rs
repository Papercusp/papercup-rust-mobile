// SPDX-License-Identifier: GPL-3.0-or-later
//
// UniFFI bindings layer. Re-exports `papercup-core` to Kotlin + Swift.

// uniffi::include_scaffolding! emits constants whose generated doc
// comments trip several clippy rules; quiet them at the crate level
// so our own code can still be -D warnings.
// large_const_arrays: the scaffolding's UNIFFI_META_CONST_UDL_PAPERCUP
// metadata buffer is a generated `const` array; newer clippy (1.99 on
// CI's floating stable) flags it once the UDL grows past the lint's
// size threshold. We cannot make generated code `static`.
#![allow(clippy::empty_line_after_doc_comments)]
#![allow(clippy::large_const_arrays)]

use papercup_core::client::{ApiError as CoreApiError, OperatorClient as CoreClient};
use papercup_core::types::{
    AttentionResp as CoreAttentionResp, AttentionSystemAlert as CoreAttentionSystemAlert,
    AttentionWorkItem as CoreAttentionWorkItem, AuditRow as CoreAudit, DeviceRow as CoreDevice,
    HarnessLite, HarnessStatusFull, PairBody, PauseInfo as CorePauseInfo,
    PlanSummary as CorePlanSummary, PushRegisterBody, RunningHarnessPhase as CoreRunning,
    RunningScan as CoreRunningScan, RuntimeConfig as CoreRuntimeConfig,
    StandingCandidate as CoreStandingCandidate, ToastRow as CoreToast,
    VoiceLeaseShape as CoreVoiceLease, VoiceSessionInit as CoreVoiceSessionInit,
    WorkspaceItem as CoreWorkspace, WorkspaceSwitchResp as CoreWorkspaceSwitch,
};
use papercup_core::voice::{
    voice_ws_url as core_voice_ws_url, VoiceClient as CoreVoice, VoiceError as CoreVoiceError,
    VoiceEvent as CoreVoiceEvent, VoiceStatus as CoreVoiceStatus,
};

uniffi::include_scaffolding!("papercup");

#[cfg(test)]
mod async_bridge_tests {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::{Duration, Instant};

    static READY_CALLBACKS: AtomicUsize = AtomicUsize::new(0);

    extern "C" fn repoll(data: u64, result: uniffi::RustFuturePoll) {
        if result == uniffi::RustFuturePoll::Ready {
            READY_CALLBACKS.fetch_add(1, Ordering::SeqCst);
        } else {
            // Match the inline Kotlin continuation observed in native1248.
            // This uses our actual generated FFI entry, not a mock scheduler.
            unsafe {
                super::ffi_papercup_rust_future_poll_u32(
                    uniffi::Handle::from_raw_unchecked(data),
                    repoll,
                    data,
                );
            }
        }
    }

    #[test]
    fn reentrant_polling_finishes() {
        const CHILD: &str = "PAPERCUP_UNIFFI_REENTRANT_CHILD";
        if std::env::var_os(CHILD).is_some() {
            let mut first = true;
            let future = std::future::poll_fn(move |cx| {
                if first {
                    first = false;
                    cx.waker().wake_by_ref();
                    std::task::Poll::Pending
                } else {
                    std::task::Poll::Ready(Ok(47_u32))
                }
            });
            let handle = uniffi::ffi::rust_future_new(future, super::UniFfiTag);
            unsafe {
                super::ffi_papercup_rust_future_poll_u32(handle.clone(), repoll, handle.as_raw());
                assert_eq!(READY_CALLBACKS.load(Ordering::SeqCst), 1);
                let mut status = uniffi::RustCallStatus::default();
                assert_eq!(
                    super::ffi_papercup_rust_future_complete_u32(handle.clone(), &mut status),
                    47
                );
                assert_eq!(status.code, uniffi::RustCallStatusCode::Success);
                super::ffi_papercup_rust_future_free_u32(handle);
            }
            return;
        }
        // A regressed native mutex must fail this test rather than hang CI.
        // Kill only this owned child; the test binary and its output are the
        // standard Cargo suite, including when the regression is present.
        let mut child = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "async_bridge_tests::reentrant_polling_finishes",
                "--nocapture",
            ])
            .env(CHILD, "1")
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            if let Some(status) = child.try_wait().unwrap() {
                assert!(
                    status.success(),
                    "generated UniFFI callback re-entry failed"
                );
                break;
            }
            if Instant::now() >= deadline {
                child.kill().unwrap();
                child.wait().unwrap();
                panic!("generated UniFFI callback re-entry deadlocked");
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

// ── free fns ────────────────────────────────────────────────────────────

fn version() -> String {
    papercup_core::version()
}

/// Build the voice WS URL from the API base URL + the
/// runtime-config-discovered port/path. The voice WS listens on its own
/// port (default :3068), NOT the API port.
fn voice_ws_url(base_url: String, port: u16, path: String) -> String {
    core_voice_ws_url(&base_url, port, &path)
}

fn parse_qr_payload(text: String) -> Result<QrPayload, PairError> {
    #[derive(serde::Deserialize)]
    struct Raw {
        server: String,
        #[serde(rename = "pairToken")]
        pair_token: String,
        #[serde(rename = "workspaceId")]
        workspace_id: String,
    }
    let raw: Raw = serde_json::from_str(text.trim()).map_err(|_| PairError::InvalidQr {
        detail: "JSON parse failed".into(),
    })?;
    if raw.server.is_empty() || raw.pair_token.is_empty() || raw.workspace_id.is_empty() {
        return Err(PairError::InvalidQr {
            detail: "JSON parse failed".into(),
        });
    }
    Ok(QrPayload {
        server: raw.server,
        pair_token: raw.pair_token,
        workspace_id: raw.workspace_id,
    })
}

// ── sync cache (Phase 3) ────────────────────────────────────────────────

#[derive(Clone)]
pub enum CacheUpdate {
    Updated {
        name: String,
        value_json: String,
        generation: i64,
    },
    Failed {
        name: String,
        error: String,
    },
}

impl From<papercup_core::cache::CacheUpdate> for CacheUpdate {
    fn from(u: papercup_core::cache::CacheUpdate) -> Self {
        match u {
            papercup_core::cache::CacheUpdate::Updated {
                name,
                value_json,
                generation,
            } => Self::Updated {
                name,
                value_json,
                generation: generation as i64,
            },
            papercup_core::cache::CacheUpdate::Failed { name, error } => {
                Self::Failed { name, error }
            }
        }
    }
}

pub trait CacheSubscriber: Send + Sync {
    fn on_update(&self, update: CacheUpdate);
}

/// Foreign listener for operator_converse_stream — receives each SSE
/// `delta` text fragment as the operator's reply streams in.
pub trait ConverseDelta: Send + Sync {
    fn on_delta(&self, text: String);
}

struct CacheSubShim(std::sync::Arc<dyn CacheSubscriber>);
impl papercup_core::cache::Subscriber for CacheSubShim {
    fn on_update(&self, u: papercup_core::cache::CacheUpdate) {
        self.0.on_update(u.into());
    }
}

/// Fetcher that maps query name → REST call on the wrapped client.
struct ClientFetcher {
    client: CoreClient,
}

#[async_trait::async_trait]
impl papercup_core::cache::Fetcher for ClientFetcher {
    async fn fetch(&self, name: &str) -> Result<String, String> {
        // Map sync-event names emitted by the desktop to the
        // mobile route that returns the freshest snapshot. Names
        // mirror the desktop's existing `name`-keyed invalidations.
        let result = match name {
            "harnesses.list" => self.client.list_harnesses().await.and_then(|v| {
                serde_json::to_string(&v)
                    .map_err(|e| papercup_core::client::ApiError::Decode(e.to_string()))
            }),
            "running" | "operatorScans.running" => self.client.list_running().await.and_then(|v| {
                serde_json::to_string(&v)
                    .map_err(|e| papercup_core::client::ApiError::Decode(e.to_string()))
            }),
            "toastLog.recent" | "notifications.recent" => {
                self.client.recent_notifications().await.and_then(|v| {
                    serde_json::to_string(&v)
                        .map_err(|e| papercup_core::client::ApiError::Decode(e.to_string()))
                })
            }
            "auditLog.recent" | "actions.recent" => {
                self.client.recent_actions().await.and_then(|v| {
                    serde_json::to_string(&v)
                        .map_err(|e| papercup_core::client::ApiError::Decode(e.to_string()))
                })
            }
            other if other.starts_with("harness.status:") => {
                let slug = other.trim_start_matches("harness.status:");
                self.client.get_harness_status(slug).await.and_then(|v| {
                    serde_json::to_string(&v)
                        .map_err(|e| papercup_core::client::ApiError::Decode(e.to_string()))
                })
            }
            _ => return Err(format!("unmapped query name: {name}")),
        };
        result.map_err(|e| format!("{e}"))
    }
}

pub struct SyncCache {
    inner: papercup_core::cache::Cache,
    /// Held across the lifetime of the cache to keep registered
    /// subscribers alive.
    _subs: std::sync::Mutex<Vec<papercup_core::cache::Subscription>>,
    /// Names the host has registered. Cache::handle_invalidate
    /// already gates on cache contents, but we also track here so
    /// register_query can pre-populate by triggering a first refresh.
    registered: std::sync::Mutex<std::collections::HashSet<String>>,
}

impl SyncCache {
    pub fn new(client: std::sync::Arc<OperatorClient>) -> Self {
        let fetcher = std::sync::Arc::new(ClientFetcher {
            client: client.inner.clone(),
        });
        Self {
            inner: papercup_core::cache::Cache::new(fetcher),
            _subs: std::sync::Mutex::new(Vec::new()),
            registered: std::sync::Mutex::new(std::collections::HashSet::new()),
        }
    }

    pub fn register_query(&self, name: String) {
        let mut reg = self.registered.lock().unwrap();
        if reg.insert(name.clone()) {
            // Make the name visible to the polling loop immediately,
            // then kick off a first fetch so the cache has a value when
            // the UI first observes it.
            self.inner.register(&name);
            let inner = self.inner.clone();
            let n = name.clone();
            rt().spawn(async move {
                inner.refresh(&n).await;
            });
        }
    }

    pub async fn handle_invalidate(&self, name: String) {
        // Non-registered → no-op (per cache contract).
        let known = self.registered.lock().unwrap().contains(&name);
        if known {
            self.inner.refresh(&name).await;
        }
    }

    /// Start the rest-query polling loop (the SSE stream's replacement —
    /// mobile-apps-revival D-001.1). Subscribers are notified only when a
    /// payload actually changes. Idempotent; restart replaces the loop.
    pub fn start_polling(&self, interval_ms: u64) {
        let _g = rt().enter();
        self.inner
            .start_polling(std::time::Duration::from_millis(interval_ms.max(500)));
    }

    /// Stop the polling loop (e.g. when the app backgrounds).
    pub fn stop_polling(&self) {
        self.inner.stop_polling();
    }

    pub fn subscribe(&self, subscriber: Box<dyn CacheSubscriber>) {
        let arc: std::sync::Arc<dyn CacheSubscriber> = std::sync::Arc::from(subscriber);
        let sub = std::sync::Arc::new(CacheSubShim(arc));
        // core::cache::Cache::subscribe spawns a tokio task. Kotlin/Swift
        // call this from a synchronous Composable / SwiftUI lifecycle
        // callback where no tokio runtime is active; enter our owned
        // runtime so tokio::spawn finds it.
        let _guard = rt().enter();
        let subscription = self.inner.subscribe(sub);
        self._subs.lock().unwrap().push(subscription);
    }

    pub fn get(&self, name: String) -> Option<String> {
        self.inner.get(&name).and_then(|e| e.value_json)
    }
}

// ── voice intent dispatch (Phase 4) ─────────────────────────────────────

pub enum Intent {
    Navigate { slug: String, speak: String },
    Pause { speak: String },
    Resume { speak: String },
    ClaimVoice { speak: String },
    Speak { text: String },
}

impl From<papercup_core::intent::Intent> for Intent {
    fn from(i: papercup_core::intent::Intent) -> Self {
        match i {
            papercup_core::intent::Intent::Navigate { slug, speak } => {
                Self::Navigate { slug, speak }
            }
            papercup_core::intent::Intent::Pause { speak } => Self::Pause { speak },
            papercup_core::intent::Intent::Resume { speak } => Self::Resume { speak },
            papercup_core::intent::Intent::ClaimVoice { speak } => Self::ClaimVoice { speak },
            papercup_core::intent::Intent::Speak { text } => Self::Speak { text },
        }
    }
}

fn parse_intent(text: String) -> Intent {
    papercup_core::intent::parse(&text).into()
}

#[cfg(test)]
mod boundary_smoke {
    use super::*;

    /// Exercise the same free-function surface that generated Kotlin and Swift
    /// call, without needing a device or live operator endpoint.
    #[test]
    fn host_boundary_smoke_passes() {
        assert!(!version().is_empty());

        let qr = parse_qr_payload(
            r#"{"server":"https://operator.example.test","pairToken":"pair-smoke","workspaceId":"workspace-smoke"}"#.into(),
        )
        .expect("valid QR payload crosses the UniFFI surface");
        assert_eq!(qr.workspace_id, "workspace-smoke");

        assert_eq!(
            voice_ws_url(
                "https://operator.example.test/api".into(),
                3068,
                "/voice".into(),
            ),
            "wss://operator.example.test:3068/voice",
        );
        assert!(matches!(
            parse_intent("[PAUSE]".into()),
            Intent::Pause { .. }
        ));
        assert!(parse_qr_payload("not-json".into()).is_err());
    }
}

// ── error mapping ───────────────────────────────────────────────────────

#[derive(Debug, thiserror::Error)]
pub enum ApiError {
    #[error("network: {detail}")]
    Network { detail: String },
    #[error("server returned {status}: {detail}")]
    Server { status: u16, detail: String },
    #[error("decode: {detail}")]
    Decode { detail: String },
    #[error("unauthorized — re-pair the device")]
    Unauthorized,
}

impl From<CoreApiError> for ApiError {
    fn from(e: CoreApiError) -> Self {
        match e {
            CoreApiError::Network(detail) => ApiError::Network { detail },
            CoreApiError::Server { status, detail } => ApiError::Server { status, detail },
            CoreApiError::Decode(detail) => ApiError::Decode { detail },
            CoreApiError::Unauthorized => ApiError::Unauthorized,
            other => {
                let (status, detail) = cloud_error_as_server(&other);
                ApiError::Server { status, detail }
            }
        }
    }
}

/// Cloud-relay errors (D-013) surface over the current UDL as `Server`
/// with a stable `code` prefix in `detail`, and NEVER as `Unauthorized`
/// (which forces a re-pair). Dedicated UDL variants are a follow-up
/// coordinated with the iPhone lane (D-010).
fn cloud_error_as_server(e: &CoreApiError) -> (u16, String) {
    let retry = |s: &Option<u32>| s.map(|n| format!(" retry_after={n}")).unwrap_or_default();
    match e {
        CoreApiError::WorkspaceOffline { retry_after_secs } => {
            (503, format!("workspace_offline{}", retry(retry_after_secs)))
        }
        CoreApiError::RelayRefused { status, code } => (*status, format!("relay_refused: {code}")),
        CoreApiError::PayloadTooLarge { detail } => {
            (413, format!("request_body_too_large: {detail}"))
        }
        CoreApiError::RateLimited { retry_after_secs } => {
            (429, format!("rate_limited{}", retry(retry_after_secs)))
        }
        other => (0, other.to_string()),
    }
}

#[derive(Debug, thiserror::Error)]
pub enum PairError {
    #[error("QR payload malformed: {detail}")]
    InvalidQr { detail: String },
    #[error("network: {detail}")]
    Network { detail: String },
    #[error("server returned {status}: {detail}")]
    Server { status: u16, detail: String },
    #[error("decode: {detail}")]
    Decode { detail: String },
    #[error("pair token invalid or expired: {detail}")]
    Unauthorized { detail: String },
}

impl From<CoreApiError> for PairError {
    fn from(e: CoreApiError) -> Self {
        match e {
            CoreApiError::Network(detail) => PairError::Network { detail },
            CoreApiError::Server { status, detail } => PairError::Server { status, detail },
            CoreApiError::Decode(detail) => PairError::Decode { detail },
            CoreApiError::Unauthorized => PairError::Unauthorized {
                detail: "pair token rejected by server".into(),
            },
            other => {
                let (status, detail) = cloud_error_as_server(&other);
                PairError::Server { status, detail }
            }
        }
    }
}

// ── DTOs ────────────────────────────────────────────────────────────────

pub struct Harness {
    pub slug: String,
    pub path: String,
    pub has_state: bool,
    pub harness_kind: Option<String>,
    pub iteration: Option<i64>,
    pub last_active_ts: Option<i64>,
    pub status: Option<String>,
}

impl From<HarnessLite> for Harness {
    fn from(h: HarnessLite) -> Self {
        Self {
            slug: h.slug,
            path: h.path,
            has_state: h.has_state,
            harness_kind: h.harness_kind,
            iteration: h.iteration,
            last_active_ts: h.last_active_ts,
            status: h.status,
        }
    }
}

pub struct HarnessStatus {
    pub slug: String,
    pub path: String,
    pub iteration: i64,
    pub alive: bool,
    pub escalated: bool,
    pub smoke_fail: bool,
    pub pending_checkpoints: i64,
    pub active_competitions: i64,
    pub mission_cost_usd: f64,
    pub mission_input_tokens: i64,
    pub mission_output_tokens: i64,
    pub last_decision: Option<String>,
    pub counts: std::collections::HashMap<String, i64>,
    pub feature_count: i64,
}

impl From<HarnessStatusFull> for HarnessStatus {
    fn from(h: HarnessStatusFull) -> Self {
        let feature_count = h.counts.values().sum();
        Self {
            slug: h.project.slug,
            path: h.project.path,
            iteration: h.iteration,
            alive: h.alive,
            escalated: h.escalated,
            smoke_fail: h.smoke_fail,
            pending_checkpoints: h.pending_checkpoints,
            active_competitions: h.active_competitions,
            mission_cost_usd: h.mission_cost_usd,
            mission_input_tokens: h.mission_input_tokens,
            mission_output_tokens: h.mission_output_tokens,
            last_decision: h.last_decision,
            counts: h.counts,
            feature_count,
        }
    }
}

pub struct QrPayload {
    pub server: String,
    pub pair_token: String,
    pub workspace_id: String,
}

pub struct PairOutcome {
    pub device_token: String,
    pub device_id: String,
    pub workspace_id: String,
    pub desktop_host: String,
    /// Defguard self-enrollment URL (D-005) — open/hand off at pair time
    /// so the device joins the mesh. None when the server has no Defguard
    /// configured (LAN/public-tunnel reachability still works).
    pub defguard_enrollment_url: Option<String>,
    /// Advertised routes as opaque JSON (`"null"` from an older server).
    pub base_urls_json: String,
}

/// `GET /api/device/runtime-config` — post-pair device config. The voice
/// WS port is the load-bearing field: the WS does NOT share the API port.
/// `voice_ws_port == None` → the server's voice WS failed to bind →
/// show "voice unavailable" instead of dialing a dead port.
pub struct RuntimeConfig {
    pub mesh_host: String,
    pub workspace_id: String,
    pub device_kind: String,
    pub voice_ws_port: Option<u16>,
    pub voice_ws_path: String,
    pub base_urls_json: String,
}

impl From<CoreRuntimeConfig> for RuntimeConfig {
    fn from(c: CoreRuntimeConfig) -> Self {
        Self {
            mesh_host: c.mesh_host,
            workspace_id: c.workspace_id,
            device_kind: c.device_kind,
            voice_ws_port: c.voice_ws.port,
            voice_ws_path: c.voice_ws.path,
            base_urls_json: routes_json(&c.base_urls),
        }
    }
}

/// `GET /api/device/voice-session-init` — the selected mobile voice
/// transport. Hosted ElevenLabs fields remain intact; desktop-local mode
/// adds its streaming routes and ordered transport candidates.
pub struct VoiceSessionInit {
    pub mode: String,
    pub conversation_token: String,
    pub agent_id: String,
    pub idle_timeout_min: f64,
    pub session_max_min: f64,
    pub voice_mode: String,
    pub dynamic_variables_json: String,
    pub turn_path: Option<String>,
    pub warmup_path: Option<String>,
    pub audience_mode: Option<String>,
    pub device_id: Option<String>,
    pub workspace_id: Option<String>,
    pub base_urls_json: String,
}

impl From<CoreVoiceSessionInit> for VoiceSessionInit {
    fn from(v: CoreVoiceSessionInit) -> Self {
        Self {
            mode: v.mode,
            conversation_token: v.conversation_token,
            agent_id: v.agent_id,
            idle_timeout_min: v.idle_timeout_min,
            session_max_min: v.session_max_min,
            voice_mode: v.voice_mode,
            dynamic_variables_json: v.dynamic_variables.to_string(),
            turn_path: v.turn_path,
            warmup_path: v.warmup_path,
            audience_mode: v.audience_mode,
            device_id: v.device_id,
            workspace_id: v.workspace_id,
            base_urls_json: routes_json(&v.base_urls),
        }
    }
}

pub struct Toast {
    pub id: i64,
    pub level: String,
    pub message: String,
    pub created_at: i64,
    pub description: Option<String>,
    pub harness_slug: Option<String>,
    pub action_href: Option<String>,
    pub action_label: Option<String>,
}

impl From<CoreToast> for Toast {
    fn from(t: CoreToast) -> Self {
        Self {
            id: t.id,
            level: t.level,
            message: t.message,
            created_at: t.created_at,
            description: t.description,
            harness_slug: t.harness_slug,
            action_href: t.action_href,
            action_label: t.action_label,
        }
    }
}

pub struct AuditEntry {
    pub id: String,
    pub ts: i64,
    pub actor: String,
    pub action: String,
    pub subject: String,
    pub details_json: String,
}

impl From<CoreAudit> for AuditEntry {
    fn from(a: CoreAudit) -> Self {
        Self {
            id: a.id,
            ts: a.ts,
            actor: a.actor,
            action: a.action,
            subject: a.subject,
            details_json: a.details.to_string(),
        }
    }
}

pub struct PauseInfo {
    pub paused: bool,
    pub at: Option<String>,
    pub by: Option<String>,
}

pub struct VoiceLease {
    pub workspace_id: String,
    pub owner_id: String,
    pub owner_kind: String,
    pub expires_at_ms: i64,
}

impl From<CoreVoiceLease> for VoiceLease {
    fn from(v: CoreVoiceLease) -> Self {
        Self {
            workspace_id: v.workspace_id,
            owner_id: v.owner_id,
            owner_kind: v.owner_kind,
            expires_at_ms: v.expires_at_ms,
        }
    }
}

pub struct RunningScan {
    pub id: i64,
    pub started_at: i64,
    pub request_text: Option<String>,
    pub cost_usd: f64,
}

impl From<CoreRunningScan> for RunningScan {
    fn from(scan: CoreRunningScan) -> Self {
        Self {
            id: scan.id,
            started_at: scan.started_at,
            request_text: scan.request_text,
            cost_usd: scan.cost_usd,
        }
    }
}

pub struct RunningSnapshot {
    pub scan: Option<RunningScan>,
    pub harnesses: Vec<Running>,
}

pub struct Running {
    pub harness_slug: String,
    pub phase: String,
    pub status: String,
    pub iteration: i32,
    pub total_features: i32,
    pub passed_count: i32,
    pub todo_count: i32,
    pub blocked_count: i32,
    pub active_roles: Vec<String>,
    pub last_active_ts: Option<i64>,
}

impl From<CoreRunning> for Running {
    fn from(r: CoreRunning) -> Self {
        Self {
            harness_slug: r.harness_slug,
            phase: r.phase,
            status: r.status,
            iteration: r.iteration,
            total_features: r.total_features,
            passed_count: r.passed_count,
            todo_count: r.todo_count,
            blocked_count: r.blocked_count,
            active_roles: r.active_roles,
            last_active_ts: r.last_active_ts,
        }
    }
}

impl From<CorePauseInfo> for PauseInfo {
    fn from(p: CorePauseInfo) -> Self {
        Self {
            paused: p.paused,
            at: p.at,
            by: p.by,
        }
    }
}

pub struct Workspace {
    pub id: String,
    pub name: String,
    pub current: bool,
    pub last_activity_at: Option<i64>,
}

impl From<CoreWorkspace> for Workspace {
    fn from(w: CoreWorkspace) -> Self {
        Self {
            id: w.id,
            name: w.name,
            current: w.current,
            last_activity_at: w.last_activity_at,
        }
    }
}

pub struct WorkspaceSwitchResult {
    pub device_token: String,
    pub workspace_id: String,
}

impl From<CoreWorkspaceSwitch> for WorkspaceSwitchResult {
    fn from(r: CoreWorkspaceSwitch) -> Self {
        Self {
            device_token: r.device_token,
            workspace_id: r.workspace_id,
        }
    }
}

pub struct Device {
    pub device_id: String,
    pub workspace_id: String,
    pub device_label: Option<String>,
    pub last_seen: Option<String>,
    pub paired_at: Option<String>,
}

impl From<CoreDevice> for Device {
    fn from(d: CoreDevice) -> Self {
        Self {
            device_id: d.device_id,
            workspace_id: d.workspace_id,
            device_label: d.device_label,
            last_seen: d.last_seen,
            paired_at: d.paired_at,
        }
    }
}

pub struct StandingCandidate {
    pub capability: String,
    pub target_harness: String,
    pub count: i64,
    pub last_seen_at: String,
    pub first_shown_at: Option<String>,
}

impl From<CoreStandingCandidate> for StandingCandidate {
    fn from(c: CoreStandingCandidate) -> Self {
        Self {
            capability: c.capability,
            target_harness: c.target_harness,
            count: c.count,
            last_seen_at: c.last_seen_at,
            first_shown_at: c.first_shown_at,
        }
    }
}

// ── attention (Inbox) + plans (D-002) ────────────────────────────────────

/// The Inbox attention feed. `groups_json` is the opaque attention-group
/// payload (rendered generically by the UI); `work_items` is the decoded
/// work_items-native layer (the actionable list).
pub struct AttentionFeed {
    pub groups_json: String,
    pub work_items: Vec<AttentionWorkItem>,
    pub system_alerts: Vec<AttentionSystemAlert>,
    pub group_count: i64,
    pub work_item_count: i64,
}

pub struct FleetActivitySummary {
    pub agents: u64,
    pub available_agents: u64,
    pub fleets: Vec<FleetActivityRow>,
    pub pots: Vec<PotActivityRow>,
}

pub struct FleetActivityRow {
    pub slug: String,
    pub members: u64,
    pub available_agents: u64,
    pub leader: Option<String>,
}

pub struct PotActivityRow {
    pub slug: String,
    pub agents: u64,
    pub available_agents: u64,
}

pub struct AttentionSystemAlert {
    pub id: String,
    pub kind: String,
    pub severity: String,
    pub title: String,
    pub body: String,
}

impl From<CoreAttentionSystemAlert> for AttentionSystemAlert {
    fn from(alert: CoreAttentionSystemAlert) -> Self {
        Self {
            id: alert.id,
            kind: alert.kind,
            severity: alert.severity,
            title: alert.title,
            body: alert.body,
        }
    }
}

impl From<CoreAttentionResp> for AttentionFeed {
    fn from(resp: CoreAttentionResp) -> Self {
        Self {
            groups_json: resp.groups.to_string(),
            group_count: resp.counts.groups,
            work_item_count: resp.counts.work_items,
            work_items: resp
                .work_items
                .into_iter()
                .map(AttentionWorkItem::from)
                .collect(),
            system_alerts: resp
                .system_alerts
                .into_iter()
                .map(AttentionSystemAlert::from)
                .collect(),
        }
    }
}

#[cfg(test)]
mod attention_feed_tests {
    use super::{AttentionFeed, CoreAttentionResp};
    use serde_json::json;

    #[test]
    fn system_alert_only_response_survives_the_native_boundary() {
        let response: CoreAttentionResp = serde_json::from_value(json!({
            "groups": [], "workItems": [],
            "systemAlerts": [{
                "id": "system:release-red-gate", "kind": "release-red-gate",
                "severity": "high", "title": "Release gate is red",
                "body": "Changes cannot reach production."
            }],
            "counts": {"groups": 0, "workItems": 0, "systemAlerts": 1}
        }))
        .unwrap();
        let feed = AttentionFeed::from(response);
        assert_eq!(feed.groups_json, "[]");
        assert!(feed.work_items.is_empty());
        assert_eq!(feed.system_alerts.len(), 1);
        let alert = &feed.system_alerts[0];
        assert_eq!(alert.id, "system:release-red-gate");
        assert_eq!(alert.kind, "release-red-gate");
        assert_eq!(alert.severity, "high");
        assert_eq!(alert.title, "Release gate is red");
        assert_eq!(alert.body, "Changes cannot reach production.");
    }

    #[test]
    fn legacy_attention_response_remains_compatible() {
        let response: CoreAttentionResp = serde_json::from_value(json!({
            "groups": [], "workItems": [], "counts": {"groups": 0, "workItems": 0}
        }))
        .unwrap();
        assert!(AttentionFeed::from(response).system_alerts.is_empty());
    }
}

pub struct AttentionWorkItem {
    pub id: String,
    pub kind: String,
    pub family: String,
    pub harness: Option<String>,
    pub title: String,
    pub summary: String,
    pub state: String,
    pub assignee: Option<String>,
    pub assigned_by: Option<String>,
    pub severity: Option<String>,
    pub parent: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

impl From<CoreAttentionWorkItem> for AttentionWorkItem {
    fn from(w: CoreAttentionWorkItem) -> Self {
        Self {
            id: w.id,
            kind: w.kind,
            family: w.family,
            harness: w.harness,
            title: w.title,
            summary: w.summary,
            state: w.state,
            assignee: w.assignee,
            assigned_by: w.assigned_by,
            severity: w.severity,
            parent: w.parent,
            created_at: w.created_at,
            updated_at: w.updated_at,
        }
    }
}

/// One plan card for the Plans list. `item_counts` is status→count.
pub struct PlanSummary {
    pub slug: String,
    pub harness: String,
    pub title: String,
    pub status: Option<String>,
    pub updated: Option<String>,
    pub owner: Option<String>,
    pub archived: bool,
    pub item_counts: std::collections::HashMap<String, i64>,
    pub now_state: Option<String>,
    pub now_next: Option<String>,
}

impl From<CorePlanSummary> for PlanSummary {
    fn from(p: CorePlanSummary) -> Self {
        Self {
            slug: p.slug,
            harness: p.harness,
            title: p.title,
            status: p.status,
            updated: p.updated,
            owner: p.owner,
            archived: p.archived,
            item_counts: p.item_counts,
            now_state: p.now_state,
            now_next: p.now_next,
        }
    }
}

/// One plan's full detail. The parser-shaped sections (frontmatter / now /
/// items / decisions) are passed through as JSON strings — the UI decodes
/// what it renders without this layer tracking the parser's evolution.
pub struct PlanDetail {
    pub slug: String,
    pub harness: String,
    pub archived: bool,
    pub title: String,
    pub status: Option<String>,
    pub owner: Option<String>,
    pub frontmatter_json: String,
    pub now_json: String,
    pub items_json: String,
    pub decisions_json: String,
}

impl From<papercup_core::types::PlanDetail> for PlanDetail {
    fn from(d: papercup_core::types::PlanDetail) -> Self {
        Self {
            slug: d.slug,
            harness: d.harness,
            archived: d.archived,
            title: d.title,
            status: d.status,
            owner: d.owner,
            frontmatter_json: d.frontmatter.to_string(),
            now_json: d.now.to_string(),
            items_json: d.items.to_string(),
            decisions_json: d.decisions.to_string(),
        }
    }
}

// ── operator conversation (chat, D-002) ──────────────────────────────────

pub struct ConversationRead {
    pub conversation_id: String,
    pub status: String,
    pub turns: Vec<OperatorTurn>,
    pub has_more_earlier: bool,
}

pub struct OperatorTurn {
    pub id: String,
    pub seq: i64,
    /// "user" | "assistant" | "system".
    pub role: String,
    pub text: String,
    pub source: String,
    pub created_at: i64,
    /// Tool-call entries as JSON (chat:ask_choice cards, etc.), or "null".
    pub tools_json: String,
}

impl From<papercup_core::types::OperatorTurn> for OperatorTurn {
    fn from(t: papercup_core::types::OperatorTurn) -> Self {
        Self {
            id: t.id,
            seq: t.seq,
            role: t.role,
            text: t.text,
            source: t.source,
            created_at: t.created_at,
            tools_json: t.tools.to_string(),
        }
    }
}

// ── voice ────────────────────────────────────────────────────────────────

#[derive(Debug, thiserror::Error)]
pub enum VoiceError {
    #[error("connect failed")]
    Connect,
    #[error("stream closed")]
    Closed,
}

impl From<CoreVoiceError> for VoiceError {
    fn from(e: CoreVoiceError) -> Self {
        match e {
            CoreVoiceError::Connect(_) => VoiceError::Connect,
            CoreVoiceError::Closed => VoiceError::Closed,
        }
    }
}

pub enum VoiceStatus {
    Idle,
    Connecting,
    Listening,
    Speaking,
    Paused,
}

impl From<VoiceStatus> for CoreVoiceStatus {
    fn from(s: VoiceStatus) -> Self {
        match s {
            VoiceStatus::Idle => CoreVoiceStatus::Idle,
            VoiceStatus::Connecting => CoreVoiceStatus::Connecting,
            VoiceStatus::Listening => CoreVoiceStatus::Listening,
            VoiceStatus::Speaking => CoreVoiceStatus::Speaking,
            VoiceStatus::Paused => CoreVoiceStatus::Paused,
        }
    }
}

pub enum VoiceEvent {
    Connected,
    Speak {
        text: String,
        source: String,
        agent_id: Option<String>,
        format: Option<String>,
    },
    Closed {
        code: u16,
        reason: String,
    },
}

impl From<CoreVoiceEvent> for VoiceEvent {
    fn from(e: CoreVoiceEvent) -> Self {
        match e {
            CoreVoiceEvent::Connected => VoiceEvent::Connected,
            CoreVoiceEvent::Speak {
                text,
                source,
                agent_id,
                format,
            } => VoiceEvent::Speak {
                text,
                source,
                agent_id,
                format,
            },
            CoreVoiceEvent::Closed { code, reason } => VoiceEvent::Closed { code, reason },
        }
    }
}

pub struct VoiceClient {
    inner: CoreVoice,
}

impl VoiceClient {
    /// `ws_url` is the FULL voice WS URL — build it with `voice_ws_url`
    /// from the runtime-config's discovered port + path.
    pub fn new(ws_url: String, device_token: String, wake_word: Option<String>) -> Self {
        let _g = rt().enter();
        Self {
            inner: CoreVoice::connect(&ws_url, &device_token, wake_word.as_deref()),
        }
    }

    pub async fn next_event(&self) -> Result<VoiceEvent, VoiceError> {
        let ev = self.inner.next_event().await?;
        Ok(ev.into())
    }

    pub async fn send_status(&self, status: VoiceStatus) {
        self.inner.send_status(status.into()).await;
    }

    pub async fn send_transcript(&self, text: String) {
        self.inner.send_transcript(text).await;
    }

    pub async fn send_hello(&self, wake_word: String) {
        self.inner.send_hello(wake_word).await;
    }

    pub fn disconnect(&self) {
        self.inner.close();
    }
}

// ── OperatorClient ──────────────────────────────────────────────────────

fn rt() -> &'static tokio::runtime::Runtime {
    use std::sync::OnceLock;
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .worker_threads(2)
            .thread_name("papercup-core-rt")
            .build()
            .expect("tokio runtime")
    })
}

pub struct OperatorClient {
    inner: CoreClient,
    biometric: std::sync::Arc<
        std::sync::RwLock<Option<std::sync::Arc<dyn papercup_core::biometric::BiometricPrompt>>>,
    >,
}

/// UDL-declared types re-exported.
#[derive(Clone)]
pub enum BiometricResult {
    Approved,
    Denied,
    Unavailable { reason: String },
}

#[derive(Clone, Copy)]
pub enum RiskLevel {
    Low,
    Medium,
    High,
}

impl From<RiskLevel> for papercup_core::biometric::RiskLevel {
    fn from(r: RiskLevel) -> Self {
        match r {
            RiskLevel::Low => Self::Low,
            RiskLevel::Medium => Self::Medium,
            RiskLevel::High => Self::High,
        }
    }
}

/// Trait that UDL `callback interface BiometricPrompt` lowers to.
/// The platform shell implements this in Kotlin/Swift; we receive an
/// Arc<dyn BiometricPrompt> from set_biometric_prompt below.
pub trait BiometricPrompt: Send + Sync {
    fn prompt(&self, reason: String) -> BiometricResult;
}

/// Wraps the UDL callback (delivered as Box<dyn>) into an Arc so the
/// core::biometric trait can hold it across .await points.
struct PromptShim(std::sync::Arc<dyn BiometricPrompt>);

impl From<Box<dyn BiometricPrompt>> for PromptShim {
    fn from(b: Box<dyn BiometricPrompt>) -> Self {
        Self(std::sync::Arc::from(b))
    }
}
#[async_trait::async_trait]
impl papercup_core::biometric::BiometricPrompt for PromptShim {
    async fn prompt(&self, reason: String) -> papercup_core::biometric::BiometricResult {
        match self.0.prompt(reason) {
            BiometricResult::Approved => papercup_core::biometric::BiometricResult::Approved,
            BiometricResult::Denied => papercup_core::biometric::BiometricResult::Denied,
            BiometricResult::Unavailable { reason } => {
                papercup_core::biometric::BiometricResult::Unavailable(reason)
            }
        }
    }
}

impl OperatorClient {
    pub fn new(base_url: String, device_token: Option<String>) -> Self {
        Self {
            inner: CoreClient::new(base_url, device_token),
            biometric: std::sync::Arc::new(std::sync::RwLock::new(None)),
        }
    }

    /// Phase 6c — auto-fallback constructor. Primary URL preferred;
    /// transport failures swap to fallback for the rest of the session.
    pub fn new_with_fallback(
        primary: String,
        fallback: String,
        device_token: Option<String>,
    ) -> Self {
        Self {
            inner: CoreClient::new_with_fallback(primary, fallback, device_token),
            biometric: std::sync::Arc::new(std::sync::RwLock::new(None)),
        }
    }

    /// Phase 8 — set the platform-supplied biometric prompt. Pass None
    /// to disable gating (high-risk actions will deny).
    /// UDL `callback interface` lowers to Box<dyn>; we wrap into Arc.
    pub fn set_biometric_prompt(&self, prompt: Option<Box<dyn BiometricPrompt>>) {
        let mut w = self.biometric.write().unwrap();
        *w = prompt.map(|p| {
            let shim: std::sync::Arc<dyn papercup_core::biometric::BiometricPrompt> =
                std::sync::Arc::new(PromptShim::from(p));
            shim
        });
    }

    fn current_prompt(
        &self,
    ) -> Option<std::sync::Arc<dyn papercup_core::biometric::BiometricPrompt>> {
        self.biometric.read().unwrap().clone()
    }

    pub async fn list_harnesses(&self) -> Result<Vec<Harness>, ApiError> {
        let core = self.inner.clone();
        let result = rt()
            .spawn(async move { core.list_harnesses().await })
            .await
            .map_err(|_| ApiError::Network {
                detail: "tokio join".into(),
            })??;
        Ok(result.into_iter().map(Harness::from).collect())
    }

    pub async fn get_harness_status(&self, slug: String) -> Result<HarnessStatus, ApiError> {
        let core = self.inner.clone();
        let resp = rt()
            .spawn(async move { core.get_harness_status(&slug).await })
            .await
            .map_err(|_| ApiError::Network {
                detail: "tokio join".into(),
            })??;
        Ok(resp.into())
    }

    pub async fn register_push(&self, platform: String, token: String) -> Result<(), ApiError> {
        let core = self.inner.clone();
        rt().spawn(async move {
            core.register_push(PushRegisterBody { platform, token })
                .await
        })
        .await
        .map_err(|_| ApiError::Network {
            detail: "tokio join".into(),
        })??;
        Ok(())
    }

    pub async fn heartbeat(&self) -> Result<(), ApiError> {
        let core = self.inner.clone();
        rt().spawn(async move { core.heartbeat().await })
            .await
            .map_err(|_| ApiError::Network {
                detail: "tokio join".into(),
            })??;
        Ok(())
    }

    pub async fn pause_get(&self) -> Result<PauseInfo, ApiError> {
        let core = self.inner.clone();
        let p = rt()
            .spawn(async move { core.pause_get().await })
            .await
            .map_err(|_| ApiError::Network {
                detail: "tokio join".into(),
            })??;
        Ok(p.into())
    }

    pub async fn pause_set(&self, paused: bool) -> Result<bool, ApiError> {
        let core = self.inner.clone();
        let p = rt()
            .spawn(async move { core.pause_set(paused).await })
            .await
            .map_err(|_| ApiError::Network {
                detail: "tokio join".into(),
            })??;
        Ok(p)
    }

    pub async fn voice_lease_claim(&self) -> Result<(), ApiError> {
        let core = self.inner.clone();
        rt().spawn(async move { core.voice_lease_claim().await })
            .await
            .map_err(|_| ApiError::Network {
                detail: "tokio join".into(),
            })??;
        Ok(())
    }

    pub async fn voice_lease_heartbeat(&self) -> Result<(), ApiError> {
        let core = self.inner.clone();
        rt().spawn(async move { core.voice_lease_heartbeat().await })
            .await
            .map_err(|_| ApiError::Network {
                detail: "tokio join".into(),
            })??;
        Ok(())
    }

    pub async fn voice_lease_release(&self) -> Result<(), ApiError> {
        let core = self.inner.clone();
        rt().spawn(async move { core.voice_lease_release().await })
            .await
            .map_err(|_| ApiError::Network {
                detail: "tokio join".into(),
            })??;
        Ok(())
    }

    pub async fn voice_lease_get(&self) -> Result<Option<VoiceLease>, ApiError> {
        let core = self.inner.clone();
        let result = rt()
            .spawn(async move { core.voice_lease_get().await })
            .await
            .map_err(|_| ApiError::Network {
                detail: "tokio join".into(),
            })??;
        Ok(result.map(VoiceLease::from))
    }

    pub async fn list_running(&self) -> Result<Vec<Running>, ApiError> {
        let core = self.inner.clone();
        let result = rt()
            .spawn(async move { core.list_running().await })
            .await
            .map_err(|_| ApiError::Network {
                detail: "tokio join".into(),
            })??;
        Ok(result.into_iter().map(Running::from).collect())
    }

    pub async fn running_snapshot(&self) -> Result<RunningSnapshot, ApiError> {
        let core = self.inner.clone();
        let result = rt()
            .spawn(async move { core.running_snapshot().await })
            .await
            .map_err(|_| ApiError::Network {
                detail: "tokio join".into(),
            })??;
        Ok(RunningSnapshot {
            scan: result.0.map(RunningScan::from),
            harnesses: result.1.into_iter().map(Running::from).collect(),
        })
    }

    pub async fn recent_notifications(&self) -> Result<Vec<Toast>, ApiError> {
        let core = self.inner.clone();
        let result = rt()
            .spawn(async move { core.recent_notifications().await })
            .await
            .map_err(|_| ApiError::Network {
                detail: "tokio join".into(),
            })??;
        Ok(result.into_iter().map(Toast::from).collect())
    }

    pub async fn recent_actions(&self) -> Result<Vec<AuditEntry>, ApiError> {
        let core = self.inner.clone();
        let result = rt()
            .spawn(async move { core.recent_actions().await })
            .await
            .map_err(|_| ApiError::Network {
                detail: "tokio join".into(),
            })??;
        Ok(result.into_iter().map(AuditEntry::from).collect())
    }

    pub async fn list_workspaces(&self) -> Result<Vec<Workspace>, ApiError> {
        let core = self.inner.clone();
        let result = rt()
            .spawn(async move { core.list_workspaces().await })
            .await
            .map_err(|_| ApiError::Network {
                detail: "tokio join".into(),
            })??;
        Ok(result.into_iter().map(Workspace::from).collect())
    }

    pub async fn workspace_switch(
        &self,
        workspace_id: String,
    ) -> Result<WorkspaceSwitchResult, ApiError> {
        let core = self.inner.clone();
        let prompt = self.current_prompt();
        let ws_for_reason = workspace_id.clone();
        let gated = papercup_core::biometric::gate(
            prompt,
            papercup_core::biometric::RiskLevel::Medium,
            &format!("Switch to workspace {ws_for_reason}"),
            || async {
                let r = rt()
                    .spawn(async move { core.workspace_switch(&workspace_id).await })
                    .await;
                match r {
                    Ok(Ok(v)) => Ok(v),
                    Ok(Err(e)) => Err(e),
                    Err(_) => Err(papercup_core::client::ApiError::Network(
                        "join failure".into(),
                    )),
                }
            },
        )
        .await;
        match gated {
            Ok(v) => Ok(v.into()),
            Err(papercup_core::biometric::BiometricGateError::Denied) => {
                Err(ApiError::Unauthorized)
            }
            Err(papercup_core::biometric::BiometricGateError::Inner(e)) => Err(e.into()),
        }
    }

    pub async fn list_desktop_devices(&self) -> Result<Vec<Device>, ApiError> {
        let core = self.inner.clone();
        let result = rt()
            .spawn(async move { core.list_desktop_devices().await })
            .await
            .map_err(|_| ApiError::Network {
                detail: "tokio join".into(),
            })??;
        Ok(result.into_iter().map(Device::from).collect())
    }

    pub async fn revoke_device(&self, device_id: String) -> Result<(), ApiError> {
        let core = self.inner.clone();
        let prompt = self.current_prompt();
        let id_for_reason = device_id.clone();
        let gated = papercup_core::biometric::gate(
            prompt,
            papercup_core::biometric::RiskLevel::High,
            &format!(
                "Revoke device {}",
                &id_for_reason[..id_for_reason.len().min(8)]
            ),
            || async {
                let r = rt()
                    .spawn(async move { core.revoke_device(&device_id).await })
                    .await;
                match r {
                    Ok(Ok(())) => Ok(()),
                    Ok(Err(e)) => Err(e),
                    Err(_) => Err(papercup_core::client::ApiError::Network(
                        "join failure".into(),
                    )),
                }
            },
        )
        .await;
        match gated {
            Ok(()) => Ok(()),
            Err(papercup_core::biometric::BiometricGateError::Denied) => {
                Err(ApiError::Unauthorized)
            }
            Err(papercup_core::biometric::BiometricGateError::Inner(e)) => Err(e.into()),
        }
    }

    /// Post-pair runtime config — gives the host the voice WS port/path.
    pub async fn runtime_config(&self) -> Result<RuntimeConfig, ApiError> {
        let core = self.inner.clone();
        let result = rt()
            .spawn(async move { core.runtime_config().await })
            .await
            .map_err(|_| ApiError::Network {
                detail: "tokio join".into(),
            })??;
        Ok(result.into())
    }

    /// Mobile voice bootstrap for either desktop-local or ElevenLabs Conv
    /// AI. Cooldown/concurrency rejections surface as ApiError::Server with
    /// the server's hint in `detail`.
    pub async fn voice_session_init(&self) -> Result<VoiceSessionInit, ApiError> {
        let core = self.inner.clone();
        let result = rt()
            .spawn(async move { core.voice_session_init().await })
            .await
            .map_err(|_| ApiError::Network {
                detail: "tokio join".into(),
            })??;
        Ok(result.into())
    }

    /// Raw polling fetch: `GET /api/device/rest-query?name=&args=` →
    /// the `rows` payload as a JSON string. Prefer SyncCache+polling for
    /// UI surfaces; this is the escape hatch for one-shot queries.
    pub async fn rest_query(&self, name: String, args_json: String) -> Result<String, ApiError> {
        let core = self.inner.clone();
        let result = rt()
            .spawn(async move { core.rest_query(&name, &args_json).await })
            .await
            .map_err(|_| ApiError::Network {
                detail: "tokio join".into(),
            })??;
        Ok(result.rows.to_string())
    }

    /// `GET /api/device/operator/conversation` — the shared operator
    /// chat thread + recent turns (D-002).
    pub async fn operator_conversation(&self, limit: u32) -> Result<ConversationRead, ApiError> {
        let core = self.inner.clone();
        let read = rt()
            .spawn(async move { core.operator_conversation(limit).await })
            .await
            .map_err(|_| ApiError::Network {
                detail: "tokio join".into(),
            })??;
        Ok(ConversationRead {
            conversation_id: read.conversation.id,
            status: read.conversation.status,
            has_more_earlier: read.has_more_earlier,
            turns: read.turns.into_iter().map(OperatorTurn::from).collect(),
        })
    }

    /// `POST /api/device/operator/converse` — send a typed message. Awaits
    /// the operator's full turn (drains the SSE stream); re-call
    /// operator_conversation() afterwards to display the new turns.
    pub async fn operator_converse(&self, text: String) -> Result<(), ApiError> {
        let core = self.inner.clone();
        rt().spawn(async move { core.operator_converse(&text).await })
            .await
            .map_err(|_| ApiError::Network {
                detail: "tokio join".into(),
            })??;
        Ok(())
    }

    /// Streaming variant of operator_converse — `listener.on_delta` fires
    /// with each SSE `delta` fragment (UDL callbacks are Send + Sync, so
    /// invoking from the runtime task is safe). Resolves once the server
    /// has persisted both turns.
    pub async fn operator_converse_stream(
        &self,
        text: String,
        listener: Box<dyn ConverseDelta>,
    ) -> Result<(), ApiError> {
        let core = self.inner.clone();
        rt().spawn(async move {
            core.operator_converse_stream(&text, |d| listener.on_delta(d.to_string()))
                .await
        })
        .await
        .map_err(|_| ApiError::Network {
            detail: "tokio join".into(),
        })??;
        Ok(())
    }

    /// Current fleet/pot presence from the existing monitoring route.
    pub async fn fleet_activity(&self) -> Result<Option<FleetActivitySummary>, ApiError> {
        let core = self.inner.clone();
        let snapshot = rt()
            .spawn(async move { core.monitoring().await })
            .await
            .map_err(|_| ApiError::Network {
                detail: "tokio join".into(),
            })??;
        Ok(snapshot.fleets.map(|activity| FleetActivitySummary {
            agents: activity.agents,
            available_agents: activity.live,
            fleets: activity
                .fleets
                .into_iter()
                .map(|fleet| FleetActivityRow {
                    slug: fleet.fleet_slug,
                    members: fleet.members,
                    available_agents: fleet.live,
                    leader: fleet.leader,
                })
                .collect(),
            pots: activity
                .pots
                .into_iter()
                .map(|pot| PotActivityRow {
                    slug: pot.pot_slug,
                    agents: pot.agents,
                    available_agents: pot.live,
                })
                .collect(),
        }))
    }

    /// `GET /api/device/attention` — the Inbox attention feed (D-002).
    pub async fn attention(&self) -> Result<AttentionFeed, ApiError> {
        let core = self.inner.clone();
        let resp = rt()
            .spawn(async move { core.attention().await })
            .await
            .map_err(|_| ApiError::Network {
                detail: "tokio join".into(),
            })??;
        Ok(AttentionFeed::from(resp))
    }

    /// `GET /api/device/plans` — plan summaries. `harness=None` → All Pots.
    pub async fn plans_list(
        &self,
        harness: Option<String>,
        include_archived: bool,
    ) -> Result<Vec<PlanSummary>, ApiError> {
        let core = self.inner.clone();
        let result = rt()
            .spawn(async move { core.plans_list(harness.as_deref(), include_archived).await })
            .await
            .map_err(|_| ApiError::Network {
                detail: "tokio join".into(),
            })??;
        Ok(result.into_iter().map(PlanSummary::from).collect())
    }

    /// `GET /api/device/plans/:slug` — one plan's full detail.
    pub async fn plan_get(
        &self,
        slug: String,
        harness: Option<String>,
    ) -> Result<PlanDetail, ApiError> {
        let core = self.inner.clone();
        let result = rt()
            .spawn(async move { core.plan_get(&slug, harness.as_deref()).await })
            .await
            .map_err(|_| ApiError::Network {
                detail: "tokio join".into(),
            })??;
        Ok(result.into())
    }

    /// `POST /api/device/plans/:slug/items/:itemId/status` — flip a plan
    /// item's status (approve→done, nudge→wip, gate→needs-human). Returns
    /// the server's result JSON as a string.
    pub async fn plan_item_set_status(
        &self,
        slug: String,
        item_id: String,
        status: String,
        note: Option<String>,
        harness: Option<String>,
    ) -> Result<String, ApiError> {
        let core = self.inner.clone();
        let result = rt()
            .spawn(async move {
                core.plan_item_set_status(
                    &slug,
                    &item_id,
                    &status,
                    note.as_deref(),
                    harness.as_deref(),
                )
                .await
            })
            .await
            .map_err(|_| ApiError::Network {
                detail: "tokio join".into(),
            })??;
        Ok(result.to_string())
    }

    pub async fn standing_candidates(&self) -> Result<Vec<StandingCandidate>, ApiError> {
        let core = self.inner.clone();
        let result = rt()
            .spawn(async move { core.standing_candidates().await })
            .await
            .map_err(|_| ApiError::Network {
                detail: "tokio join".into(),
            })??;
        Ok(result.into_iter().map(StandingCandidate::from).collect())
    }

    pub async fn standing_candidate_decide(
        &self,
        capability: String,
        target_harness: String,
        approve: bool,
    ) -> Result<(), ApiError> {
        let core = self.inner.clone();
        let decision = if approve { "approve" } else { "dismiss" }.to_string();
        rt().spawn(async move {
            core.standing_candidate_decide(&capability, &target_harness, &decision)
                .await
        })
        .await
        .map_err(|_| ApiError::Network {
            detail: "tokio join".into(),
        })??;
        Ok(())
    }

    /// Exchange a one-time pair token for a device JWT. The response's
    /// `defguard_enrollment_url` is the Defguard self-enrollment hand-off
    /// (D-005) — no WireGuard config is exchanged at pair time anymore.
    pub async fn pair(&self, pair_token: String) -> Result<PairOutcome, PairError> {
        let core = self.inner.clone();
        let resp = rt()
            .spawn(async move { core.pair(PairBody { pair_token }).await })
            .await
            .map_err(|_| PairError::Network {
                detail: "tokio join".into(),
            })??;
        Ok(PairOutcome {
            device_token: resp.device_token,
            device_id: resp.device_id,
            workspace_id: resp.workspace_id,
            desktop_host: resp.desktop_host,
            defguard_enrollment_url: resp.defguard_enrollment_url,
            base_urls_json: routes_json(&resp.base_urls),
        })
    }
}

/// `baseUrls` as the raw JSON route list the native clients decode (D-018).
/// An absent field deserializes to `Value::Null`; hand the clients an empty
/// string for that rather than the literal `null`, so "no route list" has one
/// spelling across Swift and Kotlin.
fn routes_json(v: &serde_json::Value) -> String {
    if v.is_null() {
        String::new()
    } else {
        v.to_string()
    }
}

#[cfg(test)]
mod routes_json_tests {
    use super::routes_json;

    #[test]
    fn absent_route_list_is_empty_string() {
        assert_eq!(routes_json(&serde_json::Value::Null), "");
    }

    #[test]
    fn relay_route_list_round_trips_as_json() {
        let v = serde_json::json!([{ "kind": "relay", "url": "https://relay.example/w/1" }]);
        let back: serde_json::Value = serde_json::from_str(&routes_json(&v)).unwrap();
        assert_eq!(back, v);
    }
}
