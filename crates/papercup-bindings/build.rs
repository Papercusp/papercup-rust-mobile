// SPDX-License-Identifier: GPL-3.0-or-later
fn main() {
    uniffi::generate_scaffolding("src/papercup.udl").unwrap();
}
