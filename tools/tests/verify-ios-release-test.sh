#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFY="$REPO_ROOT/tools/build-scripts/verify-ios-release.sh"

"$VERIFY"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

files=(
    .github/workflows/ci.yml
    ios/Papercup/Info.plist
    ios/Papercup/Papercup.entitlements
    ios/Papercup/Resources/PrivacyInfo.xcprivacy
    ios/Papercup/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json
    ios/Papercup/Sources/Papercup/AppLinks.swift
    ios/Papercup/Sources/Papercup/PapercupApp.swift
    ios/ExportOptions.plist
    ios/project.yml
    store/LISTING.md
    store/PRIVACY-POLICY.md
    store/APP-STORE-PRIVACY.md
    store/APP-STORE-REVIEW.md
)

copy_fixture() {
    rm -rf "$TMP_ROOT/fixture"
    for relative in "${files[@]}"; do
        mkdir -p "$TMP_ROOT/fixture/$(dirname "$relative")"
        cp "$REPO_ROOT/$relative" "$TMP_ROOT/fixture/$relative"
    done
    for icon in "$REPO_ROOT"/ios/Papercup/Resources/Assets.xcassets/AppIcon.appiconset/*.png; do
        relative="${icon#"$REPO_ROOT"/}"
        mkdir -p "$TMP_ROOT/fixture/$(dirname "$relative")"
        cp "$icon" "$TMP_ROOT/fixture/$relative"
    done
}

expect_failure() {
    local expected="$1"
    set +e
    output="$(PAPERCUP_IOS_RELEASE_ROOT="$TMP_ROOT/fixture" "$VERIFY" 2>&1)"
    rc=$?
    set -e
    if [ "$rc" -eq 0 ] || ! grep -q "$expected" <<<"$output"; then
        echo "ERROR: expected verifier failure containing: $expected" >&2
        echo "$output" >&2
        exit 1
    fi
}

copy_fixture
python3 - "$TMP_ROOT/fixture/ios/Papercup/Info.plist" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
with path.open("rb") as handle:
    data = plistlib.load(handle)
data["NSAppTransportSecurity"] = {"NSAllowsArbitraryLoads": True}
with path.open("wb") as handle:
    plistlib.dump(data, handle)
PY
expect_failure "NSAllowsArbitraryLoads"

copy_fixture
printf '\nTODO: replace this before release\n' >> "$TMP_ROOT/fixture/store/LISTING.md"
expect_failure "placeholder marker"

copy_fixture
sed -i.bak 's/MARKETING_VERSION: "1.0.0"/MARKETING_VERSION: "0.1.0"/' \
    "$TMP_ROOT/fixture/ios/project.yml"
expect_failure "marketing version 1.0.0"

copy_fixture
python3 - "$TMP_ROOT/fixture/ios/Papercup/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
png = bytearray(path.read_bytes())
png[25] = 6
path.write_bytes(png)
PY
expect_failure "alpha channel"

copy_fixture
python3 - "$TMP_ROOT/fixture/.github/workflows/ci.yml" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
workflow = path.read_text()
workflow = workflow.replace(
    "ssh-key: ${{ secrets.TOKEN_KIT_DEPLOY_KEY }}",
    "ssh-key: ${{ secrets.BROKEN_DEPLOY_KEY }}",
    1,
)
path.write_text(workflow)
PY
expect_failure "iOS token-kit checkout must use its read-only deploy key"

copy_fixture
sed -i.bak 's#path: ci/papercup#path: ../papercup#' \
    "$TMP_ROOT/fixture/.github/workflows/ci.yml"
expect_failure "design source checkout must remain inside GITHUB_WORKSPACE"

echo "OK: iOS release verifier rejects unsafe transport, placeholders, stale versions, transparent icons, and unsafe CI dependency checkouts"
