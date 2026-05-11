// SPDX-License-Identifier: GPL-3.0-or-later
//
// Papercup Core — UI-agnostic logic for the Papercup mobile app.
//
// Phase 0 stubbed `version()`; Phase 1 adds:
//   - types: hand-mirrored from papercup-rust-server/openapi.yaml
//   - http client: reqwest + bearer auth, mirrors the operator API
//   - errors: a single ApiError enum the UI can pattern-match on
//
// Hand-mirrored shapes are deliberate. The original Phase 1 plan
// said "swap to progenitor once we hit ~10 mobile ops" — we're now
// at 23 ops and have audited the alternatives:
//
//   * progenitor adds ~30s to clean cold builds + a code-gen step
//     that's awkward for cross-compile (cargo-ndk + xcframework both
//     re-run it per ABI).
//   * The hand-mirrored types are covered by 21 wiremock tests in
//     crates/papercup-core/tests/client_test.rs that exercise every
//     endpoint's body shape. If a backend change breaks the wire
//     contract, that suite fails before any user sees it.
//   * Each new endpoint costs ~10 lines (one struct, one method) +
//     one wiremock test. That's cheaper than maintaining a
//     progenitor-overrides file for the camelCase quirks in the
//     mobile API.
//
// Decision: keep hand-mirrored. If the wiremock suite stops being
// the cheapest contract enforcement (e.g. backend ships >50
// endpoints, or generated client features like retry policies become
// shared with the desktop), revisit.

pub mod biometric;
pub mod cache;
pub mod client;
pub mod intent;
pub mod mesh;
pub mod sync;
pub mod types;
pub mod voice;

/// The crate version, as compiled in. Returned to the platform UI as
/// the world's smallest "is the bridge wired?" check. Still useful in
/// Phase 1 for diagnostics screens.
pub fn version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_is_present() {
        let v = version();
        assert!(!v.is_empty());
        assert!(v.contains('.'));
    }
}
