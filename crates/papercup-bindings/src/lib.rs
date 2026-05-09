// SPDX-License-Identifier: GPL-3.0-or-later
//
// UniFFI bindings layer. Re-exports `papercup-core` to Kotlin + Swift.
//
// Phase 1 surface:
//   - free fn `version()`
//   - opaque `OperatorClient` object
//   - `Harness` plain record (FFI-friendly version of core::HarnessLite)
//   - `ApiError` enum (variants discriminated by core::client::ApiError)
//
// All async fns require a runtime; we install a multi-thread tokio
// runtime once at first use so each call can run blocking I/O without
// the platform shells caring.

use papercup_core::client::{ApiError as CoreApiError, OperatorClient as CoreClient};
use papercup_core::types::HarnessLite;

uniffi::include_scaffolding!("papercup");

// ── free fns ────────────────────────────────────────────────────────────

fn version() -> String {
    papercup_core::version()
}

// ── error mapping ───────────────────────────────────────────────────────
//
// UniFFI can wrap thiserror::Error directly, but core::ApiError carries
// runtime data we don't want to expose verbatim across the FFI. Map to
// a flat enum that matches the .udl exactly.

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

// ── OperatorClient ──────────────────────────────────────────────────────

/// Tokio runtime shared by all UniFFI async fns. Lazily initialized so
/// non-async paths don't pay for it.
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
        // Run the request on the shared runtime, then ferry the result back.
        let result = rt()
            .spawn(async move { core.list_harnesses().await })
            .await
            .map_err(|_| ApiError::Network)??;
        Ok(result.into_iter().map(Harness::from).collect())
    }
}
