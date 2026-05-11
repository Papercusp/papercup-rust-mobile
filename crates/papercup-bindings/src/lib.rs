// SPDX-License-Identifier: GPL-3.0-or-later
//
// UniFFI bindings layer. Re-exports `papercup-core` to Kotlin + Swift.

// uniffi::include_scaffolding! emits constants whose generated doc
// comments trip several clippy rules; quiet them at the crate level
// so our own code can still be -D warnings.
#![allow(clippy::empty_line_after_doc_comments)]

use papercup_core::client::{ApiError as CoreApiError, OperatorClient as CoreClient};
use papercup_core::mesh::{
    generate_wg_keypair as core_keygen, to_wg_quick as core_wgq, MeshSpec, WgKeyPair as CoreKp,
};
use papercup_core::sync::{SyncError as CoreSyncError, SyncStream as CoreSync};
use papercup_core::types::{
    AuditRow as CoreAudit, DeviceRow as CoreDevice, HarnessLite, HarnessStatusFull, PairBody,
    PauseInfo as CorePauseInfo, PushRegisterBody, RunningHarnessPhase as CoreRunning,
    StandingCandidate as CoreStandingCandidate, ToastRow as CoreToast,
    VoiceLeaseShape as CoreVoiceLease, WorkspaceItem as CoreWorkspace,
    WorkspaceSwitchResp as CoreWorkspaceSwitch,
};
use papercup_core::voice::{
    VoiceClient as CoreVoice, VoiceError as CoreVoiceError, VoiceEvent as CoreVoiceEvent,
    VoiceStatus as CoreVoiceStatus,
};

uniffi::include_scaffolding!("papercup");

// ── free fns ────────────────────────────────────────────────────────────

fn version() -> String {
    papercup_core::version()
}

fn generate_wg_keypair() -> WgKeyPair {
    let kp: CoreKp = core_keygen();
    WgKeyPair {
        private_key_b64: kp.private_key_b64,
        public_key_b64: kp.public_key_b64,
    }
}

fn mesh_to_wg_quick(private_key_b64: String, config: MeshConfig) -> String {
    let spec = MeshSpec {
        peer_public_key_b64: config.peer_public_key,
        peer_endpoint: config.peer_endpoint,
        allowed_ips: config.allowed_ips,
        assigned_ip: config.assigned_ip,
        mtu: config.mtu,
    };
    core_wgq(&private_key_b64, &spec)
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
    let raw: Raw = serde_json::from_str(text.trim()).map_err(|_| PairError::InvalidQr)?;
    if raw.server.is_empty() || raw.pair_token.is_empty() || raw.workspace_id.is_empty() {
        return Err(PairError::InvalidQr);
    }
    Ok(QrPayload {
        server: raw.server,
        pair_token: raw.pair_token,
        workspace_id: raw.workspace_id,
    })
}

// ── error mapping ───────────────────────────────────────────────────────

#[derive(Debug, thiserror::Error)]
pub enum ApiError {
    #[error("network error")]
    Network,
    #[error("server error")]
    Server,
    #[error("decode error")]
    Decode,
    #[error("unauthorized")]
    Unauthorized,
}

impl From<CoreApiError> for ApiError {
    fn from(e: CoreApiError) -> Self {
        match e {
            CoreApiError::Network(_) => ApiError::Network,
            CoreApiError::Server { .. } => ApiError::Server,
            CoreApiError::Decode(_) => ApiError::Decode,
            CoreApiError::Unauthorized => ApiError::Unauthorized,
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum PairError {
    #[error("QR payload is malformed or missing required fields")]
    InvalidQr,
    #[error("network error")]
    Network,
    #[error("server error")]
    Server,
    #[error("decode error")]
    Decode,
}

impl From<CoreApiError> for PairError {
    fn from(e: CoreApiError) -> Self {
        match e {
            CoreApiError::Network(_) => PairError::Network,
            CoreApiError::Server { .. } => PairError::Server,
            CoreApiError::Decode(_) => PairError::Decode,
            CoreApiError::Unauthorized => PairError::Server,
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
    pub mesh: Option<MeshConfig>,
}

pub struct MeshConfig {
    pub peer_public_key: String,
    pub peer_endpoint: String,
    pub allowed_ips: Vec<String>,
    pub assigned_ip: String,
    pub mtu: u32,
}

pub struct WgKeyPair {
    pub private_key_b64: String,
    pub public_key_b64: String,
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

fn parse_mesh(value: &serde_json::Value) -> Option<MeshConfig> {
    #[derive(serde::Deserialize)]
    struct Raw {
        peer_public_key: String,
        peer_endpoint: String,
        allowed_ips: Vec<String>,
        assigned_ip: String,
        mtu: u32,
    }
    serde_json::from_value::<Raw>(value.clone())
        .ok()
        .map(|r| MeshConfig {
            peer_public_key: r.peer_public_key,
            peer_endpoint: r.peer_endpoint,
            allowed_ips: r.allowed_ips,
            assigned_ip: r.assigned_ip,
            mtu: r.mtu,
        })
}

pub struct SyncEvent {
    pub id: String,
    pub name: String,
    pub args_json: String,
}

#[derive(Debug, thiserror::Error)]
pub enum SyncError {
    #[error("stream closed")]
    Closed,
}

impl From<CoreSyncError> for SyncError {
    fn from(e: CoreSyncError) -> Self {
        match e {
            CoreSyncError::Closed => SyncError::Closed,
        }
    }
}

pub struct SyncStream {
    inner: CoreSync,
}

impl SyncStream {
    pub fn new(base_url: String, device_token: String) -> Self {
        // Constructing the core stream spawns a tokio task; ensure our
        // shared runtime is current so the spawn lands on it.
        let _g = rt().enter();
        Self {
            inner: CoreSync::connect(&base_url, &device_token),
        }
    }

    pub async fn next_event(&self) -> Result<SyncEvent, SyncError> {
        let ev = self.inner.next_event().await?;
        Ok(SyncEvent {
            id: ev.id,
            name: ev.name,
            args_json: ev.args_json,
        })
    }

    pub fn disconnect(&self) {
        self.inner.close();
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
    pub fn new(base_url: String, device_token: String, wake_word: Option<String>) -> Self {
        let _g = rt().enter();
        Self {
            inner: CoreVoice::connect(&base_url, &device_token, wake_word.as_deref()),
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
}

impl OperatorClient {
    pub fn new(base_url: String, device_token: Option<String>) -> Self {
        Self {
            inner: CoreClient::new(base_url, device_token),
        }
    }

    pub async fn list_harnesses(&self) -> Result<Vec<Harness>, ApiError> {
        let core = self.inner.clone();
        let result = rt()
            .spawn(async move { core.list_harnesses().await })
            .await
            .map_err(|_| ApiError::Network)??;
        Ok(result.into_iter().map(Harness::from).collect())
    }

    pub async fn get_harness_status(&self, slug: String) -> Result<HarnessStatus, ApiError> {
        let core = self.inner.clone();
        let resp = rt()
            .spawn(async move { core.get_harness_status(&slug).await })
            .await
            .map_err(|_| ApiError::Network)??;
        Ok(resp.into())
    }

    pub async fn register_push(&self, platform: String, token: String) -> Result<(), ApiError> {
        let core = self.inner.clone();
        rt().spawn(async move {
            core.register_push(PushRegisterBody { platform, token })
                .await
        })
        .await
        .map_err(|_| ApiError::Network)??;
        Ok(())
    }

    pub async fn heartbeat(&self) -> Result<(), ApiError> {
        let core = self.inner.clone();
        rt().spawn(async move { core.heartbeat().await })
            .await
            .map_err(|_| ApiError::Network)??;
        Ok(())
    }

    pub async fn pause_get(&self) -> Result<PauseInfo, ApiError> {
        let core = self.inner.clone();
        let p = rt()
            .spawn(async move { core.pause_get().await })
            .await
            .map_err(|_| ApiError::Network)??;
        Ok(p.into())
    }

    pub async fn pause_set(&self, paused: bool) -> Result<bool, ApiError> {
        let core = self.inner.clone();
        let p = rt()
            .spawn(async move { core.pause_set(paused).await })
            .await
            .map_err(|_| ApiError::Network)??;
        Ok(p)
    }

    pub async fn voice_lease_claim(&self) -> Result<(), ApiError> {
        let core = self.inner.clone();
        rt().spawn(async move { core.voice_lease_claim().await })
            .await
            .map_err(|_| ApiError::Network)??;
        Ok(())
    }

    pub async fn voice_lease_heartbeat(&self) -> Result<(), ApiError> {
        let core = self.inner.clone();
        rt().spawn(async move { core.voice_lease_heartbeat().await })
            .await
            .map_err(|_| ApiError::Network)??;
        Ok(())
    }

    pub async fn voice_lease_release(&self) -> Result<(), ApiError> {
        let core = self.inner.clone();
        rt().spawn(async move { core.voice_lease_release().await })
            .await
            .map_err(|_| ApiError::Network)??;
        Ok(())
    }

    pub async fn voice_lease_get(&self) -> Result<Option<VoiceLease>, ApiError> {
        let core = self.inner.clone();
        let result = rt()
            .spawn(async move { core.voice_lease_get().await })
            .await
            .map_err(|_| ApiError::Network)??;
        Ok(result.map(VoiceLease::from))
    }

    pub async fn list_running(&self) -> Result<Vec<Running>, ApiError> {
        let core = self.inner.clone();
        let result = rt()
            .spawn(async move { core.list_running().await })
            .await
            .map_err(|_| ApiError::Network)??;
        Ok(result.into_iter().map(Running::from).collect())
    }

    pub async fn recent_notifications(&self) -> Result<Vec<Toast>, ApiError> {
        let core = self.inner.clone();
        let result = rt()
            .spawn(async move { core.recent_notifications().await })
            .await
            .map_err(|_| ApiError::Network)??;
        Ok(result.into_iter().map(Toast::from).collect())
    }

    pub async fn recent_actions(&self) -> Result<Vec<AuditEntry>, ApiError> {
        let core = self.inner.clone();
        let result = rt()
            .spawn(async move { core.recent_actions().await })
            .await
            .map_err(|_| ApiError::Network)??;
        Ok(result.into_iter().map(AuditEntry::from).collect())
    }

    pub async fn list_workspaces(&self) -> Result<Vec<Workspace>, ApiError> {
        let core = self.inner.clone();
        let result = rt()
            .spawn(async move { core.list_workspaces().await })
            .await
            .map_err(|_| ApiError::Network)??;
        Ok(result.into_iter().map(Workspace::from).collect())
    }

    pub async fn workspace_switch(
        &self,
        workspace_id: String,
    ) -> Result<WorkspaceSwitchResult, ApiError> {
        let core = self.inner.clone();
        let result = rt()
            .spawn(async move { core.workspace_switch(&workspace_id).await })
            .await
            .map_err(|_| ApiError::Network)??;
        Ok(result.into())
    }

    pub async fn list_desktop_devices(&self) -> Result<Vec<Device>, ApiError> {
        let core = self.inner.clone();
        let result = rt()
            .spawn(async move { core.list_desktop_devices().await })
            .await
            .map_err(|_| ApiError::Network)??;
        Ok(result.into_iter().map(Device::from).collect())
    }

    pub async fn revoke_device(&self, device_id: String) -> Result<(), ApiError> {
        let core = self.inner.clone();
        rt().spawn(async move { core.revoke_device(&device_id).await })
            .await
            .map_err(|_| ApiError::Network)??;
        Ok(())
    }

    pub async fn standing_candidates(&self) -> Result<Vec<StandingCandidate>, ApiError> {
        let core = self.inner.clone();
        let result = rt()
            .spawn(async move { core.standing_candidates().await })
            .await
            .map_err(|_| ApiError::Network)??;
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
        .map_err(|_| ApiError::Network)??;
        Ok(())
    }

    pub async fn pair(
        &self,
        pair_token: String,
        wireguard_pubkey_b64: Option<String>,
    ) -> Result<PairOutcome, PairError> {
        let core = self.inner.clone();
        let resp = rt()
            .spawn(async move {
                core.pair(PairBody {
                    pair_token,
                    wireguard_pubkey: wireguard_pubkey_b64,
                })
                .await
            })
            .await
            .map_err(|_| PairError::Network)??;
        let mesh = resp.wg_config.as_ref().and_then(parse_mesh);
        Ok(PairOutcome {
            device_token: resp.device_token,
            device_id: resp.device_id,
            workspace_id: resp.workspace_id,
            desktop_host: resp.desktop_host,
            mesh,
        })
    }
}
