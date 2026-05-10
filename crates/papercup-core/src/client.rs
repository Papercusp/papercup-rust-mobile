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
    ListResp, PairBody, PairResp, PauseInfo, PushRegisterBody, ToastRow, ToastsResp, WorkspaceItem,
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
}

impl From<reqwest::Error> for ApiError {
    fn from(e: reqwest::Error) -> Self {
        ApiError::Network(e.to_string())
    }
}

#[derive(Debug, Clone)]
pub struct OperatorClient {
    base_url: String,
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
            base_url: base_url.into().trim_end_matches('/').to_string(),
            device_token,
            http,
        }
    }

    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    /// `GET /api/mobile/harnesses` — returns the user's harnesses.
    /// Requires a paired device token.
    pub async fn list_harnesses(&self) -> Result<Vec<HarnessLite>, ApiError> {
        let url = format!("{}/api/mobile/harnesses", self.base_url);
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
        let body = resp.json::<ListResp>().await.map_err(|e| ApiError::Decode(e.to_string()))?;
        Ok(body.harnesses)
    }

    /// `GET /api/mobile/harnesses/{slug}` — returns the per-harness
    /// status. Today this is thin (slug/status/iteration/last_active_ts);
    /// backend has the rich `StatusResp` shape on the desktop endpoint
    /// and will fold it into this route in a later stage.
    pub async fn get_harness_status(&self, slug: &str) -> Result<HarnessStatusFull, ApiError> {
        let url = format!("{}/api/mobile/harnesses/{}", self.base_url, slug);
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
            return Err(ApiError::Server { status: status.as_u16(), detail });
        }
        resp.json::<HarnessStatusFull>()
            .await
            .map_err(|e| ApiError::Decode(e.to_string()))
    }

    /// `POST /api/mobile/voice-lease/claim` — phone always pre-empts.
    /// 12-second TTL server-side; refresh via `voice_lease_heartbeat`.
    pub async fn voice_lease_claim(&self) -> Result<(), ApiError> {
        self.bearer_post_empty("/api/mobile/voice-lease/claim").await
    }

    /// `POST /api/mobile/voice-lease/heartbeat` — refresh-if-mine; the
    /// server returns 409 if another owner holds the lease (the phone
    /// then surfaces "you've been preempted" and stops listening).
    pub async fn voice_lease_heartbeat(&self) -> Result<(), ApiError> {
        self.bearer_post_empty("/api/mobile/voice-lease/heartbeat")
            .await
    }

    /// `DELETE /api/mobile/voice-lease` — release-if-mine; idempotent.
    pub async fn voice_lease_release(&self) -> Result<(), ApiError> {
        let url = format!("{}/api/mobile/voice-lease", self.base_url);
        self.bearer_delete_empty(&url).await
    }

    /// Helper for POST endpoints that take no body and return only `{ok:true}`.
    async fn bearer_post_empty(&self, path: &str) -> Result<(), ApiError> {
        let url = format!("{}{}", self.base_url, path);
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

    /// `POST /api/mobile/heartbeat` — bumps `last_seen` server-side so
    /// the desktop's "is the phone connected" badge stays fresh. Cheap;
    /// safe to call every minute while foregrounded.
    pub async fn heartbeat(&self) -> Result<(), ApiError> {
        let url = format!("{}/api/mobile/heartbeat", self.base_url);
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

    /// `GET /api/mobile/notifications/recent` — most recent toast_log
    /// entries scoped to the device's workspace. Limit defaults to 50.
    pub async fn recent_notifications(&self) -> Result<Vec<ToastRow>, ApiError> {
        let url = format!("{}/api/mobile/notifications/recent", self.base_url);
        self.bearer_get_json::<ToastsResp>(&url).await.map(|r| r.toasts)
    }

    /// `GET /api/mobile/actions/recent` — most recent audit_log entries
    /// scoped to the device's workspace.
    pub async fn recent_actions(&self) -> Result<Vec<AuditRow>, ApiError> {
        let url = format!("{}/api/mobile/actions/recent", self.base_url);
        self.bearer_get_json::<AuditResp>(&url).await.map(|r| r.entries)
    }

    /// `GET /api/mobile/operator/pause` — current global pause state.
    pub async fn pause_get(&self) -> Result<PauseInfo, ApiError> {
        let url = format!("{}/api/mobile/operator/pause", self.base_url);
        self.bearer_get_json::<PauseInfo>(&url).await
    }

    /// `POST` (set) or `DELETE` (clear) the global pause flag. Returns
    /// the new state. The server fires a `sync_invalidate` for
    /// `operatorPauseFlag` so peer clients converge instantly.
    pub async fn pause_set(&self, paused: bool) -> Result<bool, ApiError> {
        let url = format!("{}/api/mobile/operator/pause", self.base_url);
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

    /// `GET /api/mobile/workspaces` — list of workspaces the device can
    /// see, with the currently-selected one flagged.
    pub async fn list_workspaces(&self) -> Result<Vec<WorkspaceItem>, ApiError> {
        let url = format!("{}/api/mobile/workspaces", self.base_url);
        self.bearer_get_json::<WorkspacesResp>(&url).await.map(|r| r.workspaces)
    }

    /// `GET /api/mobile/desktop/devices` — every paired device, including
    /// this one (matched by device_id).
    pub async fn list_desktop_devices(&self) -> Result<Vec<DeviceRow>, ApiError> {
        let url = format!("{}/api/mobile/desktop/devices", self.base_url);
        self.bearer_get_json::<DesktopDevicesResp>(&url).await.map(|r| r.devices)
    }

    /// `DELETE /api/mobile/desktop/devices/{id}` — unpair the given device.
    /// Server also invokes Defguard revoke_user.
    pub async fn revoke_device(&self, device_id: &str) -> Result<(), ApiError> {
        let url = format!("{}/api/mobile/desktop/devices/{}", self.base_url, device_id);
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
        url: &str,
    ) -> Result<T, ApiError> {
        let mut req = self.http.get(url);
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
            return Err(ApiError::Server { status: status.as_u16(), detail });
        }
        resp.json::<T>()
            .await
            .map_err(|e| ApiError::Decode(e.to_string()))
    }

    /// `POST /api/mobile/push/register` — registers an FCM/APNS token
    /// with the backend so the desktop can deliver push notifications.
    /// Idempotent (server upserts).
    pub async fn register_push(&self, body: PushRegisterBody) -> Result<(), ApiError> {
        let url = format!("{}/api/mobile/push/register", self.base_url);
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
            return Err(ApiError::Server { status: status.as_u16(), detail });
        }
        Ok(())
    }

    /// `POST /api/mobile/pair` — exchanges a one-time pair token (from
    /// the desktop's QR code) for a long-lived device JWT. No bearer
    /// auth required for this call.
    pub async fn pair(&self, body: PairBody) -> Result<PairResp, ApiError> {
        let url = format!("{}/api/mobile/pair", self.base_url);
        let resp = self.http.post(&url).json(&body).send().await?;
        let status = resp.status();
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
        resp.json::<PairResp>()
            .await
            .map_err(|e| ApiError::Decode(e.to_string()))
    }
}
