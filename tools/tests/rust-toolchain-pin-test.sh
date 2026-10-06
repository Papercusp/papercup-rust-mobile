#!/usr/bin/env bash
# Guard for WI-10006894: local `make check` and every CI job must compile with
# ONE pinned Rust toolchain, derived from rust-toolchain.toml.
#
# The failure this prevents (WI-10006891): CI installed a floating `stable`
# toolchain, local machines used whatever stable they last installed, and a new
# clippy lint in 1.99 went red only on CI. Two floating channels = two gates.
#
# Subjects are overridable so a mutation probe can point this at a COPY:
#   RUST_TOOLCHAIN_FILE  (default: <repo>/rust-toolchain.toml)
#   RUST_CI_WORKFLOW     (default: <repo>/.github/workflows/ci.yml)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOLCHAIN_FILE="${RUST_TOOLCHAIN_FILE:-$ROOT/rust-toolchain.toml}"
CI_FILE="${RUST_CI_WORKFLOW:-$ROOT/.github/workflows/ci.yml}"

fail() { echo "rust-toolchain-pin-test: FAIL: $*" >&2; exit 1; }

[[ -f "$TOOLCHAIN_FILE" ]] || fail "missing $TOOLCHAIN_FILE — the repo must pin one Rust toolchain"
[[ -f "$CI_FILE" ]] || fail "missing $CI_FILE"

# 1. The pin is an exact release (X.Y.Z), never a floating channel.
channel="$(sed -nE 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "$TOOLCHAIN_FILE" | head -n1)"
[[ -n "$channel" ]] || fail "rust-toolchain.toml has no [toolchain] channel"
[[ "$channel" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "channel \"$channel\" is not an exact X.Y.Z release (floating channels let CI and local diverge)"

# 2. clippy and rustfmt come from the pin, because `make check` runs both.
for c in clippy rustfmt; do
    grep -Eq "^[[:space:]]*components[[:space:]]*=.*\"$c\"" "$TOOLCHAIN_FILE" \
        || fail "rust-toolchain.toml components must include \"$c\""
done

# 2b. The four Android ABIs build-android.sh cross-compiles (via cargo ndk) come
#     from the pin. A pinned toolchain is its own rustup install, so without
#     this list a fresh 1.99.0 has only the host std and the JNI build fails.
targets_line="$(grep -E '^[[:space:]]*targets[[:space:]]*=' "$TOOLCHAIN_FILE" | head -n1 || true)"
for t in aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android; do
    [[ "$targets_line" == *"\"$t\""* ]] \
        || fail "rust-toolchain.toml targets must include \"$t\" (cargo ndk builds it in build-android.sh)"
done

# 3. CI never installs a toolchain of its own choosing. Any action that takes a
#    channel/version argument would be a second source of truth.
if grep -nE 'uses:[[:space:]]*(dtolnay/rust-toolchain|actions-rs/toolchain|actions-rust-lang/setup-rust-toolchain)' "$CI_FILE"; then
    fail "ci.yml installs Rust through a toolchain action; derive it from rust-toolchain.toml with 'rustup toolchain install' instead"
fi
if grep -nE 'rustup[[:space:]]+(default|override|toolchain[[:space:]]+install[[:space:]]+[^&|;#[:space:]])|cargo[[:space:]]+\+[a-z0-9]' "$CI_FILE"; then
    fail "ci.yml names a Rust toolchain explicitly; the version must come only from rust-toolchain.toml"
fi

# 4. Every job that runs cargo installs the pinned toolchain before using it.
#    Split the workflow into jobs (2-space-indented keys under `jobs:`).
awk -v ci="$CI_FILE" '
    /^jobs:/ { injobs = 1; next }
    injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
        if (job != "" && usescargo && !installs) { print job; bad = 1 }
        job = $1; sub(":", "", job); usescargo = 0; installs = 0; next
    }
    injobs && /rustup toolchain install/ { if (!usescargo) installs = 1 }
    injobs && /(^|[^A-Za-z-])cargo[[:space:]]/ && $0 !~ /^[[:space:]]*#/ { usescargo = 1 }
    END {
        if (job != "" && usescargo && !installs) { print job; bad = 1 }
        exit bad
    }
' "$CI_FILE" > /tmp/rust-toolchain-pin-test.$$ || {
    jobs="$(tr '\n' ' ' < /tmp/rust-toolchain-pin-test.$$)"
    rm -f /tmp/rust-toolchain-pin-test.$$
    fail "CI job(s) run cargo before installing the pinned toolchain: $jobs"
}
rm -f /tmp/rust-toolchain-pin-test.$$

echo "rust-toolchain-pin-test: OK (pinned $channel; CI derives from rust-toolchain.toml)"
