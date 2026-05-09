// SPDX-License-Identifier: GPL-3.0-or-later
//
// Papercup Core — UI-agnostic logic for the Papercup mobile app.
//
// Phase 0 stubbed `version()`; Phase 1 adds:
//   - types: hand-mirrored from papercup-rust-server/openapi.yaml
//   - http client: reqwest + bearer auth, mirrors the operator API
//   - errors: a single ApiError enum the UI can pattern-match on
//
// Hand-mirrored shapes are deliberate. There are 3 mobile ops in the
// spec today; pulling in `progenitor` for that surface costs more in
// build time than it pays back. Once we hit ~10 mobile ops (Phase 4
// brings voice WS + sync/sse + workspaces), swap to progenitor.

pub mod client;
pub mod sync;
pub mod types;

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
