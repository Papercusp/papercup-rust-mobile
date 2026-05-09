// SPDX-License-Identifier: GPL-3.0-or-later
//
// Papercup Core — UI-agnostic logic for the Papercup mobile app.
//
// Layers added in later phases:
//   - http client (reqwest + progenitor types from openapi.yaml)
//   - sync stream (SSE + in-memory cache with subscriber pattern)
//   - voice WS (tokio-tungstenite, hello/transcript/speak protocol)
//   - mesh decisions (which base URL to talk to)
//   - JWT storage (via UniFFI callback into platform keychain)
//
// Phase 0: just expose `version()` so the platform shells can prove the
// FFI bridge is wired correctly.

/// The crate version, as compiled in. Returned to the platform UI as
/// the world's smallest "is the bridge wired?" check.
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
