// SPDX-License-Identifier: GPL-3.0-or-later
//
// UniFFI bindings layer. Re-exports `papercup-core` to Kotlin + Swift.

use papercup_core::client::{ApiError as CoreApiError, OperatorClient as CoreClient};
use papercup_core::sync::{SyncError as CoreSyncError, SyncStream as CoreSync};
use papercup_core::types::{HarnessLite, HarnessStatusFull, PairBody};

uniffi::include_scaffolding!("papercup");

// ── free fns ────────────────────────────────────────────────────────────

fn version() -> String {
    papercup_core::version()
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
    pub status: String,
    pub iteration: i64,
    pub last_active_ts: Option<i64>,
}

impl From<HarnessStatusFull> for HarnessStatus {
    fn from(h: HarnessStatusFull) -> Self {
        Self {
            slug: h.slug,
            status: h.status,
            iteration: h.iteration,
            last_active_ts: h.last_active_ts,
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

fn parse_mesh(value: &serde_json::Value) -> Option<MeshConfig> {
    #[derive(serde::Deserialize)]
    struct Raw {
        peer_public_key: String,
        peer_endpoint: String,
        allowed_ips: Vec<String>,
        assigned_ip: String,
        mtu: u32,
    }
    serde_json::from_value::<Raw>(value.clone()).ok().map(|r| MeshConfig {
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

    pub async fn pair(&self, pair_token: String) -> Result<PairOutcome, PairError> {
        let core = self.inner.clone();
        let resp = rt()
            .spawn(async move {
                core.pair(PairBody {
                    pair_token,
                    wireguard_pubkey: None,
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
