#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# This is a reachability guard: managed skip-ci commits must still reach the
# complete native check, and failed runs must never create a success marker.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "${1:-$ROOT/.github/workflows/ci.yml}" <<'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
assert '  schedule:' in text, 'managed skip-ci commits have no automatic CI route'
android = text.split('\n  android:\n', 1)[1].split('\n  ios:\n', 1)[0]
assert 'make check-android-host' in android
assert 'secrets.PAPERCUP_ANDROID_GOOGLE_SERVICES_JSON' in android, 'existing Firebase app configuration is not injected'
assert 'bash tools/run-android-checks.sh connected' in android
assert 'api-level: 36' in android and 'target: google_apis_ps16k' in android
sdk_setup = android.split('uses: android-actions/setup-android@v3', 1)[1].split('\n      -', 1)[0]
assert '          packages: platform-tools\n' in sdk_setup, 'SDK bootstrap must not request the retired tools package'
assert '          mkdir -p android-ci-attempt\n' in android, 'bootstrap failures need source-bound attempt evidence'
assert '\n            android-ci-attempt\n' in android, 'early failure evidence must be retained'
for path in ['android/**', 'crates/**', 'Cargo.toml', 'Cargo.lock', 'tools/**', 'Makefile', 'checks-config.json', '.github/workflows/ci.yml']:
    assert f"'{path}'" in android, f'{path} changes can reuse stale CI success'
assert 'uses: actions/cache/save@v4' in android
save = android.split('uses: actions/cache/save@v4', 1)[0].rsplit('- name:', 1)[1]
assert "if: success() && steps.android-proof.outputs.cache-hit != 'true'" in save
assert 'restore-keys:' not in android, 'partial-key proof must never skip native verification'
assert 'if-no-files-found: error' in android, 'native proof is required'
print('Android CI reachability contract: passed')
PY

if [[ $# == 0 ]]; then
    TMP_ROOT="$(mktemp -d)"
    trap 'rm -rf "$TMP_ROOT"' EXIT
    python3 - "$ROOT/.github/workflows/ci.yml" "$TMP_ROOT" <<'PY'
import sys
from pathlib import Path
text, out = Path(sys.argv[1]).read_text(), Path(sys.argv[2])
(out / 'retired-sdk.yml').write_text(text.replace('          packages: platform-tools\n', '          packages: tools platform-tools\n'))
(out / 'missing-early-evidence.yml').write_text(text.replace('          mkdir -p android-ci-attempt\n', ''))
PY
    for fixture in "$TMP_ROOT/retired-sdk.yml" "$TMP_ROOT/missing-early-evidence.yml"; do
        if bash "$0" "$fixture" > "$TMP_ROOT/output" 2>&1; then
            echo "FAIL: CI regression accepted: $fixture" >&2
            exit 1
        fi
    done
    echo 'Android CI bootstrap/evidence mutation controls: 2 rejected'
fi
