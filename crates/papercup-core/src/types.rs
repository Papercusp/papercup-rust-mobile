// SPDX-License-Identifier: GPL-3.0-or-later
//
// Wire types — hand-mirrored from papercup-rust-server/openapi.yaml.
// Keep field names + nullability identical to the spec; the operator
// emits camelCase for some structs (PairResp, PairBody) and snake_case
// for others (HarnessLite). Mirror exactly — the UI converts to its
// own preferred casing.

use serde::{Deserialize, Serialize};

// ── /api/mobile/harnesses ──────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ListResp {
    pub harnesses: Vec<HarnessLite>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HarnessLite {
    pub slug: String,
    pub path: String,
    pub has_state: bool,
    #[serde(default)]
    pub harness_kind: Option<String>,
    #[serde(default)]
    pub iteration: Option<i64>,
    #[serde(default)]
    pub last_active_ts: Option<i64>,
    #[serde(default)]
    pub status: Option<String>,
}

// ── /api/mobile/harnesses/:slug ────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HarnessStatusFull {
    pub slug: String,
    pub status: String,
    pub iteration: i64,
    #[serde(default)]
    pub last_active_ts: Option<i64>,
}

// ── /api/mobile/pair ───────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PairBody {
    #[serde(rename = "pairToken")]
    pub pair_token: String,
    /// Reserved for the Defguard mesh broker; backend currently ignores.
    #[serde(rename = "wireguardPubkey", skip_serializing_if = "Option::is_none")]
    pub wireguard_pubkey: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PairResp {
    #[serde(rename = "deviceToken")]
    pub device_token: String,
    #[serde(rename = "deviceId")]
    pub device_id: String,
    #[serde(rename = "desktopHost")]
    pub desktop_host: String,
    #[serde(rename = "workspaceId")]
    pub workspace_id: String,
    #[serde(rename = "desktopMeshHost", default)]
    pub desktop_mesh_host: Option<String>,
    #[serde(rename = "defguardControlUrl", default)]
    pub defguard_control_url: Option<String>,
    #[serde(rename = "defguardEnrollmentUrl", default)]
    pub defguard_enrollment_url: Option<String>,
    #[serde(rename = "defguardEnrollmentToken", default)]
    pub defguard_enrollment_token: Option<String>,
    #[serde(rename = "defguardUsername", default)]
    pub defguard_username: Option<String>,
    #[serde(rename = "defguardError", default)]
    pub defguard_error: Option<String>,
    /// Mesh wgConfig — opaque shape; phone just relays it to the WG
    /// service. Backend currently returns null until the broker lands.
    #[serde(rename = "wgConfig", default)]
    pub wg_config: Option<serde_json::Value>,
    #[serde(rename = "wgError", default)]
    pub wg_error: Option<String>,
}

// ── error envelope (every 4xx/5xx body) ────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ErrorBody {
    pub error: String,
}
