#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# This is a reachability guard: managed skip-ci commits must still reach the
# complete native check, and failed runs must never create a success marker.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "$ROOT/.github/workflows/ci.yml" <<'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
assert '  schedule:' in text, 'managed skip-ci commits have no automatic CI route'
android = text.split('\n  android:\n', 1)[1].split('\n  ios:\n', 1)[0]
assert 'make check-android-host' in android
assert 'bash tools/run-android-checks.sh connected' in android
assert 'api-level: 36' in android and 'target: google_apis_ps16k' in android
for path in ['android/**', 'crates/**', 'Cargo.toml', 'Cargo.lock', 'tools/**', 'Makefile', 'checks-config.json', '.github/workflows/ci.yml']:
    assert f"'{path}'" in android, f'{path} changes can reuse stale CI success'
assert 'uses: actions/cache/save@v4' in android
save = android.split('uses: actions/cache/save@v4', 1)[0].rsplit('- name:', 1)[1]
assert "if: success() && steps.android-proof.outputs.cache-hit != 'true'" in save
assert 'restore-keys:' not in android, 'partial-key proof must never skip native verification'
assert 'if-no-files-found: error' in android, 'native proof is required'
print('Android CI reachability contract: passed')
PY
