// SPDX-License-Identifier: GPL-3.0-or-later
//
// HTTP client for the Papercup operator. Mirrors the existing TS app's
// `apiFetch` shape but from Rust.
//
// Phase 1 surface:
//   - `OperatorClient::new(base_url, device_token)`
//   - `OperatorClient::list_harnesses()` → `Vec<HarnessLite>`
//   - `OperatorClient::pair(qr_payload)` → `PairResp` (no token needed)
//
// Later phases extend with: SSE sync stream (Phase 3), voice WS (Phase 4),
// mesh-aware base URL fallback (Phase 6).

use crate::types::{
    AuditResp, AuditRow, DesktopDevicesResp, DeviceRow, ErrorBody, HarnessLite, HarnessStatusFull,
    ListResp, OperatorCard, OperatorCardActionResp, OperatorCardsResp, PairBody, PairResp,
    PauseInfo, PushRegisterBody, RunningHarnessPhase, RunningResp, RunningScan, StandingCandidate,
    StandingCandidatesResp, StandingDecisionBody, ToastRow, ToastsResp, VoiceLeaseRead,
    VoiceLeaseShape, WorkspaceItem, WorkspaceSwitchBody, WorkspaceSwitchResp, WorkspacesResp,
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
}

impl From<reqwest::Error> for ApiError {
    fn from(e: reqwest::Error) -> Self {
        ApiError::Network(e.to_string())
    }
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
    /// failure. Phase 6 designed deliverable.
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
    /// status changes (e.g. after `MeshState::Up`).
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

    /// `GET /api/device/harnesses` — returns the user's harnesses.
    /// Requires a paired device token.
    pub async fn list_harnesses(&self) -> Result<Vec<HarnessLite>, ApiError> {
        self.bearer_get_json::<ListResp>("/api/device/harnesses")
            .await
            .map(|r| r.harnesses)
    }

    /// `GET /api/device/harnesses/{slug}` — returns the per-harness
    /// status. Today this is thin (slug/status/iteration/last_active_ts);
    /// backend has the rich `StatusResp` shape on the desktop endpoint
    /// and will fold it into this route in a later stage.
    pub async fn get_harness_status(&self, slug: &str) -> Result<HarnessStatusFull, ApiError> {
        let url = format!("{}/api/device/harnesses/{}", self.base_url(), slug);
        let mut req = self.http.get(&url);
        req = match &self.device_token {
            Some(tok) => req.bearer_auth(tok),
            None => return Err(ApiError::Unauthorized),
        };
        let resp = req.send().await?;
        let status = resp.status();
        if status.as_u16() == 401 {
            return Err(ApiError::Unauthorized);
        }
        if !status.is_success() {
            let detail = resp
                .json::<ErrorBody>()
                .await
                .map(|e| e.error)
                .unwrap_or_else(|_| status.canonical_reason().unwrap_or("").to_string());
            return Err(ApiError::Server {
                status: status.as_u16(),
                detail,
            });
        }
        resp.json::<HarnessStatusFull>()
            .await
            .map_err(|e| ApiError::Decode(e.to_string()))
    }

    /// `GET /api/device/running` — per-phase status of every active
    /// harness (passed/todo/blocked counts + active_roles). Tauri-parity
    /// "Currently running" view.
    pub async fn list_running(&self) -> Result<Vec<RunningHarnessPhase>, ApiError> {
        let url = format!("{}/api/device/running", self.base_url());
        self.bearer_get_json::<RunningResp>(&url)
            .await
            .map(|r| r.harnesses)
    }

    /// `GET /api/device/running` — full running snapshot including the
    /// current operator scan summary when one is active.
    pub async fn running_snapshot(
        &self,
    ) -> Result<(Option<RunningScan>, Vec<RunningHarnessPhase>), ApiError> {
        let url = format!("{}/api/device/running", self.base_url());
        self.bearer_get_json::<RunningResp>(&url)
            .await
            .map(|r| (r.scan, r.harnesses))
    }

    /// `GET /api/device/voice-lease` — current lease holder (or `None`
    /// if no one is listening).
    pub async fn voice_lease_get(&self) -> Result<Option<VoiceLeaseShape>, ApiError> {
        let url = format!("{}/api/device/voice-lease", self.base_url());
        self.bearer_get_json::<VoiceLeaseRead>(&url)
            .await
            .map(|r| r.lease)
    }

    /// `POST /api/device/voice-lease/claim` — phone always pre-empts.
    /// 12-second TTL server-side; refresh via `voice_lease_heartbeat`.
    pub async fn voice_lease_claim(&self) -> Result<(), ApiError> {
        self.bearer_post_empty("/api/device/voice-lease/claim")
            .await
    }

    /// `POST /api/device/voice-lease/heartbeat` — refresh-if-mine; the
    /// server returns 409 if another owner holds the lease (the phone
    /// then surfaces "you've been preempted" and stops listening).
    pub async fn voice_lease_heartbeat(&self) -> Result<(), ApiError> {
        self.bearer_post_empty("/api/device/voice-lease/heartbeat")
            .await
    }

    /// `DELETE /api/device/voice-lease` — release-if-mine; idempotent.
    pub async fn voice_lease_release(&self) -> Result<(), ApiError> {
        let url = format!("{}/api/device/voice-lease", self.base_url());
        self.bearer_delete_empty(&url).await
    }

    /// Helper for POST endpoints that take no body and return only `{ok:true}`.
    async fn bearer_post_empty(&self, path: &str) -> Result<(), ApiError> {
        let url = format!("{}{}", self.base_url(), path);
        let mut req = self.http.post(&url);
        req = match &self.device_token {
            Some(tok) => req.bearer_auth(tok),
            None => return Err(ApiError::Unauthorized),
        };
        let resp = req.send().await?;
        let status = resp.status();
        if status.as_u16() == 401 {
            return Err(ApiError::Unauthorized);
        }
        if !status.is_success() {
            return Err(ApiError::Server {
                status: status.as_u16(),
                detail: status.canonical_reason().unwrap_or("").to_string(),
            });
        }
        Ok(())
    }

    async fn bearer_delete_empty(&self, url: &str) -> Result<(), ApiError> {
        let mut req = self.http.delete(url);
        req = match &self.device_token {
            Some(tok) => req.bearer_auth(tok),
            None => return Err(ApiError::Unauthorized),
        };
        let resp = req.send().await?;
        let status = resp.status();
        if status.as_u16() == 401 {
            return Err(ApiError::Unauthorized);
        }
        if !status.is_success() {
            return Err(ApiError::Server {
                status: status.as_u16(),
                detail: status.canonical_reason().unwrap_or("").to_string(),
            });
        }
        Ok(())
    }

    /// `POST /api/device/heartbeat` — bumps `last_seen` server-side so
    /// the desktop's "is the phone connected" badge stays fresh. Cheap;
    /// safe to call every minute while foregrounded.
    pub async fn heartbeat(&self) -> Result<(), ApiError> {
        let url = format!("{}/api/device/heartbeat", self.base_url());
        let mut req = self.http.post(&url);
        req = match &self.device_token {
            Some(tok) => req.bearer_auth(tok),
            None => return Err(ApiError::Unauthorized),
        };
        let resp = req.send().await?;
        let status = resp.status();
        if status.as_u16() == 401 {
            return Err(ApiError::Unauthorized);
        }
        if !status.is_success() {
            return Err(ApiError::Server {
                status: status.as_u16(),
                detail: status.canonical_reason().unwrap_or("").to_string(),
            });
        }
        Ok(())
    }

    /// `GET /api/device/notifications/recent` — most recent toast_log
    /// entries scoped to the device's workspace. Limit defaults to 50.
    pub async fn recent_notifications(&self) -> Result<Vec<ToastRow>, ApiError> {
        let url = format!("{}/api/device/notifications/recent", self.base_url());
        self.bearer_get_json::<ToastsResp>(&url)
            .await
            .map(|r| r.toasts)
    }

    /// `GET /api/device/actions/recent` — most recent audit_log entries
    /// scoped to the device's workspace.
    pub async fn recent_actions(&self) -> Result<Vec<AuditRow>, ApiError> {
        let url = format!("{}/api/device/actions/recent", self.base_url());
        self.bearer_get_json::<AuditResp>(&url)
            .await
            .map(|r| r.entries)
    }

    /// `GET /api/device/operator/pause` — current global pause state.
    pub async fn pause_get(&self) -> Result<PauseInfo, ApiError> {
        let url = format!("{}/api/device/operator/pause", self.base_url());
        self.bearer_get_json::<PauseInfo>(&url).await
    }

    /// `POST` (set) or `DELETE` (clear) the global pause flag. Returns
    /// the new state. The server fires a `sync_invalidate` for
    /// `operatorPauseFlag` so peer clients converge instantly.
    pub async fn pause_set(&self, paused: bool) -> Result<bool, ApiError> {
        let url = format!("{}/api/device/operator/pause", self.base_url());
        let mut req = if paused {
            self.http.post(&url)
        } else {
            self.http.delete(&url)
        };
        req = match &self.device_token {
            Some(tok) => req.bearer_auth(tok),
            None => return Err(ApiError::Unauthorized),
        };
        let resp = req.send().await?;
        let status = resp.status();
        if status.as_u16() == 401 {
            return Err(ApiError::Unauthorized);
        }
        if !status.is_success() {
            return Err(ApiError::Server {
                status: status.as_u16(),
                detail: status.canonical_reason().unwrap_or("").to_string(),
            });
        }
        #[derive(serde::Deserialize)]
        struct R {
            paused: bool,
        }
        resp.json::<R>()
            .await
            .map(|r| r.paused)
            .map_err(|e| ApiError::Decode(e.to_string()))
    }

    /// `POST /api/device/workspace/switch` — re-issues a deviceToken
    /// scoped to the new workspace. The phone must persist the new
    /// token in place of the old one immediately.
    pub async fn workspace_switch(
        &self,
        workspace_id: &str,
    ) -> Result<WorkspaceSwitchResp, ApiError> {
        let url = format!("{}/api/device/workspace/switch", self.base_url());
        let mut req = self.http.post(&url).json(&WorkspaceSwitchBody {
            workspace_id: workspace_id.to_string(),
        });
        req = match &self.device_token {
            Some(tok) => req.bearer_auth(tok),
            None => return Err(ApiError::Unauthorized),
        };
        let resp = req.send().await?;
        let status = resp.status();
        if status.as_u16() == 401 {
            return Err(ApiError::Unauthorized);
        }
        if !status.is_success() {
            let detail = resp
                .json::<ErrorBody>()
                .await
                .map(|e| e.error)
                .unwrap_or_else(|_| status.canonical_reason().unwrap_or("").to_string());
            return Err(ApiError::Server {
                status: status.as_u16(),
                detail,
            });
        }
        resp.json::<WorkspaceSwitchResp>()
            .await
            .map_err(|e| ApiError::Decode(e.to_string()))
    }

    /// `GET /api/device/workspaces` — list of workspaces the device can
    /// see, with the currently-selected one flagged.
    pub async fn list_workspaces(&self) -> Result<Vec<WorkspaceItem>, ApiError> {
        let url = format!("{}/api/device/workspaces", self.base_url());
        self.bearer_get_json::<WorkspacesResp>(&url)
            .await
            .map(|r| r.workspaces)
    }

    /// `GET /api/device/devices` — every paired device, including
    /// this one (matched by device_id).
    pub async fn list_desktop_devices(&self) -> Result<Vec<DeviceRow>, ApiError> {
        let url = format!("{}/api/device/devices", self.base_url());
        self.bearer_get_json::<DesktopDevicesResp>(&url)
            .await
            .map(|r| r.devices)
    }

    /// `GET /api/device/operator/cards`
    pub async fn list_operator_cards(&self) -> Result<Vec<OperatorCard>, ApiError> {
        let url = format!("{}/api/device/operator/cards", self.base_url());
        self.bearer_get_json::<OperatorCardsResp>(&url)
            .await
            .map(|r| r.cards)
    }

    /// `POST /api/device/operator/cards/{id}/dispatch`
    pub async fn dispatch_operator_card(&self, card_id: &str) -> Result<String, ApiError> {
        let url = format!(
            "{}/api/device/operator/cards/{card_id}/dispatch",
            self.base_url()
        );
        let mut req = self.http.post(&url);
        req = match &self.device_token {
            Some(tok) => req.bearer_auth(tok),
            None => return Err(ApiError::Unauthorized),
        };
        let resp = req.send().await?;
        let status = resp.status();
        if status.as_u16() == 401 {
            return Err(ApiError::Unauthorized);
        }
        if !status.is_success() {
            let detail = resp
                .json::<ErrorBody>()
                .await
                .map(|e| e.error)
                .unwrap_or_else(|_| status.canonical_reason().unwrap_or("").to_string());
            return Err(ApiError::Server {
                status: status.as_u16(),
                detail,
            });
        }
        let body = resp
            .json::<OperatorCardActionResp>()
            .await
            .map_err(|e| ApiError::Decode(e.to_string()))?;
        body.message
            .ok_or_else(|| ApiError::Decode("missing message".into()))
    }

    /// `POST /api/device/operator/cards/{id}/dismiss`
    pub async fn dismiss_operator_card(&self, card_id: &str) -> Result<String, ApiError> {
        let url = format!(
            "{}/api/device/operator/cards/{card_id}/dismiss",
            self.base_url()
        );
        let mut req = self.http.post(&url);
        req = match &self.device_token {
            Some(tok) => req.bearer_auth(tok),
            None => return Err(ApiError::Unauthorized),
        };
        let resp = req.send().await?;
        let status = resp.status();
        if status.as_u16() == 401 {
            return Err(ApiError::Unauthorized);
        }
        if !status.is_success() {
            let detail = resp
                .json::<ErrorBody>()
                .await
                .map(|e| e.error)
                .unwrap_or_else(|_| status.canonical_reason().unwrap_or("").to_string());
            return Err(ApiError::Server {
                status: status.as_u16(),
                detail,
            });
        }
        let body = resp
            .json::<OperatorCardActionResp>()
            .await
            .map_err(|e| ApiError::Decode(e.to_string()))?;
        body.message
            .ok_or_else(|| ApiError::Decode("missing message".into()))
    }

    /// `GET /api/device/operator/standing-candidates`
    pub async fn standing_candidates(&self) -> Result<Vec<StandingCandidate>, ApiError> {
        let url = format!(
            "{}/api/device/operator/standing-candidates",
            self.base_url()
        );
        self.bearer_get_json::<StandingCandidatesResp>(&url)
            .await
            .map(|r| r.candidates)
    }

    /// `POST /api/device/operator/standing-candidates/decide`
    pub async fn standing_candidate_decide(
        &self,
        capability: &str,
        target_harness: &str,
        decision: &str,
    ) -> Result<(), ApiError> {
        let url = format!(
            "{}/api/device/operator/standing-candidates/decide",
            self.base_url()
        );
        let mut req = self.http.post(&url).json(&StandingDecisionBody {
            capability: capability.to_string(),
            target_harness: target_harness.to_string(),
            decision: decision.to_string(),
        });
        req = match &self.device_token {
            Some(tok) => req.bearer_auth(tok),
            None => return Err(ApiError::Unauthorized),
        };
        let resp = req.send().await?;
        let status = resp.status();
        if status.as_u16() == 401 {
            return Err(ApiError::Unauthorized);
        }
        if !status.is_success() {
            return Err(ApiError::Server {
                status: status.as_u16(),
                detail: status.canonical_reason().unwrap_or("").to_string(),
            });
        }
        Ok(())
    }

    /// `DELETE /api/device/devices/{id}` — unpair the given device.
    /// Server also invokes Defguard revoke_user.
    pub async fn revoke_device(&self, device_id: &str) -> Result<(), ApiError> {
        let url = format!("{}/api/device/devices/{}", self.base_url(), device_id);
        let mut req = self.http.delete(&url);
        req = match &self.device_token {
            Some(tok) => req.bearer_auth(tok),
            None => return Err(ApiError::Unauthorized),
        };
        let resp = req.send().await?;
        let status = resp.status();
        if status.as_u16() == 401 {
            return Err(ApiError::Unauthorized);
        }
        if !status.is_success() {
            return Err(ApiError::Server {
                status: status.as_u16(),
                detail: status.canonical_reason().unwrap_or("").to_string(),
            });
        }
        Ok(())
    }

    /// Bearer-auth GET → JSON. Helper for the read-only mobile endpoints.
    async fn bearer_get_json<T: serde::de::DeserializeOwned>(
        &self,
        path_or_url: &str,
    ) -> Result<T, ApiError> {
        // Accept either a full URL (legacy callers that build their
        // own from self.base_url()) or a leading-slash path. Path form
        // gets the mesh→public fallback retry; full-URL form doesn't.
        let is_path = path_or_url.starts_with('/');
        let do_request = |base: String| async move {
            let url = if is_path {
                format!("{}{}", base, path_or_url)
            } else {
                path_or_url.to_string()
            };
            let mut req = self.http.get(&url);
            req = match &self.device_token {
                Some(tok) => req.bearer_auth(tok),
                None => return Err(ApiError::Unauthorized),
            };
            let resp = req.send().await?;
            let status = resp.status();
            if status.as_u16() == 401 {
                return Err(ApiError::Unauthorized);
            }
            if !status.is_success() {
                let detail = resp
                    .json::<ErrorBody>()
                    .await
                    .map(|e| e.error)
                    .unwrap_or_else(|_| status.canonical_reason().unwrap_or("").to_string());
                return Err(ApiError::Server {
                    status: status.as_u16(),
                    detail,
                });
            }
            resp.json::<T>()
                .await
                .map_err(|e| ApiError::Decode(e.to_string()))
        };
        if is_path {
            self.with_fallback(do_request).await
        } else {
            do_request(String::new()).await
        }
    }

    /// `POST /api/device/push/register` — registers an FCM/APNS token
    /// with the backend so the desktop can deliver push notifications.
    /// Idempotent (server upserts).
    pub async fn register_push(&self, body: PushRegisterBody) -> Result<(), ApiError> {
        let url = format!("{}/api/device/push/register", self.base_url());
        let mut req = self.http.post(&url).json(&body);
        req = match &self.device_token {
            Some(tok) => req.bearer_auth(tok),
            None => return Err(ApiError::Unauthorized),
        };
        let resp = req.send().await?;
        let status = resp.status();
        if status.as_u16() == 401 {
            return Err(ApiError::Unauthorized);
        }
        if !status.is_success() {
            let detail = resp
                .json::<ErrorBody>()
                .await
                .map(|e| e.error)
                .unwrap_or_else(|_| status.canonical_reason().unwrap_or("").to_string());
            return Err(ApiError::Server {
                status: status.as_u16(),
                detail,
            });
        }
        Ok(())
    }

    /// `POST /api/device/pair` — exchanges a one-time pair token (from
    /// the desktop's QR code) for a long-lived device JWT. No bearer
    /// auth required for this call.
    pub async fn pair(&self, body: PairBody) -> Result<PairResp, ApiError> {
        let url = format!("{}/api/device/pair", self.base_url());
        let resp = self.http.post(&url).json(&body).send().await?;
        let status = resp.status();
        if !status.is_success() {
            let detail = resp
                .json::<ErrorBody>()
                .await
                .map(|e| e.error)
                .unwrap_or_else(|_| status.canonical_reason().unwrap_or("").to_string());
            if status == reqwest::StatusCode::UNAUTHORIZED {
                return Err(ApiError::Unauthorized);
            }
            return Err(ApiError::Server {
                status: status.as_u16(),
                detail,
            });
        }
        resp.json::<PairResp>()
            .await
            .map_err(|e| ApiError::Decode(e.to_string()))
    }
}
