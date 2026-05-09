// SPDX-License-Identifier: GPL-3.0-or-later
//
// UniFFI bindings layer. Re-exports `papercup-core` to Kotlin + Swift.
// Per the Phase 0 brief: only `version()` is exposed today.

uniffi::include_scaffolding!("papercup");

fn version() -> String {
    papercup_core::version()
}
