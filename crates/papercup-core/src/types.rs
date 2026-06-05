// SPDX-License-Identifier: GPL-3.0-or-later
//
// Wire types — hand-mirrored from papercup-rust-server/openapi.yaml.
// Keep field names + nullability identical to the spec; the operator
// emits camelCase for some structs (PairResp, PairBody) and snake_case
// for others (HarnessLite). Mirror exactly — the UI converts to its
// own preferred casing.

use serde::{Deserialize, Deserializer, Serialize};

/// Deserialize an f64 that the server may send as EITHER a JSON number
/// OR a string. postgres-js returns `NUMERIC`/`money` columns as decimal
/// STRINGS ("0.0000", "1.2345") to preserve precision, so any cost/usd
/// field is string-or-number depending on the row. Verified live against
/// `/api/device/running` (scan.cost_usd = "0.0000") 2026-06-05.
fn de_f64_flex<'de, D>(deserializer: D) -> Result<f64, D::Error>
where
    D: Deserializer<'de>,
{
    use serde::de::Error as _;
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum NumOrStr {
        Num(f64),
        Str(String),
    }
    match NumOrStr::deserialize(deserializer)? {
        NumOrStr::Num(n) => Ok(n),
        NumOrStr::Str(s) => s
            .trim()
            .parse::<f64>()
            .map_err(|e| D::Error::custom(format!("cost field {s:?} is not a number: {e}"))),
    }
}

// ── /api/device/harnesses ──────────────────────────────────────────────

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

// ── /api/device/harnesses/:slug ────────────────────────────────────────
//
// Stage 2.6 (backend) folded the desktop StatusResp shape into the mobile
// route. Field names are camelCase to match the wire contract.

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HarnessStatusFull {
    pub project: ProjectShort,
    /// Per-status feature counts (e.g. {"DONE": 12, "IN_PROGRESS": 3}).
    pub counts: std::collections::HashMap<String, i64>,
    pub iteration: i64,
    pub alive: bool,
    pub escalated: bool,
    pub pending_checkpoints: i64,
    pub active_competitions: i64,
    pub smoke_fail: bool,
    #[serde(deserialize_with = "de_f64_flex")]
    pub mission_cost_usd: f64,
    pub mission_input_tokens: i64,
    pub mission_output_tokens: i64,
    #[serde(default)]
    pub last_decision: Option<String>,
    /// `features` is a heavyweight array we don't render on mobile yet;
    /// captured as `serde_json::Value` so the type stays robust to
    /// backend-side schema additions (e.g. claims/metadata churn).
    #[serde(default)]
    pub features: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectShort {
    pub slug: String,
    pub path: String,
}

// ── /api/device/notifications/recent ───────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToastsResp {
    pub toasts: Vec<ToastRow>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToastRow {
    pub id: i64,
    pub level: String,
    pub message: String,
    pub created_at: i64,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub harness_slug: Option<String>,
    #[serde(default)]
    pub action_href: Option<String>,
    #[serde(default)]
    pub action_label: Option<String>,
}

// ── /api/device/actions/recent ─────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuditResp {
    pub entries: Vec<AuditRow>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuditRow {
    pub id: String,
    pub ts: i64,
    pub actor: String,
    pub action: String,
    pub subject: String,
    /// Free-form JSON. Mobile keeps it as an opaque string for display.
    #[serde(default)]
    pub details: serde_json::Value,
}

// ── /api/device/running ────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunningResp {
    #[serde(default)]
    pub scan: Option<RunningScan>,
    pub harnesses: Vec<RunningHarnessPhase>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunningScan {
    pub id: i64,
    pub started_at: i64,
    #[serde(default)]
    pub request_text: Option<String>,
    /// NUMERIC from PG → may arrive as a string ("0.0000"). See de_f64_flex.
    #[serde(deserialize_with = "de_f64_flex")]
    pub cost_usd: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunningHarnessPhase {
    pub harness_slug: String,
    pub phase: String,
    pub status: String,
    pub iteration: i32,
    pub total_features: i32,
    pub passed_count: i32,
    pub todo_count: i32,
    pub blocked_count: i32,
    pub active_roles: Vec<String>,
    #[serde(default)]
    pub last_active_ts: Option<i64>,
}

// ── /api/device/voice-lease ────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VoiceLeaseRead {
    #[serde(default)]
    pub lease: Option<VoiceLeaseShape>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VoiceLeaseShape {
    pub workspace_id: String,
    pub owner_id: String,
    /// "desktop" | "mobile"
    pub owner_kind: String,
    pub expires_at_ms: i64,
}

// ── /api/device/operator/pause ─────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PauseInfo {
    pub paused: bool,
    #[serde(default)]
    pub at: Option<String>,
    #[serde(default)]
    pub by: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PauseToggleResp {
    pub ok: bool,
    pub paused: bool,
}

// ── /api/device/workspace/switch ───────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceSwitchBody {
    #[serde(rename = "workspaceId")]
    pub workspace_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceSwitchResp {
    #[serde(rename = "deviceToken")]
    pub device_token: String,
    #[serde(rename = "workspaceId")]
    pub workspace_id: String,
}

// ── /api/device/workspaces ─────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspacesResp {
    pub workspaces: Vec<WorkspaceItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceItem {
    pub id: String,
    pub name: String,
    pub current: bool,
    #[serde(default)]
    pub last_activity_at: Option<i64>,
}

// ── /api/device/desktop/devices ────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DesktopDevicesResp {
    pub devices: Vec<DeviceRow>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceRow {
    pub device_id: String,
    pub workspace_id: String,
    #[serde(default)]
    pub device_label: Option<String>,
    /// Backend serialises these as ISO-8601; keep as string and let the
    /// platform format for display.
    #[serde(default)]
    pub last_seen: Option<String>,
    #[serde(default)]
    pub paired_at: Option<String>,
}

// ── /api/device/push/register ──────────────────────────────────────────
//
// Route is being rebuilt server-side (mobile-apps-revival D-001.2/D-004);
// body shape kept in sync with the rebuild — confirm against the landed
// route before shipping push.

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PushRegisterBody {
    /// "fcm" or "apns".
    pub platform: String,
    pub token: String,
}

// ── /api/device/pair ───────────────────────────────────────────────────
//
// Mesh = Defguard self-enrollment (D-005): the server returns an
// enrollment URL the phone opens; no WireGuard config is exchanged at
// pair time anymore.

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PairBody {
    #[serde(rename = "pairToken")]
    pub pair_token: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairResp {
    pub device_token: String,
    pub device_id: String,
    pub desktop_host: String,
    pub workspace_id: String,
    /// Defguard self-enrollment URL — open/hand off at pair time so the
    /// device can join the mesh. Optional defensively (a server without
    /// Defguard configured still pairs; LAN/public-tunnel fallbacks work).
    #[serde(default)]
    pub defguard_enrollment_url: Option<String>,
}

// ── /api/device/runtime-config ─────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeConfig {
    pub mesh_host: String,
    pub workspace_id: String,
    /// Currently always "mobile".
    pub device_kind: String,
    pub voice_ws: VoiceWsInfo,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VoiceWsInfo {
    /// Voice WS port (default :3068 server-side, walks up on conflicts).
    /// `null` when the server's voice WS failed to bind — surface
    /// "voice unavailable" instead of dialing a dead port.
    #[serde(default)]
    pub port: Option<u16>,
    /// e.g. "/api/device/voice".
    pub path: String,
}

// ── /api/device/voice-session-init ─────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VoiceSessionInit {
    pub conversation_token: String,
    pub agent_id: String,
    pub idle_timeout_min: f64,
    pub session_max_min: f64,
    pub voice_mode: String,
    /// Opaque map forwarded to the ElevenLabs Conv AI SDK verbatim.
    #[serde(default)]
    pub dynamic_variables: serde_json::Value,
}

// ── /api/device/rest-query ─────────────────────────────────────────────

/// `GET /api/device/rest-query?name=&args=` → `{ rows, version }` —
/// libs/sync's polling-fetcher shape. `rows` stays raw JSON; the cache
/// layer is name-keyed and UI-agnostic.
#[derive(Debug, Clone, Deserialize)]
pub struct RestQueryResp {
    pub rows: serde_json::Value,
    /// Server stamps `String(Date.now())` — changes every call, so it is
    /// NOT a change marker; diff `rows` instead.
    pub version: String,
}

// ── /api/device/attention (Inbox feed) ─────────────────────────────────
//
// D-002/D-003. `groups` is the canonical attention-group shape from
// plans:attention (plan items + coord escalations + messages-to-human +
// smoke-fails + plan-reviews) — a rich, evolving structure we keep as raw
// JSON for the UI to render generically. `workItems` is the work_items-
// native layer (attention-worthy features/bugs/changes), which we decode.

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AttentionResp {
    /// Raw attention groups (opaque, renderer-defined). Kept as JSON so a
    /// server-side group-shape change doesn't break decode.
    #[serde(default)]
    pub groups: serde_json::Value,
    #[serde(default)]
    pub work_items: Vec<AttentionWorkItem>,
    pub counts: AttentionCounts,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AttentionCounts {
    pub groups: i64,
    pub work_items: i64,
}

/// Mirrors the server's `WorkItem` (work-items.ts). Single-word fields map
/// as-is; camelCase handles assignedBy/createdAt/updatedAt.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AttentionWorkItem {
    pub id: String,
    pub kind: String,
    pub family: String,
    #[serde(default)]
    pub harness: Option<String>,
    pub title: String,
    #[serde(default)]
    pub summary: String,
    pub state: String,
    #[serde(default)]
    pub assignee: Option<String>,
    #[serde(default)]
    pub assigned_by: Option<String>,
    #[serde(default)]
    pub severity: Option<String>,
    #[serde(default)]
    pub parent: Option<String>,
    #[serde(default)]
    pub payload: serde_json::Value,
    pub created_at: String,
    pub updated_at: String,
}

// ── /api/device/plans ──────────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize)]
pub struct PlansResp {
    pub plans: Vec<PlanSummary>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanSummary {
    pub slug: String,
    pub harness: String,
    pub title: String,
    /// Nullable: a plan without frontmatter status reads as null (verified
    /// live — drafts/legacy plans have no status).
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default)]
    pub updated: Option<String>,
    #[serde(default)]
    pub owner: Option<String>,
    #[serde(default)]
    pub archived: bool,
    /// status → count, e.g. {"todo":3,"done":12}.
    #[serde(default)]
    pub item_counts: std::collections::HashMap<String, i64>,
    #[serde(default)]
    pub now_state: Option<String>,
    #[serde(default)]
    pub now_next: Option<String>,
}

/// One plan's full parsed structure. frontmatter/now/items/decisions are
/// the plan-parser's own shapes — kept as JSON so the UI decodes what it
/// needs without this crate tracking the parser's evolution.
#[derive(Debug, Clone, Deserialize)]
pub struct PlanDetail {
    pub slug: String,
    pub harness: String,
    #[serde(default)]
    pub archived: bool,
    pub title: String,
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default)]
    pub owner: Option<String>,
    #[serde(default)]
    pub frontmatter: serde_json::Value,
    #[serde(default)]
    pub now: serde_json::Value,
    #[serde(default)]
    pub items: serde_json::Value,
    #[serde(default)]
    pub decisions: serde_json::Value,
}

#[derive(Debug, Clone, Serialize)]
pub struct PlanItemStatusBody {
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub harness: Option<String>,
}

// ── /api/device/operator/conversation (Operator chat) ──────────────────
//
// D-002. The phone's Operator tab is a real chat thread on the SAME
// workspace-scoped operator conversation the desktop + TUI use. Reads
// load history; sending (POST /converse) is SSE — the client drains it to
// completion (the server persists both the user + assistant turns), then
// re-reads the conversation, so no delta-stream parsing is needed.

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConversationRead {
    pub conversation: ConversationRow,
    #[serde(default)]
    pub turns: Vec<OperatorTurn>,
    #[serde(default)]
    pub has_more_earlier: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConversationRow {
    pub id: String,
    pub workspace_id: String,
    #[serde(default)]
    pub harness_slug: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    pub status: String,
    pub started_at: i64,
    #[serde(default)]
    pub ended_at: Option<i64>,
    #[serde(default)]
    pub has_audio: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OperatorTurn {
    pub id: String,
    pub conversation_id: String,
    pub seq: i64,
    /// "user" | "assistant" | "system".
    pub role: String,
    pub text: String,
    /// "text_typed" | "voice_stt" | "voice_tts" | "system".
    pub source: String,
    pub created_at: i64,
    /// Tool-call entries (chat:ask_choice cards, etc.) — kept raw; the UI
    /// renders what it understands.
    #[serde(default)]
    pub tools: serde_json::Value,
}

#[derive(Debug, Clone, Serialize)]
pub struct ConverseBody {
    pub text: String,
    pub modality: String,
    pub trigger: String,
}

// ── standing approvals ─────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StandingCandidatesResp {
    pub candidates: Vec<StandingCandidate>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StandingCandidate {
    pub capability: String,
    #[serde(rename = "targetHarness")]
    pub target_harness: String,
    pub count: i64,
    #[serde(rename = "lastSeenAt")]
    pub last_seen_at: String,
    #[serde(rename = "firstShownAt", default)]
    pub first_shown_at: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct StandingDecisionBody {
    pub capability: String,
    #[serde(rename = "targetHarness")]
    pub target_harness: String,
    pub decision: String,
}

// ── error envelope (every 4xx/5xx body) ────────────────────────────────
//
// The server speaks TWO error shapes:
//   - route-stack errors (auth / input validation / timeout / handler
//     crash): `{"error":{"code":"unauthorized","message":"…"}}`
//   - handler-level errors: `{"error":"workspace_not_found"}`, sometimes
//     with `hint` / `detail` siblings.
// `ErrorPayload` decodes either; `detail_string()` flattens for display.

#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
pub enum ErrorPayload {
    Nested { code: String, message: String },
    Flat(String),
}

#[derive(Debug, Clone, Deserialize)]
pub struct ErrorBody {
    pub error: ErrorPayload,
    #[serde(default)]
    pub hint: Option<String>,
    #[serde(default)]
    pub detail: Option<String>,
}

impl ErrorBody {
    /// One human-readable line: "code: message" or the flat code, with
    /// any `hint`/`detail` appended.
    pub fn detail_string(&self) -> String {
        let mut s = match &self.error {
            ErrorPayload::Nested { code, message } => {
                if message.is_empty() {
                    code.clone()
                } else {
                    format!("{code}: {message}")
                }
            }
            ErrorPayload::Flat(code) => code.clone(),
        };
        if let Some(h) = &self.hint {
            s.push_str(&format!(" — {h}"));
        }
        if let Some(d) = &self.detail {
            s.push_str(&format!(" ({d})"));
        }
        s
    }
}
