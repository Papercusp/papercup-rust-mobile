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

use crate::types::{ErrorBody, HarnessLite, ListResp, PairBody, PairResp};

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
