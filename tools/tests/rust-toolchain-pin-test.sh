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
CI_FILE="${RUST_CI_WORKFLOW:-$ROOT/tools/ios-ci.py}"

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

# The native executor installs the toolchain without a channel argument; rustup
# resolves the checked-in pin. Effective version equality is also tested at runtime.
python3 - "$CI_FILE" <<'PY'
import ast
import sys
source = open(sys.argv[1]).read()
tree = ast.parse(source)
commands = [node.value for node in ast.walk(tree) if isinstance(node, ast.Constant) and isinstance(node.value, str)]
assert 'rustup' in commands and 'toolchain' in commands and 'install' in commands
assert 'stable' not in commands and 'nightly' not in commands, 'native CI must not float the Rust toolchain'
assert 'Effective Rust version does not match rust-toolchain.toml' in commands
PY

echo "rust-toolchain-pin-test: OK (pinned $channel; native CI derives from rust-toolchain.toml)"
